#!/usr/bin/env pwsh
# gehihi-commit-gate.ps1
# PreToolUse hook: Enforcement gate for git staging and commit operations.
#
# Rules enforced (ref: research_agents/rules/02-commit-rules.md):
#   [GATE-1]  git add . / git add -A / git add --all -> DENY              (§3)
#   [GATE-2H] git add <hard-noise-file>              -> DENY (no override) (§1.1, §8)
#   [GATE-2S] git add <soft-suspect-file>            -> force_ask          (§8)
#   [GATE-3]  Staged diff contains secrets           -> DENY               (§23)
#   [GATE-4]  git commit                             -> force_ask checklist (§34)
#   [GATE-5]  git push --force / --force-with-lease  -> DENY               (§18)
#   [GATE-6]  git commit --allow-empty               -> DENY               (§29)
#   [GATE-7]  Vague/agent-theater commit message     -> DENY               (§12,§15,§16)
#
# Config: gehihi-commit-gate-config.json (sibling of this script, schema v2)
#   hardPatterns  : regex[]              -> absolute deny, no override possible
#   softPatterns  : {pattern,hint}[]     -> force_ask per operation, no persistent whitelist
#   Agent cannot self-approve soft patterns. Human approval required every time.

param()

Set-StrictMode -Off
$ErrorActionPreference = "SilentlyContinue"

# ---------------------------------------------------------------------------
# Read stdin
# ---------------------------------------------------------------------------
$inputRaw = $input | Out-String
if ([string]::IsNullOrWhiteSpace($inputRaw)) {
    @{ decision = "allow" } | ConvertTo-Json -Compress; exit 0
}
$payload = $null
try   { $payload = $inputRaw | ConvertFrom-Json }
catch { @{ decision = "allow" } | ConvertTo-Json -Compress; exit 0 }

$toolName = $payload.toolCall.name
$cmdLine  = $payload.toolCall.args.CommandLine

if ($toolName -ne "run_command" -or [string]::IsNullOrWhiteSpace($cmdLine)) {
    @{ decision = "allow" } | ConvertTo-Json -Compress; exit 0
}

# Fast-path: Bypass immediately for non-git commands without touching disk or loading configs
if ($cmdLine -notmatch '\bgit\b') {
    @{ decision = "allow" } | ConvertTo-Json -Compress; exit 0
}

# ---------------------------------------------------------------------------
# Load patterns from gehihi-commit-gate-config.json (schema v2)
# hardPatterns : regex[] - absolute deny
# softPatterns : {pattern, hint}[] - force_ask (human required, no persistent whitelist)
# ---------------------------------------------------------------------------
$hardPatterns = @(
    '^\.gemini[/\\]',
    'TRACE[^/\\]*\.md$',
    'tomb\.md$'
)
$softPatterns = @()   # will be populated from config if present

$configPath = Join-Path $PSScriptRoot "gehihi-commit-gate-config.json"
if (Test-Path $configPath) {
    try {
        $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
        if ($cfg.hardPatterns -and $cfg.hardPatterns.Count -gt 0) {
            $hardPatterns = $cfg.hardPatterns
        }
        if ($cfg.softPatterns -and $cfg.softPatterns.Count -gt 0) {
            $softPatterns = $cfg.softPatterns
        }
    } catch {}
}

