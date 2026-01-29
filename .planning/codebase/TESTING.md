# Testing Patterns

**Analysis Date:** 2026-01-28

## Test Framework

**Runner:**
- No formal unit test framework detected
- Testing performed via:
  - Pre-commit hooks for validation
  - GitHub Actions workflows for integration testing
  - Manual local ISO builds for verification

**Validation Tools:**
- Pre-commit hooks (v4.4.0)
- Just command runner (for syntax checking)
- GitHub Actions (for ISO build verification)

**Run Commands:**
```bash
pre-commit run --all-files    # Run all validation hooks
just check                     # Validate Just syntax
just fix                       # Auto-fix formatting issues
```

## Test File Organization

**Location:**
- No dedicated test directory
- Validation workflows in `.github/workflows/`
- Pre-commit config at `.pre-commit-config.yaml`

**Naming:**
- Workflow files: `*-*.yml` (e.g., `pull-request.yml`, `validate-renovate.yml`)
- No `.test.*` or `.spec.*` files

**Structure:**
```
.github/workflows/
├── pull-request.yml          # PR validation
├── validate-renovate.yml     # Renovate config validation
├── reusable-build-iso-anaconda.yml  # Main ISO build testing
└── build-iso-*.yml           # Variant-specific builds
```

## Validation Structure

**Pre-commit Hooks:**
```yaml
repos:
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v4.4.0
    hooks:
        - id: check-json
        - id: check-toml
        - id: check-yaml
        - id: end-of-file-fixer
        - id: trailing-whitespace
```

**Patterns:**
- Run all hooks on all files before commit
- Automatic fixing for end-of-file and trailing whitespace
- Syntax validation for configuration files

## Workflow Testing

**PR Validation:**
- Workflow: `.github/workflows/pull-request.yml`
- Triggers: Pull requests to main branch
- Tests both LTS and Stable ISO builds
- Does not upload artifacts (fast validation)

**Pattern:**
```yaml
jobs:
  build-iso-lts:
    uses: ./.github/workflows/reusable-build-iso-anaconda.yml
    with:
      image_version: lts
      upload_r2: false
      upload_artifacts: false
```

**Manual Testing:**
- Workflow dispatch for manual builds
- Local ISO builds via Just recipes
- VM testing with `just run-iso`

## Build Validation

**ISO Build Process:**
1. Determine build matrix based on variant
2. Setup environment (maximize disk space)
3. Checkout and install Just
4. Format image reference
5. Build ISO using Titanoboa
6. Checksum generation
7. Upload to R2 or artifacts

**Validation Points:**
- Image reference validation
- Flatpak list validation
- ISO generation success
- Checksum creation

## Just Recipe Testing

**Syntax Validation:**
```just
# Check Just Syntax
check:
    #!/usr/bin/bash
    find . -type f -name "*.just" | while read -r file; do
    	echo "Checking syntax: $file"
    	{{ just }} --unstable --fmt --check -f $file
    done
    echo "Checking syntax: Justfile"
    {{ just }} --unstable --fmt --check -f Justfile
```

**Auto-fix Pattern:**
```just
# Fix Just Syntax
fix:
    #!/usr/bin/bash
    find . -type f -name "*.just" | while read -r file; do
    	echo "Checking syntax: $file"
    	{{ just }} --unstable --fmt -f $file
    done
    echo "Checking syntax: Justfile"
    {{ just }} --unstable --fmt -f Justfile || { exit 1; }
```

## Shell Script Validation

**No Automated Testing:**
- Scripts use strict error handling: `set -eoux pipefail`
- Manual syntax check: `bash -n script.sh`
- Testing via execution in CI/CD workflows

**Error Detection:**
- Exit on error (`-e`) catches most issues
- Undefined variable detection (`-u`)
- Pipeline failure detection (`-o pipefail`)
- Command echo (`-x`) aids debugging

## Image Validation

**Cosign Verification:**
Recipe `verify-container` validates container signatures:
- Fetches cosign tool if not present
- Verifies with public key
- Pattern:
  ```bash
  if ! cosign verify --key "${key}" "{{ registry }}"/"{{ container }}" >/dev/null; then
      echo "NOTICE: Verification failed. Please ensure your public key is correct."
      exit 1
  fi
  ```

