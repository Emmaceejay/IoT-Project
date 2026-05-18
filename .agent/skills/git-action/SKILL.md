---
name: Git Action
description: Automates git commit and push prompts to ensure code changes are safely persisted to the repository.
---

# Git Action Protocol

This skill enforces a professional version control workflow by ensuring that all accepted codebase updates are promptly committed and pushed to the remote repository.

## 1. Core Directive
Whenever an implementation plan is completed, a bug is fixed, or any functional changes to the codebase are accepted by the user, you MUST proactively ask the user if they would like to commit and push the changes to GitHub.

## 2. Trigger Conditions
You must initiate this protocol immediately following:
- The completion of a `<planning_mode>` Execution and Verification phase.
- The successful resolution of an isolated bug or issue.
- Any manual file modifications that result in a functional state change.

## 3. The Prompt Format
When a trigger condition is met, append the following prompt to the end of your response using a distinct blockquote or alert:

> [!TIP]
> **Repository Sync Recommended:** You have uncommitted changes. Would you like me to commit and push these changes to GitHub to prevent any accidental data loss?

## 4. Execution Protocol
If the user replies "yes" or approves the prompt:
1. **Status Check:** Run `git status` using the terminal to identify modified, added, or deleted files.
2. **Commit Generation:** 
   - Generate a concise, professional commit message following the Conventional Commits format (e.g., `feat: implement login flow` or `fix: resolve padding issue on mobile`).
   - Run `git add .` (or specific files if requested).
   - Run `git commit -m "<your generated message>"`.
3. **Push:** Run `git push`.
4. **Confirmation:** Confirm with the user once the push is successfully completed.

## 5. Professional Guardrails
- **NEVER** forcefully commit and push without explicit user consent.
- Always ensure the code is in a working state before prompting to commit.
- If the `git push` fails (e.g., due to remote conflicts), inform the user and suggest running `git pull --rebase` or explicitly ask for instructions.
