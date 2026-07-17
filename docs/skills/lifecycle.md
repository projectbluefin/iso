---
name: lifecycle
version: "1.0"
last_updated: 2026-07-17
tags: [issues, pull-requests, releases]
description: "Use when a task needs to move through issue triage, PR review/merge, and release handling without skipping the repository's safety guardrails."
metadata:
  type: procedure
---

# Repository lifecycle

## When to Use

Use this skill when you need to:

- triage or scope an issue or PR in this repository
- decide whether a change is small enough to merge quickly
- prepare release-facing work or promotion decisions
- close out a session after implementation

## When NOT to Use

- Do not use it for low-level implementation details that belong in the code or workflow files.
- Do not use it as a substitute for `workflow-map` when the task is specifically about build, prerelease, or promotion behavior.

## Core Process

1. Start with the current repo state: issue or PR status, branch state, and the relevant workflow documentation.
2. For issues, confirm scope, acceptance criteria, and release impact before editing.
3. For PRs, favor small, safe changes with clear validation; keep behavior changes and documentation/skill updates together.
4. For release work, prefer testing artifacts first and keep LTS promotion blocked until the known breakage is resolved.
5. Before closing a session, verify that implementation, validation, and any needed skill updates are all present.

## Common Rationalizations

- "This is obvious, so no lifecycle note is needed." The repo has release and LTS guardrails that are easy to miss.
- "I can merge this after the release." If the change is safe, it should be landed with its own verification and skill update.
- "The issue is already clear, so I can skip the scope check." Scope drift is how small tasks grow into release risk.

## Red Flags

- Opening a PR that changes behavior but leaves the skill docs unchanged
- Treating LTS or LTS-HWE promotion as normal when the repo is explicitly in a broken state
- Closing a session without a clear handoff, validation evidence, or the relevant skill update

## Verification

- [ ] I understand the issue or PR scope and release impact.
- [ ] I validated the change with the repo's existing checks.
- [ ] I updated or created the closest matching skill file if the session changed repo behavior or workflow expectations.
- [ ] I closed the session with a clear outcome and any follow-up needed.

## Repo-specific expectations

- Keep issue and PR work aligned with the repo's release model: build and test in R2 testing, then promote manually to production.
- Treat LTS non-HWE promotion as unsafe while the current Anaconda regression remains unresolved.
- Keep the agent-facing docs in `docs/skills/` current whenever behavior or workflow expectations change.