function Test-IsHardNoise {
    param([string]$path)
    $n = $path.Trim().Replace('\', '/')
    foreach ($pat in $hardPatterns) {
        if ($n -match $pat) { return $true }
    }
    return $false
}

function Get-SoftHint {
    # Returns hint string if path matches a soft pattern, $null otherwise
    param([string]$path)
    $n = $path.Trim().Replace('\', '/')
    foreach ($entry in $softPatterns) {
        if ($n -match $entry.pattern) { return $entry.hint }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Secret patterns for staged diff scan
# ---------------------------------------------------------------------------
$secretPatterns = @(
    '(?i)(password|passwd|pwd)\s*[=:]\s*["\x27][^"\x27\s]{4,}',
    '(?i)(api_?key|apikey)\s*[=:]\s*["\x27][^"\x27\s]{8,}',
    '(?i)(secret|token|auth_?token|access_?key)\s*[=:]\s*["\x27][^"\x27\s]{8,}',
    'AKIA[0-9A-Z]{16}',
    '(?i)-----BEGIN\s+(RSA|EC|DSA|OPENSSH)\s+PRIVATE KEY'
)

function Find-SecretsInDiff {
    param([string[]]$diffLines)
    $hits = @()
    foreach ($line in $diffLines) {
        if (-not $line.StartsWith('+')) { continue }
        foreach ($pat in $secretPatterns) {
            if ($line -match $pat) {
                $hits += $line.Substring(0, [Math]::Min(80, $line.Length))
                break
            }
        }
    }
    return $hits
}

# ---------------------------------------------------------------------------
# Vague/agent-theater commit message patterns (§12, §15, §16)
# ---------------------------------------------------------------------------
$vaguePatterns = @(
    '(?i)^((feat|fix|chore|style|docs|refactor|test|build|ci|perf|revert)(\([^)]+\))?:\s*)?(improve things|make it work|changes|update|updates|update files|fix bug|fixes|wip|checkpoint|save|save progress|temp|temporary|agent checkpoint|continue previous|implement according to prompt|ai generated|final implementation|important fix|minor fix|various fixes|misc|stuff)$',
    '(?i)\b(WIP|checkpoint|temporary|save progress)\b'
)

function Test-IsVagueMessage {
    param([string]$msg)
    foreach ($pat in $vaguePatterns) {
        if ($msg -match $pat) { return $true }
    }
    return $false
}

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
function Deny {
    param([string]$reason)
    @{ decision = "deny"; reason = $reason } | ConvertTo-Json -Compress
    exit 0
}

function ForceAsk {
    param([string]$reason)
    @{ decision = "force_ask"; reason = $reason } | ConvertTo-Json -Compress
    exit 0
}

# ---------------------------------------------------------------------------
# [GATE-1] Hard deny: git add . / git add -A / git add --all
# ---------------------------------------------------------------------------
if ($cmdLine -match '(?:^|[;&|]\s*)git\s+add\s+(?:[.](\s|$)|(?:-A|--all)\b)') {
    Deny @"
[GATE-1] BLOCKED: 'git add .' / 'git add -A' is FORBIDDEN. (ref: ss3 Never Commit Unrelated Changes)
Reckless staging includes changes you did not make and cannot explain.

NEXT ACTION - stage files explicitly:
  git status                    # see full working tree state
  git diff --name-only          # unstaged changes
  git diff --cached --name-only # already staged
  git add <file1> <file2> ...   # stage only your changes

Stage only source code and scripts that belong to this commit.
"@
}

# ---------------------------------------------------------------------------
# [GATE-2H] Hard deny / [GATE-2S] Soft warn: git add <file>
# Hard files -> DENY (no override possible)
# Soft files -> force_ask (human approval required per operation)
# ---------------------------------------------------------------------------
if ($cmdLine -match '(?:^|[;&|]\s*)git\s+add\s+(.+)') {
    $addArgs = $Matches[1].Trim()
    $tokens  = $addArgs -split '\s+' | Where-Object { $_ -ne '' -and $_ -notmatch '^-' }

    # Hard check first - absolute denial
    $hardFound = @($tokens | Where-Object { Test-IsHardNoise $_ })
    if ($hardFound.Count -gt 0) {
        $list = $hardFound -join "`n  - "
        Deny @"
[GATE-2H] BLOCKED: These files are hard-denied and must NEVER be staged.
(ref: ss1.1 Commit only meaningful work, ss8 Generated Files)

Hard-denied paths:
  - $list

These are workflow/trace/AI-session artifacts. They must never appear in version control history.
No override exists for hard-denied files.

NEXT ACTION - remove them from your git add command and re-run with only source files.
"@
    }

    # Soft check - suspicious but occasionally legitimate, human must approve
    $softHits = [System.Collections.Generic.List[string]]::new()
    foreach ($token in $tokens) {
        $hint = Get-SoftHint $token
        if ($null -ne $hint) {
            $softHits.Add("  - $token`n      Reason: $hint")
        }
    }
    if ($softHits.Count -gt 0) {
        $detail = $softHits -join "`n"
        ForceAsk @"
[GATE-2S] Staging unusual file(s) - human approval required.
(ref: ss8 Generated Files, ss1.1 Commit only meaningful work)

$detail

If this file genuinely belongs in version control for this commit, approve.
If unsure, deny and reconsider. No persistent whitelist exists - approval is per staging operation.
The agent cannot self-approve this gate.
"@
    }
}

# ---------------------------------------------------------------------------
# [GATE-5] Hard deny: git push --force / --force-with-lease
# ---------------------------------------------------------------------------
if ($cmdLine -match '(?:^|[;&|]\s*)git\s+push\s+.*--(force|force-with-lease)\b') {
    Deny @"
[GATE-5] BLOCKED: Force-push is FORBIDDEN without explicit authorization.
(ref: ss18 Do Not Rewrite Shared History)

Force-pushing rewrites shared history and destroys collaborators' work.

NEXT ACTION:
  - If this is a local-only branch, get explicit approval from the user first.
  - If working on a shared branch, do NOT force-push under any circumstances.
  - Use 'git log --oneline -5' to review the state before deciding.
"@
}

# ---------------------------------------------------------------------------
# [GATE-6] Hard deny: git commit --allow-empty
# ---------------------------------------------------------------------------
if ($cmdLine -match '(?:^|[;&|]\s*)git\s+commit\s+.*--allow-empty\b') {
    Deny @"
[GATE-6] BLOCKED: Empty commits are FORBIDDEN. (ref: ss29 No Empty Commits)
An empty commit provides no value to the repository history.

NEXT ACTION:
  - Stage actual changes before committing.
  - If you need a placeholder, discuss with the user first.
"@
}

# ---------------------------------------------------------------------------
# [GATE-7] Vague / agent-theater commit message check
# ---------------------------------------------------------------------------
if ($cmdLine -match '(?:^|[;&|]\s*)git\s+commit\s+.*-m\s+["\x27]?([^"&;|]+)') {
    $extractedMsg = $Matches[1].Trim().Trim('"').Trim("'").Trim()
    if (Test-IsVagueMessage $extractedMsg) {
        Deny @"
[GATE-7] BLOCKED: Commit message is vague or describes agent behavior, not repository change.
(ref: ss12 Commit Subject, ss15 Do Not Commit Agent Process, ss16 No WIP Commits)

Message rejected: '$extractedMsg'

A commit message MUST describe WHAT changed in the repository.

Bad:  "chore: changes"  |  "WIP"  |  "checkpoint"  |  "agent checkpoint"
Good: "fix(auth): cancel stale session on logout"

NEXT ACTION - rewrite the message:
  git commit -m "<type>(<scope>): <imperative description of actual change>"

Types: feat | fix | refactor | perf | test | docs | build | ci | chore | style | revert
"@
    }
}

# ---------------------------------------------------------------------------
# [GATE-3 + GATE-4] git commit: secret scan + Minimum Commit Checklist
# ---------------------------------------------------------------------------
if ($cmdLine -match '(?:^|[;&|]\s*)git\s+commit') {
    $isAmend = $cmdLine -match '--amend'
    $workDir = if ($payload.workspacePaths -and $payload.workspacePaths.Count -gt 0) { $payload.workspacePaths[0] } else { $null }
    $opLabel = if ($isAmend) { "git commit --amend" } else { "git commit" }

    $stagedFiles  = @()
    $secretHits   = @()

    if ($workDir -and (Test-Path $workDir)) {
        $stagedFiles = @(& git -C $workDir diff --cached --name-only 2>$null | Where-Object { $_ })

        # GATE-2H reinforcement: hard-denied files in staged set
        $hardInStaged = @($stagedFiles | Where-Object { Test-IsHardNoise $_ })
        if ($hardInStaged.Count -gt 0) {
            $badList = $hardInStaged -join "`n  - "
            Deny @"
[GATE-2H] BLOCKED: Staged set contains hard-denied files that must NOT be committed.
(ref: ss1.1 Commit only meaningful work, ss8 Generated Files)

Hard-denied files in staged set:
  - $badList

NEXT ACTION:
  git restore --staged $($hardInStaged -join ' ')
Then re-run git commit.
"@
        }

        # GATE-3: secret scan on staged diff
        $diffLines = @(& git -C $workDir diff --cached -U0 2>$null | Where-Object { $_ })
        if ($diffLines.Count -gt 0) {
            $secretHits = @(Find-SecretsInDiff $diffLines)
        }

        if ($secretHits.Count -gt 0) {
            $hitList = ($secretHits | Select-Object -First 5) -join "`n  "
            Deny @"
[GATE-3] BLOCKED: Staged diff contains potential secrets or credentials.
(ref: ss23 Security-Sensitive Changes)

Suspicious lines detected:
  $hitList

NEXT ACTION:
  1. Remove the hardcoded values from the affected files.
  2. Use environment variables or a secrets manager instead.
  3. Re-stage the corrected files: git add <file>
  4. Verify clean: git diff --cached -U0 | findstr /i password
"@
        }
    }

    # Build staged file summary for the checklist prompt
    $stagedSummary = if ($stagedFiles.Count -gt 0) {
        "`n`nStaged files ($($stagedFiles.Count)):`n  - " + ($stagedFiles -join "`n  - ")
    } elseif ($isAmend) {
        "`n`n(Amend: no new staged files - amending metadata/message only)"
    } else {
        "`n`n(Staged set is EMPTY - this commit will contain nothing)"
    }

    # GATE-4: Minimum Commit Checklist (ref: §34)
    ForceAsk @"
[GATE-4] '$opLabel' requires checklist confirmation before proceeding.
(ref: ss34 Minimum Commit Checklist, ss26 Commit as Repository State)
$stagedSummary

Answer YES to ALL items before approving:

  [ ] I know exactly what this commit does.
  [ ] I know why this commit needs to exist (not just a checkpoint or save).
  [ ] All staged files belong to this single, coherent change.
  [ ] No user work or unrelated changes were accidentally staged.
  [ ] No secrets, credentials, or tokens are staged. (secret scan passed - also confirm visually)
  [ ] No temporary/debug artifacts or generated outputs are staged.
  [ ] Relevant verification was performed (tests/lint/build as applicable).
  [ ] The commit message describes the actual repository change, not the agent's process.
  [ ] The commit is appropriately scoped (not mixing unrelated changes).
  [ ] The repository will be in a coherent, buildable state after this commit.
  [ ] If this belongs with the previous commit - STOP and amend instead.

Approve only if every item is satisfied.
"@
}

# Default: allow everything else
@{ decision = "allow" } | ConvertTo-Json -Compress
