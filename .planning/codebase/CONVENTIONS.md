# Coding Conventions

**Analysis Date:** 2026-01-28

## Naming Patterns

**Files:**
- Bash scripts: `snake_case.sh` (e.g., `configure_iso_anaconda.sh`, `configure_lts_iso_anaconda.sh`, `local-iso-build.sh`)
- YAML workflows: `kebab-case.yml` (e.g., `build-iso-stable.yml`, `reusable-build-iso-anaconda.yml`)
- Just recipes: `kebab-case.just` (e.g., `bluefin-apps.just`, `bluefin-system.just`)
- Main Just file: `Justfile` (capitalized)

**Functions:**
- Just recipes use lowercase with hyphens: `build-iso`, `build-iso-ghcr`, `local-iso-lts`
- Bash functions (if any) use snake_case

**Variables:**
- Environment variables: UPPERCASE with underscores (e.g., `IMAGE_REGISTRY`, `IMAGE_NAME`, `BUILD_VERSION`)
- Just variables: lowercase with underscores (e.g., `repo_organization`, `rechunker_image`)
- Bash local variables: lowercase with underscores (e.g., `image_name`, `build_dir`, `flatpak_refs`)

**Workflow Jobs:**
- Job IDs: `kebab-case` (e.g., `build-iso-stable`, `determine-matrix`)
- Job names: Title Case (e.g., "Build Stable ISOs", "Determine Build Matrix")

## Code Style

**Formatting:**
- YAML files: 2-space indentation, checked by `pre-commit` with `check-yaml` hook
- Just files: Checked and formatted with `just --unstable --fmt --check` and `just --unstable --fmt`
- Bash scripts: Use `set -eoux pipefail` for strict error handling
- Leading triple-hyphen `---` for YAML files

**Linting:**
- Pre-commit hooks enforce validation:
  - `check-json` - JSON syntax validation
  - `check-toml` - TOML syntax validation
  - `check-yaml` - YAML syntax validation
  - `end-of-file-fixer` - Ensures newline at EOF
  - `trailing-whitespace` - Removes trailing spaces
- Just syntax checked with: `just check`
- Just auto-formatting: `just fix`

## Import Organization

**Not applicable** - This is a shell/YAML/Just codebase without traditional imports.

**Path References:**
- Absolute paths in workflows: `/var/home/jorge/src/iso/...` or relative with `${{ github.workspace }}`
- Relative paths in Just recipes: `./`, `../` from execution context
- Environment variable paths: `${PWD}`, `${REPO_ROOT}`

## Error Handling

**Patterns:**
- Bash scripts universally use: `set -eoux pipefail`
  - `e` - Exit on error
  - `o pipefail` - Fail on pipe errors
  - `u` - Error on undefined variables
  - `x` - Print commands (for debugging)
- Alternative in `hack/local-iso-build.sh`: `set -euo pipefail` (no `-x` for cleaner output)
- Just recipes use shebang: `#!/usr/bin/bash` or `#!/usr/bin/env bash`
- Workflow failure handling: Use `|| true` for non-critical commands (e.g., `dnf config-manager --set-disabled centos-hyperscale &>/dev/null || true`)

**Exit codes:**
- Explicit exit codes in validation: `exit 1` on failure
- Successful completion: implicit or explicit `exit 0`

## Logging

**Framework:** Standard shell output (no logging framework)

**Patterns:**
- Use `echo` for informational messages
- Colored output in `hack/local-iso-build.sh`: ANSI escape codes (e.g., `\033[1;32m`, `\033[1;33m`)
- Workflow grouping in Justfile: `echo "::group:: Build Prep"` and `echo "::endgroup::"` for GitHub Actions
- Debug output: Automatic via `set -x` in scripts
- Error messages: Direct to stderr with `echo "Error: ..." >&2`

## Comments

**When to Comment:**
- Document purpose at script start
- Explain complex logic (e.g., workflow matrix determination)
- Clarify non-obvious configuration (e.g., Anaconda profile settings)
- Annotate disabled code sections (e.g., secureboot in LTS: `# sbkey='...'` line 9)
- Provide examples for complex recipes (e.g., `just retag-nvidia-on-ghcr` examples at line 860-869)

**Style:**
- Shell scripts: `# Single line comments`
- YAML workflows: `# Inline comments` for explanation
- Multi-line comment blocks for major sections:
  ```bash
  # Configure Live Environment
  
  # Setup dock
  ```

