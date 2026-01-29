# Codebase Concerns

**Analysis Date:** 2026-01-28

## Tech Debt

**ISO Configuration Scripts - Extensive Inline Modifications:**
- Issue: Both `configure_iso_anaconda.sh` and `configure_lts_iso_anaconda.sh` use numerous `sed -i` commands to modify installed files in-place during ISO build
- Files: `iso_files/configure_iso_anaconda.sh`, `iso_files/configure_lts_iso_anaconda.sh`
- Impact: Fragile approach that breaks if upstream file formats change; difficult to test; no validation that modifications succeeded
- Fix approach: Consider using overlay files or configuration injection instead of string replacement; add validation checks after each sed command

**Duplicated Code Between Standard and LTS Scripts:**
- Issue: ~90% code duplication between `configure_iso_anaconda.sh` (208 lines) and `configure_lts_iso_anaconda.sh` (203 lines)
- Files: `iso_files/configure_iso_anaconda.sh`, `iso_files/configure_lts_iso_anaconda.sh`
- Impact: Bug fixes and improvements must be manually synchronized; easy to introduce inconsistencies
- Fix approach: Extract common functionality into shared functions or library script; use parameters to handle variant-specific logic

**Large Commented-Out Code Blocks in LTS Script:**
- Issue: Entire secure boot enrollment section (30+ lines) commented out; multiple brew-related service disables commented out
- Files: `iso_files/configure_lts_iso_anaconda.sh` (lines 9, 38-40, 44-46, 170-200)
- Impact: Unclear if features are temporarily disabled or permanently abandoned; dead code clutters codebase
- Fix approach: Either remove dead code with explanation in commit message, or document why it's disabled and conditions for re-enabling

**No Flatpak List Files in Repository:**
- Issue: Workflow pulls flatpaks from external GitHub repository (`projectbluefin/common`) at build time; no local flatpak list files found
- Files: `.github/workflows/reusable-build-iso-anaconda.yml` (line 177-179)
- Impact: ISO builds depend on external repository availability; no version control of flatpak selections in this repo; broken external link could break builds
- Fix approach: Mirror flatpak lists locally; use external source as fallback only; document sync process

**Hardcoded Python Version in Path:**
- Issue: LTS hotfix uses hardcoded Python 3.12 path for sed replacement
- Files: `iso_files/configure_lts_iso_anaconda.sh` (line 76)
- Impact: Will break when CentOS updates Python version; no error handling if path doesn't exist
- Fix approach: Use `find` or `python3 -c` to locate module dynamically; add validation that file exists before modification

## Known Bugs

**Duplicate anaconda-webui in LTS Package List:**
- Symptoms: `anaconda-webui` appears twice in SPECS array for LTS configuration
- Files: `iso_files/configure_lts_iso_anaconda.sh` (lines 62-63)
- Trigger: Every LTS ISO build
- Workaround: DNF ignores duplicate packages, but creates confusing logs

**Build-All Workflow Uses Wrong image_tag for Stable:**
- Symptoms: `build-iso-all.yml` passes LTS tag to Stable workflow instead of `stable` tag
- Files: `.github/workflows/build-iso-all.yml` (line 57)
- Trigger: Scheduled weekly builds and workflow dispatch on Tuesdays
- Workaround: Stable workflow overrides with `stable` in line 28 of `build-iso-stable.yml`, but inconsistent behavior

**Incomplete Error Handling in Service Disables:**
- Symptoms: Some `systemctl disable` commands lack `|| true` suffix; will fail if service doesn't exist
- Files: `iso_files/configure_iso_anaconda.sh` (lines 43-57), `iso_files/configure_lts_iso_anaconda.sh` (lines 35-48)
- Trigger: If base image removes any of these services
- Workaround: Some services may not exist, causing script to exit early with `set -e`

## Security Considerations

**Hardcoded Secure Boot Enrollment Password:**
- Risk: Secure boot MOK enrollment password "universalblue" is publicly visible in source
- Files: `iso_files/configure_iso_anaconda.sh` (line 183)
- Current mitigation: Password is only used for temporary MOK enrollment during install; user changes it post-install
- Recommendations: Document that this is a well-known temporary password; consider making it configurable via environment variable

