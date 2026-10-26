#!/usr/bin/env pwsh
# ==============================================================================
# Gehihi-Things Installer for Antigravity (.agents workspace)
#
# Initializes or appends Gehihi modules into a target repository's .agents/ dir.
# Safely merges hooks.json without breaking existing configurations.
# ==============================================================================

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$TargetDir = "",

    [Parameter()]
    [string]$Package = "",

    [Parameter()]
    [switch]$All,

    [Parameter()]
    [switch]$Force
)

$ErrorActionPreference = "Stop"

# ------------------------------------------------------------------------------
# Source Resolution (Local repo clone vs Remote web execution)
# ------------------------------------------------------------------------------
$RepoOwner  = "Gawasna"
$RepoName   = "gehihi-things"
$Branch     = "main"
$RawBaseUrl = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$Branch"

$SourceRoot = $null
if ($MyInvocation.MyCommand.Definition) {
    $SourceRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
}

$IsRemote = $true
$DistDir  = $null

if ($SourceRoot) {
    $localDist = Join-Path $SourceRoot "dist_agents"
    if (Test-Path $localDist) {
        $DistDir  = $localDist
        $IsRemote = $false
    }
}

# ------------------------------------------------------------------------------
# Package Registry (Extensible list of 'things')
# ------------------------------------------------------------------------------
$Registry = @(
    @{
        Id          = "commit-gate"
        Name        = "Gehihi Commit Gate"
        Description = "PreToolUse gate enforcing explicit staging, secret scan, message quality, and force-push block"
        Files       = @(
            @{ Source = "hooks/gehihi/gehihi-commit-gate.ps1";        Dest = "hooks/gehihi/gehihi-commit-gate.ps1" },
            @{ Source = "hooks/gehihi/gehihi-commit-gate-config.json"; Dest = "hooks/gehihi/gehihi-commit-gate-config.json"; PreserveExisting = $true },
            @{ Source = "rules/gehihi-commit.md";                     Dest = "rules/gehihi-commit.md" }
        )
        HookKey     = "gehihi-commit-gate"
        HookConfig  = @{
            PreToolUse = @(
                @{
                    matcher = "run_command"
                    hooks   = @(
                        @{
                            type    = "command"
                            command = "pwsh -NoProfile -NonInteractive -File ./hooks/gehihi/gehihi-commit-gate.ps1"
                            timeout = 15
                        }
                    )
                }
            )
        }
    }
)

# ------------------------------------------------------------------------------
# Helper: Safe Merge into hooks.json
# ------------------------------------------------------------------------------
function Update-HooksJson {
    param(
        [string]$HooksJsonPath,
        [string]$HookKey,
        [hashtable]$HookConfig,
        [bool]$ForceOverwrite
    )

    $existingObj = [ordered]@{}
    if (Test-Path $HooksJsonPath) {
        try {
            $raw = Get-Content $HooksJsonPath -Raw
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $parsed = $raw | ConvertFrom-Json
                foreach ($prop in $parsed.PSObject.Properties) {
                    $existingObj[$prop.Name] = $prop.Value
                }
            }
        } catch {
            Write-Warning "Could not parse existing hooks.json as JSON. Creating backup..."
            Copy-Item -Path $HooksJsonPath -Destination "$HooksJsonPath.bak.$(Get-Date -Format 'yyyyMMddHHmmss')"
            $existingObj = [ordered]@{}
        }
    }

    if ($existingObj.Contains($HookKey) -and -not $ForceOverwrite) {
        Write-Host "  [-] Hook '$HookKey' already exists in hooks.json. Kept existing (use -Force to overwrite)." -ForegroundColor DarkGray
        return
    }

    $existingObj[$HookKey] = $HookConfig

    $jsonOut = $existingObj | ConvertTo-Json -Depth 10
    Set-Content -Path $HooksJsonPath -Value $jsonOut -Encoding UTF8
    Write-Host "  [+] Appended hook '$HookKey' into hooks.json" -ForegroundColor Green
}

# ------------------------------------------------------------------------------
# Helper: Install Single Package
# ------------------------------------------------------------------------------
function Install-GehihiPackage {
    param(
        [hashtable]$Pkg,
        [string]$DestAgentsDir,
        [bool]$ForceOverwrite
    )

    Write-Host ""
    Write-Host "==> Installing: $($Pkg.Name)" -ForegroundColor Cyan
    Write-Host "    $($Pkg.Description)" -ForegroundColor DarkGray

    # 1. Copy or Download Files
    foreach ($item in $Pkg.Files) {
        $destPath = Join-Path $DestAgentsDir $item.Dest
        $destParent = Split-Path -Parent $destPath
        if (-not (Test-Path $destParent)) {
            New-Item -ItemType Directory -Force -Path $destParent | Out-Null
        }

        if ((Test-Path $destPath) -and $item.PreserveExisting -and -not $ForceOverwrite) {
            Write-Host "  [-] Preserved existing configuration: $($item.Dest)" -ForegroundColor DarkGray
            continue
        }

        if (-not $IsRemote) {
            $srcPath = Join-Path $DistDir $item.Source
            if (-not (Test-Path $srcPath)) {
                Write-Warning "Source file missing: $srcPath"
                continue
            }
            Copy-Item -Force -Path $srcPath -Destination $destPath
            Write-Host "  [+] Copied: $($item.Dest)" -ForegroundColor Green
        } else {
            $fileUrl = "$RawBaseUrl/dist_agents/$($item.Source)"
            try {
                Invoke-RestMethod -Uri $fileUrl -OutFile $destPath
                Write-Host "  [+] Downloaded: $($item.Dest)" -ForegroundColor Green
            } catch {
                Write-Error "Failed to download $fileUrl : $_"
                exit 1
            }
        }
    }

    # 2. Merge into hooks.json if package defines a hook
    if ($Pkg.HookKey -and $Pkg.HookConfig) {
        $hooksJsonPath = Join-Path $DestAgentsDir "hooks.json"
        Update-HooksJson -HooksJsonPath $hooksJsonPath -HookKey $Pkg.HookKey -HookConfig $Pkg.HookConfig -ForceOverwrite $ForceOverwrite
    }

    Write-Host "[OK] $($Pkg.Name) successfully installed." -ForegroundColor Green
}

