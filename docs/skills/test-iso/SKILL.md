---
name: test-iso
description: Guides agents through ISO validation and evidence collection. Use when running smoke tests, installer E2E tests, local ISO boots, or investigating validation artifacts.
---

# Test ISO

## Use when

Use this skill for static checks, shell checks, local ISO boots, QEMU smoke validation, unattended installer tests, logs, screenshots, and proof artifacts.

## Do not use when

Do not use this skill to change production filters or promote a release. Use `release-iso` for those tasks.

## Procedure

1. Read `docs/qa.md`.
2. Run the smallest relevant static check.
3. Reproduce the behavior with a fresh ISO when installer behavior changes.
4. Use `.github/workflows/iso-smoke-test.yml` for candidate boot validation.
5. Use `.github/workflows/iso-e2e-test.yml` or the canonical `tests/iso/e2e.sh` harness for unattended installation changes. The `hack/` path is compatibility-only.
6. Preserve the exact candidate tag and variant in the test record.
7. Keep generated output outside the source patch.
8. Report failed or incomplete evidence as failed; never edit evidence to change its result.

## Verification

```bash
pre-commit run --all-files
actionlint .github/workflows/*.yml
just check
bash -n path/to/changed-script.sh
```

For the complete local suite (boot smoke plus unattended installation):

```bash
just test-iso PATH_TO_ISO iso-test-output
```

Or run only the installer E2E check:

```bash
E2E_POST_INSTALL_TIMEOUT=300 bash tests/iso/e2e.sh PATH_TO_ISO e2e-output
```

The installer E2E phase passes only after the installer reports completion and the installed system produces serial-console boot evidence.

A promotion candidate requires a successful matching smoke run. A run for another tag or variant is not evidence.

## Related documents

- [QA](../../qa.md)
- [Architecture](../../architecture.md)
- [Release procedure](../../release.md)