**External Git Clone Without Verification:**
- Risk: Branding repository cloned without signature verification or commit pinning
- Files: `iso_files/configure_iso_anaconda.sh` (line 137), `iso_files/configure_lts_iso_anaconda.sh` (line 134)
- Current mitigation: Uses HTTPS; shallow clone limits exposure
- Recommendations: Pin to specific commit SHA or tag; verify git signatures; mirror critical assets locally

**Secure Boot Key Fetched Over HTTP(S) Without Verification:**
- Risk: Public key downloaded from GitHub without checksum or signature verification
- Files: `iso_files/configure_iso_anaconda.sh` (line 176)
- Current mitigation: Uses retry logic; only applies to standard (non-LTS) ISOs; URL uses GitHub (trusted source)
- Recommendations: Include checksum validation; consider embedding key in repository

**No Verification of External Flatpak Source:**
- Risk: Workflow fetches flatpak list from external repository without validation
- Files: `.github/workflows/reusable-build-iso-anaconda.yml` (line 177)
- Current mitigation: Uses HTTPS; official projectbluefin organization
- Recommendations: Validate file contents before use; implement checksum or signature verification

## Performance Bottlenecks

**Sequential ISO Builds in Matrix:**
- Problem: Matrix builds run sequentially if runner capacity is limited; each ISO takes 30-60 minutes
- Files: `.github/workflows/reusable-build-iso-anaconda.yml` (line 109-120)
- Cause: GitHub Actions runner availability; large ISO build operations
- Improvement path: Consider splitting into separate workflows that can run in parallel; optimize disk space cleanup steps

**Full Git Clone During Flatpak List Generation:**
- Problem: Clones entire `projectbluefin/common` repository just to extract flatpak list
- Files: `.github/workflows/reusable-build-iso-anaconda.yml` (line 177)
- Cause: Unnecessary full clone when only one file is needed
- Improvement path: Use sparse checkout or direct file download via raw.githubusercontent.com

**Unnecessary Package Installation During ISO Build:**
- Problem: Firefox installed in live environment but may already be available; multiple libblockdev packages installed
- Files: `iso_files/configure_iso_anaconda.sh` (lines 62-77), `iso_files/configure_lts_iso_anaconda.sh` (lines 56-70)
- Cause: Conservative package list ensures all dependencies present
- Improvement path: Audit which packages are truly needed vs already present in base image

## Fragile Areas

**ISO Hook Scripts:**
- Files: `iso_files/configure_iso_anaconda.sh`, `iso_files/configure_lts_iso_anaconda.sh`
- Why fragile: Uses `set -eoux pipefail` but has many operations that could fail; relies on specific file paths and string patterns in upstream files; no rollback mechanism
- Safe modification: Test in VM before committing; add validation steps after critical operations; use workflow dispatch for testing
- Test coverage: No automated tests; relies on manual ISO testing

**LTS Blivet/Dasbus Hotfix:**
- Files: `iso_files/configure_lts_iso_anaconda.sh` (line 76)
- Why fragile: String replacement in Python library code; hardcoded Python version path; could break with Python or Blivet updates
- Safe modification: Verify Python version matches before sed; add error handling; check if upstream fix is available
- Test coverage: None; only discovered at runtime if import fails

**Workflow Matrix Generation Logic:**
- Files: `.github/workflows/reusable-build-iso-anaconda.yml` (lines 41-107)
- Why fragile: Large case statement with manual JSON construction; easy to introduce syntax errors; no validation of matrix output
- Safe modification: Validate JSON with `jq` before output; use consistent formatting; test each case branch
- Test coverage: Only tested by actual workflow runs; no pre-merge validation

**Titanoboa Patching in Local Build Script:**
- Files: `hack/local-iso-build.sh` (lines 111-116)
- Why fragile: Patches third-party tool's Justfile with sed; assumes specific string patterns exist; breaks if Titanoboa changes
- Safe modification: Check if pattern exists before patching; consider forking Titanoboa with patches applied
- Test coverage: Only tested via local builds; no CI validation

**Service Disable List Synchronization:**
- Files: `iso_files/configure_iso_anaconda.sh` (lines 43-57), `iso_files/configure_lts_iso_anaconda.sh` (lines 35-48)
- Why fragile: Two different lists with some commented out in LTS; no documentation of why services are disabled or differences between variants
- Safe modification: Document reason for each disable; create shared list with variant overrides; add existence checks
- Test coverage: No validation that services actually exist before disabling

