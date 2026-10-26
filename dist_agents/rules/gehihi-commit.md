---
trigger: model_decision
description: "Rules to evaluate before staging files or running git commit."
---

# Git Commit Evaluation

DO NOT USE `git add .` or `git add -A`. Always stage specific files explicitly.

Before committing, the agent MUST evaluate and satisfy these questions:

1. **Amend vs. New Commit:**
   Does creating a separate commit introduce unnecessary clutter into version history?
   If this change fixes, refines, or continues the immediately preceding commit, the preferred action is to amend:
   `git commit --amend --no-edit` (or with updated message).

2. **File Necessity & Scope:**
   Does every single file in the staged change belong in professional version control?
   If a file is not strictly required production or test code, DO NOT COMMIT.