# ------------------------------------------------------------------------------
# Target Directory Resolution
# ------------------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($TargetDir)) {
    # If run in gehihi-things root itself, ask user for target project path
    $currentDir = (Get-Location).Path
    if ($currentDir -eq $SourceRoot) {
        Write-Host ""
        Write-Host "You are running installer from the gehihi-things repository root." -ForegroundColor Yellow
        $prompt = Read-Host "Enter target repository directory (leave empty for current directory '$currentDir')"
        if (-not [string]::IsNullOrWhiteSpace($prompt)) {
            $TargetDir = $prompt
        } else {
            $TargetDir = $currentDir
        }
    } else {
        $TargetDir = $currentDir
    }
}

$TargetDir = [System.IO.Path]::GetFullPath($TargetDir)
if (-not (Test-Path $TargetDir)) {
    $create = Read-Host "Target directory '$TargetDir' does not exist. Create it? (y/N)"
    if ($create -match '^(y|yes)$') {
        New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null
    } else {
        Write-Host "Aborted." -ForegroundColor Red
        exit 1
    }
}

$DestAgentsDir = Join-Path $TargetDir ".agents"
if (-not (Test-Path $DestAgentsDir)) {
    New-Item -ItemType Directory -Force -Path $DestAgentsDir | Out-Null
    Write-Host "[+] Initialized .agents directory at: $DestAgentsDir" -ForegroundColor Green
} else {
    Write-Host "[*] Found existing .agents directory at: $DestAgentsDir" -ForegroundColor Cyan
}

# ------------------------------------------------------------------------------
# Interactive Menu or Non-Interactive Execution
# ------------------------------------------------------------------------------
if ($All) {
    foreach ($pkg in $Registry) {
        Install-GehihiPackage -Pkg $pkg -DestAgentsDir $DestAgentsDir -ForceOverwrite $Force
    }
    exit 0
}

if (-not [string]::IsNullOrWhiteSpace($Package)) {
    $selected = $Registry | Where-Object { $_.Id -eq $Package }
    if ($null -eq $selected) {
        Write-Error "Package '$Package' not found in registry. Available: $($Registry.Id -join ', ')"
        exit 1
    }
    Install-GehihiPackage -Pkg $selected -DestAgentsDir $DestAgentsDir -ForceOverwrite $Force
    exit 0
}

# Interactive Menu
Clear-Host
Write-Host "==================================================================" -ForegroundColor Magenta
Write-Host "               GEHIHI-THINGS INSTALLER                           " -ForegroundColor Magenta
Write-Host "==================================================================" -ForegroundColor Magenta
Write-Host "Target: $TargetDir" -ForegroundColor Yellow
Write-Host ".agents: $DestAgentsDir" -ForegroundColor Yellow
Write-Host ""
Write-Host "Available Packages (Things):" -ForegroundColor White

for ($i = 0; $i -lt $Registry.Count; $i++) {
    $idx = $i + 1
    $p = $Registry[$i]
    Write-Host "  [$idx] $($p.Name)" -ForegroundColor Green
    Write-Host "      $($p.Description)" -ForegroundColor DarkGray
}

Write-Host "  [A] Install All Packages" -ForegroundColor Cyan
Write-Host "  [Q] Quit" -ForegroundColor Red
Write-Host ""

$choice = Read-Host "Enter selection [1-$($Registry.Count), A, Q] (default: 1)"
if ([string]::IsNullOrWhiteSpace($choice)) { $choice = "1" }

if ($choice -match '^(q|quit|exit)$') {
    Write-Host "Cancelled." -ForegroundColor Yellow
    exit 0
}

if ($choice -match '^(a|all)$') {
    foreach ($pkg in $Registry) {
        Install-GehihiPackage -Pkg $pkg -DestAgentsDir $DestAgentsDir -ForceOverwrite $Force
    }
} else {
    $num = 0
    if ([int]::TryParse($choice, [ref]$num) -and $num -ge 1 -and $num -le $Registry.Count) {
        $chosenPkg = $Registry[$num - 1]
        Install-GehihiPackage -Pkg $chosenPkg -DestAgentsDir $DestAgentsDir -ForceOverwrite $Force
    } else {
        Write-Warning "Invalid choice '$choice'. Nothing installed."
        exit 1
    }
}

Write-Host ""
Write-Host "Installation completed. Gehihi-things is active for this workspace." -ForegroundColor Green