**Secure Boot Validation:**
Recipe `secureboot` checks kernel signing:
- Extract vmlinuz from container
- Fetch public certificates
- Verify signatures with sbverify
- Exit with code 1 on failure

## Input Validation

**Parameter Validation:**
Recipe `validate` checks image/tag/flavor combinations:
```bash
validate $image $tag $flavor:
    #!/usr/bin/bash
    declare -A images={{ images }}
    declare -A tags={{ tags }}
    declare -A flavors={{ flavors }}
    
    # Validity Checks
    if [[ -z "$checkimage" ]]; then
        echo "Invalid Image..."
        exit 1
    fi
    # ... more checks
```

**Workflow Input Validation:**
- Matrix determination based on `image_version` input
- Default to Stable for PR validation
- Error messages for invalid combinations

## Coverage

**Requirements:** Not enforced (no coverage tooling)

**Test Coverage:**
- Pre-commit hooks: 100% of configuration files
- Workflow testing: ISO builds for all variants
- Manual testing: Local builds, VM testing

**Gaps:**
- No unit tests for bash functions
- No integration tests for Just recipes
- No automated tests for hook scripts in `iso_files/`

## Test Types

**Validation Tests:**
- Syntax validation for YAML, JSON, TOML
- Formatting validation for Just files
- Configuration file structure validation

**Integration Tests:**
- Full ISO build workflows in GitHub Actions
- Matrix builds across platforms and flavors
- End-to-end ISO generation from container images

**Manual Tests:**
- Local ISO builds: `just build-iso-ghcr bluefin stable main`
- VM testing: `just run-iso bluefin stable main`
- Smoke testing via workflow dispatch

## Common Patterns

**Workflow Dispatch Testing:**
```yaml
on:
  workflow_dispatch:
    inputs:
      upload_artifacts:
        type: boolean
        default: false
```
- Allows manual triggering for testing
- Controls artifact upload for debugging
- Useful for validating changes before merge

**Cleanup Pattern:**
```just
# Clean Repo
clean:
    #!/usr/bin/bash
    set -eoux pipefail
    touch _build
    find *_build* -exec rm -rf {} \;
    rm -f previous.manifest.json
    rm -f changelog.md
    rm -f output.env
```
- Clean build artifacts between tests
- Prevents interference from previous builds

**Conditional Testing:**
```yaml
# Only build on specific path changes
on:
  pull_request:
    paths:
      - ".github/workflows/reusable-build-iso-anaconda.yml"
      - "iso_files/configure_iso_anaconda.sh"
```
- Efficient CI by testing only affected components
- Reduces unnecessary workflow runs

## Error Testing

**ISO Build Failure Handling:**
- Titanoboa builds with `|| true` to continue cleanup
- Conditional steps based on previous step success
- Explicit ISO existence checks before operations

**Validation Failure Handling:**
- Pre-commit hooks fail fast on syntax errors
- Just check exits with code 1 on format violations
- Workflow matrix fails individual jobs without blocking others

## Performance Testing

**Not Implemented:**
- No performance benchmarks
- No timing measurements
- Build time tracked implicitly by GitHub Actions

**Resource Considerations:**
- ISO builds require 50GB+ disk space
- Parallel matrix builds for efficiency
- Conditional cleanup to free space in CI

## Best Practices

**Before Committing:**
1. Run `pre-commit run --all-files`
2. Run `just check` (if Just installed)
3. Fix issues with `just fix`
4. Test locally if modifying build logic

**Testing Workflow Changes:**
1. Test in fork first
2. Use workflow dispatch for manual testing
3. Monitor runner time and storage
4. Verify artifacts or R2 uploads

**Debugging Failed Builds:**
1. Check GitHub Actions logs for error messages
2. Review ISO build step output
3. Test locally with `just build-iso-ghcr`
4. Run VM tests with `just run-iso`

---

*Testing analysis: 2026-01-28*
