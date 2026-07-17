---
name: skill-improvement
version: "1.0"
last_updated: 2026-07-17
tags: [skills, improvement, documentation]
description: "Use when you are about to finish a task in this repository and need to decide whether to write back a skill update for future agents."
metadata:
  type: procedure
---

# Skill Improvement

## When to Use

Use this skill when a session changes workflows, scripts, hooks, or docs and you need to decide what learning to write back.

## When NOT to Use

Do not use this skill for one-off operational notes, obvious commands, or ephemeral state that does not help future agents.

## Core Process

1. Identify the work completed and the repo-specific behavior that was discovered.
2. Update or create the closest matching skill file under `docs/skills/`.
3. Keep the skill update in the same PR as the implementation.
4. Before closing the session, confirm the work and the learning were both shipped.

## Common Rationalizations

- "I'll update the skill file next session." The loop only compounds if agents write back immediately.
- "This was obvious, so no skill update is needed." If the pattern required trial and error, it is not obvious.

## Red Flags

- Finishing a non-trivial task without touching `docs/skills/`
- Adding changelog files or session notes to the repository instead of skill files
- Writing a skill update that only restates the obvious

## Verification

- [ ] Did I discover a workaround, repo-specific convention, or non-obvious behavior?
- [ ] Did I update or create the closest matching skill file?
- [ ] Is the skill update in the same PR as the implementation?

## Repo-specific expectations

- Keep `docs/skills/` in sync with workflow, hook-script, and Justfile changes.
- Document ISO workflow changes, LTS caveats, and operational gotchas.
- Do not add changelog or session-note files to the repository; keep session state in the agent session folder.
