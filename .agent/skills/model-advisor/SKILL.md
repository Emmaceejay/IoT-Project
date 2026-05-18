---
name: model-advisor
description: Automatically evaluates task complexity and advises the user on which LLM model tier to use to optimize speed and compute quota.
---

# Model Advisor Skill Protocol

When this skill is active, you must follow this mandatory protocol for all subsequent interactions:

## 1. Core Directive
Before undertaking any code implementation, architectural design, or debugging phase, you MUST evaluate the complexity of the user's request and explicitly recommend which model tier they should use.

## 2. Complexity Tiers & Rules

### 🟢 Lightweight Tier (Fast / Low Compute)
*   **Target Tasks:** Scaffolding folder structures, fixing typos, adjusting UI colors/CSS, adding comments, reading logs.
*   **Tag:** `**[Model Target: 🟢 Lightweight]**`
*   **Action:** Place the tag at the top of your response. Briefly mention the task is simple and they can switch to a light model to save quota. Proceed with the task immediately.

### 🟡 Standard Tier
*   **Target Tasks:** Writing standard UI components, basic CRUD API integrations, writing unit tests, isolated bug fixes.
*   **Tag:** `**[Model Target: 🟡 Standard]**`
*   **Action:** Place the tag at the top. Mention standard models are perfectly fine. Proceed with the task.

### 🔴 Heavyweight Tier (Pro / Thinking Models)
*   **Target Tasks:** System architecture design, embedded C/C++ firmware, complex state management (Riverpod/Redux/etc), cryptographics, multi-file refactoring, or hunting deep logical bugs.
*   **Tag:** `**[Model Target: 🔴 Heavyweight]**`
*   **Action:** Place the tag at the top. Tell the user: *"This task requires deep reasoning. I highly recommend ensuring you are on a 'Pro' or 'Thinking' level model to prevent logic errors."* **Do NOT execute heavy code changes until the user gives the "GO" approval on their desired model.**

## 3. Communication Style
Keep it brief. Do not be overly verbose about the models; just provide the colored tag, one sentence of context, and await instructions if it is a Heavy task.

## 4. Quota Management Protocol (Surgical Efficiency)
To preserve the user's compute quota, especially when working on complex projects, you must actively implement the following professional coding behaviors:

- **Surgical Code Edits:** NEVER rewrite an entire file to change a few lines. Use precise code modification tools (`multi_replace_file_content`) to target only the specific lines needing change.
- **Micro-Verifications:** Instead of running comprehensive, quota-heavy recursive workspace searches, check specific files intentionally.
- **Batching Tool Calls:** Execute multiple non-conflicting tool calls (e.g., creating 5 files) in a single response turn simultaneously, rather than burning 5 response turns to do them one by one.
- **Measure Twice, Cut Once:** For Heavyweight tasks, output a brief markdown `Implementation Plan` artifact for user approval *before* generating hundreds of lines of code. If the user spots a logic flaw early, you save the massive quota cost of re-generating it.

## 5. Documentation Maintenance Protocol
To ensure the project remains professional and easily hand-off ready:
- **Continuous README Sync:** Whenever you implement a new feature, change the project architecture, or add significant capabilities, you MUST automatically evaluate if the root `README.md` (or other core docs) requires an update.
- **Silent Updates:** Treat documentation (`README.md`, `QUICKSTART_GUIDE.md`) as living code. If it goes out of sync with your changes, update it in tandem automatically to ensure zero technical debt.

## 6. Git Action Integration
To ensure code changes are safely persisted, whenever you successfully complete any task across the Light, Standard, or Heavy tiers, you MUST silently invoke the `@git-action` skill. Follow its exact protocol to proactively prompt the user to commit and push their changes.
