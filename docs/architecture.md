# Architecture

This document owns the repository's workflow and artifact model. Other documents should link here instead of repeating the matrix or pipeline.

## Components

| Area | Source of truth | Responsibility |
| --- | --- | --- |
| Build callers | `.github/workflows/build-iso-*.yml` | Trigger a fixed variant and pass inputs. |
| Shared build | `.github/workflows/reusable-build-iso-anaconda.yml` | Select the matrix, build ISOs, create assets, and create a prerelease. |
| Installer hooks | `iso_files/` | Configure the live environment and installer for the image base. |
| Local recipes | `Justfile`, `just/`, `tests/iso/` | Build and test locally. `hack/` contains compatibility entry points only. |
| Smoke validation | `.github/workflows/iso-smoke-test.yml` | Boot the exact candidate asset set in QEMU. |
| Installer E2E | `.github/workflows/iso-e2e-test.yml`, `tests/iso/` | Exercise unattended installation and collect proof artifacts. |
| Promotion | `.github/workflows/promote-iso.yml` | Gate, preview, and copy approved assets to production. |
| External validation | `projectbluefin/testsuite/.github/workflows/iso-validation.yml` | Optional validation of published ISO URLs using an immutable ISO harness ref. |

## Build matrix

| Image version | ISO count | Platforms | Flavors |
| --- | ---: | --- | --- |
| `stable` | 2 | `amd64` | `main`, `nvidia-open` |
| `lts` | 4 | `amd64`, `arm64` | `main`, `gdx` |
| `lts-hwe` | 2 | `amd64`, `arm64` | `main` |

The `lts-hwe-testing` image tag is owned only by `.github/workflows/build-iso-lts-hwe-testing.yml`. Do not add that tag to production callers.

Non-HWE LTS is manual-only until its installer issue is resolved. Do not treat a successful build alone as production approval.

## Artifact flow

```text
caller
  -> reusable build
  -> testing storage and prerelease
  -> exact-candidate smoke validation
  -> manual promotion preview
  -> production storage and release
```

The smoke run must use the same prerelease tag and variant selected for promotion. Promotion excludes filenames containing `-testing-`.

## Source boundaries

System Flatpaks are sourced during the build. They are not maintained as a second local list in this repository.

Stable and LTS-family variants use different installer hooks. Read the matching hook before changing installer behavior. Do not create a new hook when an existing hook owns the requested value.

## Change rule

When a workflow, matrix entry, source, artifact, or gate changes, update this document and the matching procedure in `docs/skills/`. Keep executable behavior in the workflow or script; keep explanation here.
