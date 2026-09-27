# QA and validation

This document owns validation commands, test levels, and release evidence. Do not treat generated test output as source.

## Static checks

Run the checks relevant to the change:

```bash
pre-commit run --all-files
actionlint .github/workflows/*.yml
just check
```

For changed shell scripts:

```bash
bash -n path/to/script.sh
```

Run `pre-commit` and `actionlint` before handoff. `just check` validates Just syntax.

## Local ISO validation

Use the existing recipes:

```bash
just local-iso-bluefin
just local-iso-lts
```

Run the complete local suite against an ISO with both QEMU boot smoke and unattended installation checks:

```bash
just test-iso PATH_TO_ISO [OUTPUT_DIRECTORY]
```

The default output directory is `iso-test-output/`; it contains separate `smoke/` and `e2e/` proof artifacts. The command runs both checks and fails if either check fails.

ISO creation requires root for the Titanoboa loop-device step. After changing an installer hook, rebuild the ISO and boot the new artifact. Do not patch a running VM and use that state as evidence.

## Smoke validation

`.github/workflows/iso-smoke-test.yml` validates the exact prerelease asset set that promotion will use. A passing result is required before promotion, including a dry-run preview.

Review the workflow summary and downloaded proof artifacts. Record the prerelease tag, variant, workflow URL, result summary, serial log, and screen or proof artifacts when triaging a failure.

## Installer E2E validation

`.github/workflows/iso-e2e-test.yml` invokes the canonical `tests/iso/e2e.sh` harness (with `hack/iso-e2e-test.sh` retained as a compatibility entry point) to exercise unattended installation under QEMU. Use this path when the change affects installation, disk setup, boot, or post-install behavior.

The harness writes logs, screenshots, summary data, and proof files to its output directory. It passes only after the installer reports completion and the installed system produces serial boot evidence. `E2E_INSTALL_TIMEOUT` (default 2700 seconds) and `E2E_POST_INSTALL_TIMEOUT` (default 180 seconds) can tune the two phases. Keep generated files out of source changes.

The kickstart is delivered inside the initramfs, not over the network: the harness appends a gzip cpio overlay to the ISO's `initramfs.img` that carries the rendered kickstart plus a `e2e-kickstart.service` initrd unit, which copies it to `/run/install/ks.cfg` before switch-root. That is the only path anaconda reads for `inst.ks=`, and the titanoboa initramfs has no anaconda dracut module to fetch a URL into it. If the serial log ends with `Kickstart file /run/install/ks.cfg is missing.`, the overlay did not unpack or the unit did not run; check for `e2e-kickstart.service` in the initrd portion of `installer-serial.log`.

The kickstart's `ostreecontainer --url` is read from the ISO itself: the harness pulls `var/lib/containers/storage/overlay-images/images.json` out of `/LiveOS/squashfs.img` (`squashfs-tools`) and uses the name the build stored the payload under, so the E2E cannot ask anaconda for an image the ISO does not carry (the nvidia-open ISO embeds `bluefin-nvidia-open`). `IMAGE_REF`/`IMAGE_TAG` only disambiguate if an ISO ever carries several images. The kickstart's `%pre` and `%pre-install` blocks print `e2e-pre:` and `e2e-pre-install:` lines to the serial log with the installer's own view of the store, the latter immediately before the payload step.

Budget note: anaconda's optional Subscription DBus module fails to activate in this image and dbus waits its full 600-second `service_start_timeout` before installation starts (`Failed to activate service 'org.fedoraproject.Anaconda.Modules.Subscription': timed out`). The install timeout includes that dead time.

## Failure rules

- A failed smoke run blocks promotion.
- A smoke run for another tag or variant is not evidence for the current candidate.
- A missing or incomplete result is not a pass.
- Do not replace failed evidence with a manually edited summary.
- Fix the owning workflow, hook, or script, then rerun the relevant test.

For published ISO URLs, `.github/workflows/iso-testsuite.yml` invokes the dedicated `projectbluefin/testsuite` ISO workflow. Pass the exact ISO URL and an immutable `iso_ref`; testsuite runs smoke plus unattended E2E by default and uploads the same proof artifacts. This is additive external validation and does not replace the repository-local promotion gate.

## Documentation rule

When a command, artifact, test gate, or required evidence changes, update this document and `docs/skills/test-iso/SKILL.md` in the same change.