## Script Structure

**Shebangs:**
- Bash scripts: `#!/usr/bin/env bash` (portable)
- Just recipe blocks: `#!/usr/bin/bash` (assumes system bash)

**Script Organization:**
1. Shebang
2. Error handling setup (`set -eoux pipefail`)
3. Variable declarations
4. Input parsing/validation
5. Main logic
6. Cleanup/output

**Example from `hack/local-iso-build.sh`:**
```bash
#!/usr/bin/env bash
set -euo pipefail

# Variables
GITHUB_REPOSITORY_OWNER="${GITHUB_REPOSITORY_OWNER:-ublue-os}"

# Input parsing
variant="${1:-lts}"
flavor="${2:-base}"

# Validation
if [ "$variant" == "lts" ]; then
    # ...
fi

# Main logic
# ...
```

## Workflow Structure

**Caller Workflows:**
- Minimal structure: triggers, single job calling reusable workflow
- No `permissions:` block in caller workflows
- Use `secrets: inherit` for secret passing
- Standard inputs: `upload_artifacts`, `upload_r2`
- Example pattern in `build-iso-stable.yml`:
  ```yaml
  ---
  name: Build Stable ISOs
  on:
    workflow_dispatch:
      inputs:
        upload_artifacts:
          type: boolean
        upload_r2:
          type: boolean
    schedule:
      - cron: '0 2 1 * *'
  
  jobs:
    build-iso-stable:
      uses: ./.github/workflows/reusable-build-iso-anaconda.yml
      secrets: inherit
      with:
        image_version: stable
  ```

**Reusable Workflows:**
- Complex logic encapsulated
- Matrix strategy for parallel builds
- Conditional logic based on inputs
- Permissions managed internally

## Just Recipe Patterns

**Recipe Groups:**
- Use `[group('Category')]` attribute for organization
- Categories: `Just`, `Utility`, `Image`, `ISO`, `Apps`, `Admin`

**Private Recipes:**
- Mark with `[private]` attribute for internal helpers

**Recipe Documentation:**
- Comment above recipe describing purpose
- Example: `# Check Just Syntax` above `check:` recipe

**Parameter Defaults:**
- Provide sensible defaults: `image="bluefin" tag="latest" flavor="main"`
- Quote string defaults: `$image="bluefin"`

**Recipe Body Structure:**
```just
recipe-name param1="default" param2="default":
    #!/usr/bin/bash
    set -eoux pipefail
    
    # Validate inputs
    {{ just }} validate "${param1}" "${param2}"
    
    # Main logic
    # ...
```

## Configuration File Patterns

**Anaconda Profiles:**
- INI-style configuration in kickstart scripts
- Sections in brackets: `[Profile]`, `[Bootloader]`, `[Storage]`
- Key-value pairs: `profile_id = bluefin`
- Embedded in bash with here-docs: `tee /etc/anaconda/profile.d/bluefin.conf <<'EOF'`

**GNOME Schema Overrides:**
- GSettings format embedded in bash
- Numeric types explicitly typed: `idle-delay=uint32 0`
- Arrays with bracket notation: `favorite-apps = ['item1', 'item2']`

**Environment Variables:**
- Uppercase with underscores
- Defaults using shell parameter expansion: `${VAR:-default}`
- Export for cross-process use: `export SUDO_DISPLAY := ...`

## String Quoting

**Bash:**
- Double quotes for variable interpolation: `"${variable}"`
- Single quotes for literal strings: `'literal string'`
- Here-docs with single quotes for no interpolation: `<<'EOF'`
- Here-docs without quotes for interpolation: `<<EOF`

**YAML:**
- Single quotes for strings with special chars: `'0 2 1 * *'`
- No quotes for simple strings: `type: boolean`
- Use `>` or `|` for multi-line strings

## Commit Conventions

**Format:** Conventional Commits (enforced by repository)

**Types:**
- `feat:` - New features
- `fix:` - Bug fixes
- `docs:` - Documentation changes
- `ci:` - CI/CD workflow changes
- `chore:` - Maintenance tasks
- `refactor:` - Code refactoring

**Scope Examples:**
- `feat(iso):`
- `fix(flatpaks):`
- `ci(workflow):`

**AI Attribution:**
- Required footer: `Assisted-by: [Model] via [Tool]`

---

*Convention analysis: 2026-01-28*
