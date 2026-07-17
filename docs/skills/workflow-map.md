---
name: workflow-map
version: "1.0"
last_updated: 2026-07-17
tags: [workflows, iso, build]
description: "Use when you need to understand how the Bluefin ISO builder workflows fit together or update workflow documentation for this repository."
metadata:
  type: reference
---

# ISO workflow map

## When to Use

Use this skill when you need to understand the repository's workflow topology, the LTS safety guardrails, or the role of a specific GitHub Actions workflow.

## When NOT to Use

Do not use this skill for implementation changes that belong in the workflow files themselves; use it for orientation and documentation only.

## Core Process

1. Read the workflow files and the repo's AGENTS guidance before changing behavior.
2. Use the workflow roles below to identify the correct workflow for the task at hand.
3. Keep the repo's LTS and promotion guardrails documented whenever the workflow behavior changes.

## Common Rationalizations

- "I already know the workflow layout." The repo's LTS caveats and testing workflow boundaries are easy to misread without the documentation.
- "The workflow name is obvious, so I can skip the map." That is how cross-workflow mistakes happen.

## Red Flags

- Re-enabling LTS scheduling without reviewing the documented breakage
- Treating `build-iso-lts-hwe-testing.yml` as a general testing workflow
- Forgetting that `promote-iso.yml` is manual and should not overwrite production during the LTS outage

## Verification

- [ ] The workflow file I changed is documented here.
- [ ] The repo's LTS safety guardrails are still accurate.
- [ ] The workflow map still matches the current `.github/workflows/` directory.

## Workflow roles

- `build-iso-stable.yml` — builds the stable ISO variants.
- `build-iso-lts.yml` — builds the LTS ISO variants; this workflow is intentionally left without a schedule because the LTS base image currently breaks Anaconda.
- `build-iso-lts-hwe.yml` — builds the LTS-HWE production variants.
- `build-iso-lts-hwe-testing.yml` — the only authorized workflow for `lts-hwe-testing` tags.
- `build-iso-all.yml` — orchestrates the stable and LTS-HWE variants.
- `reusable-build-iso-anaconda.yml` — contains the shared matrix, build, torrent, and prerelease logic.
- `promote-iso.yml` — promotes testing artifacts into the production R2 bucket and GitHub release.
- `pull-request.yml` — runs build validation without uploading artifacts.
- `validate-renovate.yml` — validates the Renovate configuration.
- `skill-drift.yml` — warns when implementation changes land without a matching skill update.

## Operational notes

- LTS non-HWE production promotion is disabled while the LTS build remains broken.
- Only `variant: stable` promotion is safe until the LTS issue is resolved.
- Flatpak lists are assembled at build time from `projectbluefin/common`'s `*system-flatpaks.Brewfile` files.
