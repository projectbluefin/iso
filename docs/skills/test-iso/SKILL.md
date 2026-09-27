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

## Harness internals worth knowing

- The install VM boots the ISO's extracted `vmlinuz` and `initramfs.img` directly; the ISO is only the live root. That initramfs (titanoboa: `dracut --add "dmsquash-live ..."`) has no anaconda dracut module, so `inst.ks=<url>` is never fetched. `e2e.sh` appends a gzip cpio overlay carrying `/etc/e2e/ks.cfg` and an initrd unit that copies it to `/run/install/ks.cfg` (the only path anaconda's `inst.ks=` option reads) before switch-root. Needs `cpio` and `gzip` on the runner.
- The kickstart's `ostreecontainer --url=… --transport=containers-storage` must name the image exactly as the ISO's embedded store knows it: titanoboa `podman pull`s the build's image ref into the live root's `/var/lib/containers/storage`, and anaconda resolves the URL against that store, not a registry. `e2e.sh` reads the stored names out of the ISO (`unsquashfs` on `/LiveOS/squashfs.img` → `var/lib/containers/storage/overlay-images/images.json`) and uses them; `IMAGE_REF`/`IMAGE_TAG` only choose between stored images. Needs `squashfs-tools`. `Using kickstart ostreecontainer --url=…` in the harness output and the `e2e-pre:` lines in `installer-serial.log` (a `%pre` that lists `podman images` and runs `skopeo inspect` on the chosen URL inside the installer) show what was asked for and what the installer saw.
- `installer-serial.log` is the first thing to read on a failure. `Kickstart file /run/install/ks.cfg is missing.` means the overlay was not applied. `Installer did not report completion` with anaconda logs present means the install itself was slow or wedged; the Subscription DBus module always burns 600 seconds before installation starts, which the default `E2E_INSTALL_TIMEOUT` already accounts for.
- Serial logs are dominated by `brltty` noise; filter it (`grep -v brltty`) before reading anaconda output.

## Related documents

- [QA](../../qa.md)
- [Architecture](../../architecture.md)
- [Release procedure](../../release.md)
