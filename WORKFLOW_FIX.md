# Workflow Fix Documentation

## Issue Summary

Workflow run https://github.com/projectbluefin/iso/actions/runs/19023634490 failed immediately with all "Determine Build Matrix" jobs failing before any actual work could be done.

## Root Cause

The reusable workflow `.github/workflows/reusable-build-iso-anaconda.yml` declared three R2 CloudFlare secrets as **required**:

```yaml
secrets:
  R2_ACCESS_KEY_ID_2025:
    required: true  # ← This was the problem
  R2_SECRET_ACCESS_KEY_2025:
    required: true  # ← This was the problem
  R2_ENDPOINT_2025:
    required: true  # ← This was the problem
```

When a workflow calls a reusable workflow with required secrets, GitHub Actions validates that those secrets exist **before running any jobs**. Since the repository didn't have these secrets configured, all workflows failed immediately.

## Fix Applied

Changed all three R2 secrets to **optional** (`required: false`):

```yaml
secrets:
  R2_ACCESS_KEY_ID_2025:
    required: false  # ← Now optional
  R2_SECRET_ACCESS_KEY_2025:
    required: false  # ← Now optional
  R2_ENDPOINT_2025:
    required: false  # ← Now optional
```

### Why This Works

1. **With secrets configured & `upload_r2: true`**: Upload to R2 works normally
2. **Without secrets & `upload_r2: true`**: Upload step fails (expected behavior)
3. **Without secrets & `upload_r2: false`**: Workflow runs successfully, no upload attempted
4. **With `upload_artifacts: true`**: ISOs uploaded to GitHub artifacts (no secrets needed)

The upload step is already protected by a conditional:
```yaml
- name: Upload to CloudFlare
  if: inputs.upload_r2 && github.event_name != 'pull_request'
```

## Testing Performed

All tests passed successfully:

- ✅ YAML syntax validation for all 8 workflow files
- ✅ Reusable workflow structure validation
- ✅ Individual workflow structure validation (lts, lts-hwe, gts, stable)
- ✅ Orchestrator workflow structure validation (build-iso-all)
- ✅ Matrix generation logic validation
- ✅ Conditional upload logic validation
- ✅ Secrets reference validation

### Matrix Validation Results

| Variant  | ISOs Built | Platforms | Flavors |
|----------|------------|-----------|---------|
| lts      | 4          | amd64, arm64 | main, gdx |
| lts-hwe  | 2          | amd64, arm64 | main |
| gts      | 2          | amd64     | main, nvidia-open |
| stable   | 2          | amd64     | main, nvidia-open |
| all      | 10         | All above | All above |
| PR       | 4          | amd64     | gts + stable only |

## Next Steps for Repository Maintainers

To fully enable ISO uploads to CloudFlare R2, add these repository secrets:

1. Go to: `Settings` → `Secrets and variables` → `Actions`
2. Add three secrets:
   - `R2_ACCESS_KEY_ID_2025`
   - `R2_SECRET_ACCESS_KEY_2025`
   - `R2_ENDPOINT_2025`

Without these secrets:
- ✅ Workflows will run successfully
- ✅ ISOs will be built
- ✅ ISOs can be uploaded to GitHub artifacts (if `upload_artifacts: true`)
- ❌ ISOs will NOT be uploaded to R2 (unless secrets are configured)

## Workflow Usage

### Individual Workflows

Trigger any variant individually:
```bash
# Via GitHub UI: Actions → Select workflow → Run workflow
# Or via gh CLI:
gh workflow run build-iso-lts.yml
gh workflow run build-iso-lts-hwe.yml
gh workflow run build-iso-gts.yml
gh workflow run build-iso-stable.yml
```

### Orchestrator Workflow

Build all ISOs at once:
```bash
gh workflow run build-iso-all.yml
```

### Scheduled Builds

All workflows are scheduled to run automatically at **2am UTC on the 1st of every month**.

## Verification

To verify the fix works, trigger any workflow:

1. **Without R2 secrets configured**:
   - Workflow should run successfully
   - "Determine Build Matrix" should complete
   - Build job should execute
   - R2 upload step should be skipped (or fail if `upload_r2: true`)

2. **With R2 secrets configured**:
   - Everything above, plus:
   - R2 upload step should succeed when `upload_r2: true`

## Files Modified

- `.github/workflows/reusable-build-iso-anaconda.yml` - Made R2 secrets optional

## Additional Information

- All workflows use `secrets: inherit` to pass secrets from caller to reusable workflow
- Upload behavior is controlled by `upload_artifacts` and `upload_r2` inputs
- Pull requests never upload to R2 (protected by conditional)
- Default behavior: `upload_artifacts: false`, `upload_r2: true`