## Scaling Limits

**Single Reusable Workflow for All Variants:**
- Current capacity: Handles 8 total ISOs (4 LTS, 2 LTS-HWE, 2 Stable)
- Limit: Adding new variants requires modifying central workflow matrix
- Scaling path: Consider per-variant workflows that call even more generic base workflow; current structure still maintainable but approaching complexity limit

**GitHub Actions Runner Disk Space:**
- Current capacity: Uses maximization steps to create ~60GB free space
- Limit: ISO builds require 50GB+ per build; limited by runner constraints
- Scaling path: Already using cleanup actions; consider self-hosted runners with larger disks for parallel builds

**CloudFlare R2 Upload Bandwidth:**
- Current capacity: Sequential uploads of 4-8 ISOs per workflow run
- Limit: Each ISO is 3-5GB; slow network could cause timeouts
- Scaling path: Already uses rclone with checksums; consider parallel uploads or CDN distribution

## Dependencies at Risk

**Titanoboa Builder Dependency:**
- Risk: Local builds depend on third-party `hanthor/titanoboa` fork; uncertain maintenance status
- Impact: Local ISO builds could break; GitHub Actions use ublue-os/titanoboa which is maintained
- Migration plan: Standardize on ublue-os/titanoboa for both local and CI builds; update hack/local-iso-build.sh

**COPR Repository Dependency:**
- Risk: LTS builds depend on `jreilly1821/anaconda-webui` COPR repo; user-maintained, not official
- Impact: If COPR repo goes offline or removes packages, LTS ISO builds fail completely
- Migration plan: Mirror critical packages to ublue-os COPR; consider including in base image

**External Branding Repository:**
- Risk: Both scripts clone `projectbluefin/branding` at build time; no version pinning
- Impact: Breaking changes to branding repo could break all ISO builds
- Migration plan: Pin to commit SHA; mirror assets in this repository; consider embedding in base images

**External Flatpak Source:**
- Risk: Workflow fetches from `projectbluefin/common` Brewfile at build time
- Impact: If source repository changes format or goes offline, flatpak installation breaks
- Migration plan: Already noted above in "No Flatpak List Files" - mirror locally with sync process

## Missing Critical Features

**No ISO Build Validation Tests:**
- Problem: ISOs are built but not tested for bootability or installation success
- Blocks: Automated quality assurance; confidence in releases
- Priority: Medium - relies on manual testing currently

**No Automated Checksum Publication:**
- Problem: Checksums generated but not automatically published to download page or release notes
- Blocks: User verification of ISO integrity; security best practice
- Priority: Low - checksums exist in R2 bucket alongside ISOs

**No Incremental ISO Updates:**
- Problem: Every build creates full ISO from scratch; no delta/incremental updates
- Blocks: Faster builds; reduced bandwidth for recurring builds
- Priority: Low - current build times acceptable

## Test Coverage Gaps

**ISO Configuration Scripts:**
- What's not tested: All hook script functionality; sed replacements; service disables; package installations
- Files: `iso_files/configure_iso_anaconda.sh`, `iso_files/configure_lts_iso_anaconda.sh`
- Risk: Syntax errors, missing files, or failed operations only discovered during actual ISO builds (30+ minutes)
- Priority: High - consider shellcheck integration and dry-run testing

**Workflow Matrix Logic:**
- What's not tested: Matrix generation case statement; JSON syntax; platform/flavor combinations
- Files: `.github/workflows/reusable-build-iso-anaconda.yml` (lines 41-107)
- Risk: Invalid matrix breaks all ISO builds; only caught when workflow runs
- Priority: Medium - use workflow validation in pre-commit hooks

**Local Build Script:**
- What's not tested: Titanoboa patching; flatpak list parsing; hook script execution
- Files: `hack/local-iso-build.sh`
- Risk: Local builds diverge from CI builds; developers get different results
- Priority: Low - local builds are for development only

**Justfile ISO Recipes:**
- What's not tested: Complex recipe logic; image name formatting; validation functions
- Files: `Justfile` (lines 456-637)
- Risk: Recipes copied from main Bluefin repo may not work correctly in ISO-only context
- Priority: Low - recipes are development helpers, not production critical

---

*Concerns audit: 2026-01-28*
