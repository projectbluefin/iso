---
name: build-iso
description: Guides agents through changing and validating ISO build inputs. Use when modifying build matrices, image references, installer hooks, workflow callers, or local ISO recipes.
---

# Build ISO

## Use when

Use this skill for build matrices, image tags, caller inputs, shared build steps, installer hooks, Flatpak sourcing, and local ISO recipes.

## Do not use when

Do not use this skill for smoke evidence, installer E2E triage, or production promotion. Use `test-iso` or `release-iso` instead.

## Inputs

Read `docs/architecture.md` first. Then read the owning workflow, hook, script, or recipe before editing it.

- Caller behavior: `.github/workflows/build-iso-*.yml`
- Shared build: `.github/workflows/reusable-build-iso-anaconda.yml`
- Installer hooks: `iso_files/`
- Local commands: `Justfile`, `just/`, and `hack/`

## Procedure

1. Identify the single file that owns the requested behavior.
2. Confirm the requested variant and image tag in the caller and reusable workflow.
3. Preserve existing inputs, outputs, artifact names, and file formats.
4. Keep the shared workflow on Titanoboa commit `840217d97bd0bc9a52466508c54d8dda5c5ba2fd` until its hook and Flatpak inputs are supported again; its Justfile needs `set lists` with current Just.
5. Change the smallest existing structure that implements the request.
5. Update `docs/architecture.md` when the matrix, source, artifact flow, or workflow boundary changes.
6. Update this skill when the agent procedure changes.
7. Do not edit generated ISO, build, smoke, or E2E output.

## Verification

```bash
bash -n path/to/changed-script.sh
just check
pre-commit run --all-files
actionlint .github/workflows/*.yml
```

For installer changes, rebuild and boot the ISO. Follow `docs/qa.md` for the applicable evidence.

The current Titanoboa `main` action accepts only `image-ref` and `iso-dest`; using it here silently drops the installer hook and Flatpak inputs. The reusable workflow checks out the last compatible Titanoboa revision, adds `set lists` for current Just, and invokes its build recipe directly.

## Related documents

- [Architecture](../../architecture.md)
- [QA](../../qa.md)
- [Contributor workflow](../../contributing.md)
