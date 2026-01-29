# Secret Server Migration Toolkit - Testing Guide

This guide covers how to test the migration toolkit, from unit tests to full end-to-end migration testing.

---

## Quick Start

```powershell
# Run unit tests (no Secret Server needed)
pwsh ./Test-SSMigrate.ps1
pwsh ./Test-V3Infrastructure.ps1

# Both should show all tests passing
```

---

## Test Types

| Test Type | File | Requires SS? | Purpose |
|-----------|------|--------------|---------|
| Unit Tests | `Test-SSMigrate.ps1` | No | Core logic validation |
| Infrastructure Tests | `Test-V3Infrastructure.ps1` | No | v3.0+ ID mapping, checkpoints |
| End-to-End | Manual | Yes (2 tenants) | Full migration workflow |

---

## 1. Unit Tests (No Secret Server Required)

These tests validate core script logic without any network calls.

### On macOS

```bash
# Install PowerShell if not already installed
brew install powershell/tap/powershell

# Navigate to toolkit directory
cd /path/to/ss-migration-toolkit

# Run unit tests
pwsh ./Test-SSMigrate.ps1

# Run v3.0 infrastructure tests
pwsh ./Test-V3Infrastructure.ps1
```

### On Windows

```powershell
# Install PowerShell 7 if not already installed
winget install Microsoft.PowerShell

# Open PowerShell 7 (not Windows PowerShell)
pwsh

# Navigate to toolkit directory
cd C:\path\to\ss-migration-toolkit

# Set execution policy if needed
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser

# Run unit tests
.\Test-SSMigrate.ps1

# Run v3.0 infrastructure tests
.\Test-V3Infrastructure.ps1
```

### Expected Output

```
╔═══════════════════════════════════════════════════════════════╗
║  SS-MIGRATE v3.0 INFRASTRUCTURE TESTS                         ║
╚═══════════════════════════════════════════════════════════════╝

═══ ID Mapping Infrastructure ═══
  ✓ Clear ID Maps
  ✓ Set-IdMapping for Sites
  ✓ Set-IdMapping for Templates
  ...

═══════════════════════════════════════════════════════════════
  RESULTS: 51 passed, 0 failed
═══════════════════════════════════════════════════════════════
```

---

## 2. Setting Up Test Secret Server Tenants

For end-to-end testing, you need two Secret Server instances:
- **Source**: Contains secrets to migrate
- **Target**: Empty or test environment to receive secrets

### Option A: Secret Server Cloud Trial

1. Request two SSC trial tenants from Delinea
2. Each trial gives you a separate cloud instance
3. URLs will be like: `https://source.secretservercloud.com` and `https://target.secretservercloud.com`

### Option B: On-Premise VMs

1. Set up two Windows Server VMs
2. Install Secret Server on each (evaluation license)
3. Ensure network connectivity between your test machine and both servers

### Option C: Use Existing Dev/Test Tenants

If your team has existing dev/test Secret Server instances, use those. Just ensure:
- You have admin access to both
- Target can be safely modified (secrets will be created)

### Tenant Configuration Checklist

On **both** source and target:

- [ ] Web Services enabled (Admin > Configuration > General)
- [ ] Create API user account (or use existing admin)
- [ ] Note the URL and credentials

On **target** only:

- [ ] "Allow Duplicate Secret Names" enabled (Admin > Configuration > General)
- [ ] Ensure secret templates exist that match source (or use built-in templates)

---

## 3. Generating Test Data

Use `ss-generate.ps1` to populate your source tenant with test secrets.

### Basic Usage

```powershell
# Interactive mode - prompts for everything
pwsh ./ss-generate.ps1

# Generate specific count
pwsh ./ss-generate.ps1 -Count 100
```

### What It Creates

- Secrets using built-in templates (Windows Account, Unix Account, etc.)
- Random but realistic-looking names and values
- Distributed across folders (if folders exist)

### Recommended Test Scenarios

| Scenario | Secret Count | Purpose |
|----------|--------------|---------|
| Smoke test | 10-20 | Verify basic functionality |
| Small migration | 100-500 | Test checkpoint/resume |
| Medium migration | 1,000-5,000 | Test performance |
| Large migration | 10,000+ | Stress test (expect 2-3 hours) |

### Creating Test Folders and Policies

The generator creates secrets, but for full v3.0 testing you may want:

1. **Folders**: Create a folder hierarchy manually in source SS
2. **Policies**: Create 1-2 secret policies with checkout enabled
3. **RPC Setup**: If testing v3.1 features, create a custom Script and Password Type

---

## 4. Running End-to-End Migration Test

### Step 1: Verify Connectivity

```powershell
pwsh ./ss-migrate.ps1
```

Enter credentials for both source and target. The pre-flight check will verify:
- Authentication works
- Permissions are sufficient
- Sites and templates can be mapped

### Step 2: Run Export Only (Safe)

The wizard will prompt you through:
1. Connect to source and target
2. Pre-flight validation
3. Choose migration mode (Secrets Only or Full Migration)
4. Export from source

At the **import** step, you can cancel to inspect the export file first:

```powershell
# View export file (contains secrets - handle securely!)
Get-Content ss-export-*.json | ConvertFrom-Json | Select-Object -First 5
```

### Step 3: Run Full Migration

Continue through the wizard:
1. Dry run (shows what would be created)
2. Actual import (creates objects on target)
3. Validation (compares counts)

### Step 4: Verify Results

After migration completes:

**In Target Secret Server UI:**
- [ ] Secrets appear in correct folders
- [ ] Secret values are correct (spot check a few)
- [ ] Policies are applied to folders
- [ ] Custom fields preserved

**For v3.1 (RPC Infrastructure):**
- [ ] Scripts appear in Admin > Scripts
- [ ] Password Types appear in Admin > Remote Password Changing > Password Types
- [ ] Password Types reference correct Scripts
- [ ] Lists appear in Admin > Lists with all options
- [ ] Test RPC heartbeat on a migrated secret

---

## 5. Testing Specific Features

### Test Checkpoint/Resume

1. Start a migration with 500+ secrets
2. Cancel mid-import (Ctrl+C)
3. Resume:
   ```powershell
   pwsh ./ss-migrate.ps1 -Resume
   ```
4. Verify it picks up where it left off (check log for "Skipping already imported")

### Test Duplicate Handling

1. Run migration once
2. Run again without clearing target
3. Verify duplicates are handled per policy (log shows "already exists")

### Test Circular RPC Detection

1. On source, create two secrets that reference each other as privileged accounts
2. Run migration
3. Verify warning E3006 appears and migration completes
4. One RPC link will need manual configuration on target

### Test v3.1 Script/PasswordType Migration

1. On source, create:
   - A custom PowerShell script (Admin > Scripts)
   - A custom Password Type using that script
   - A secret using that Password Type
2. Run Full Migration
3. Verify on target:
   - Script exists with correct content
   - Password Type exists and references the new Script ID
   - Secret can perform RPC heartbeat

---

## 6. Troubleshooting Tests

### Unit Tests Fail to Load

```
The term 'xxx' is not recognized...
```

**Fix**: Ensure you're running PowerShell 7, not Windows PowerShell:
```powershell
pwsh --version  # Should show 7.x.x
```

### Authentication Fails in E2E Test

**Check**:
- URL includes `https://`
- User account is not locked
- Web Services enabled on Secret Server
- No MFA required for API user

### Export Works But Import Fails

**Check**:
- Target permissions (Create Secret, Create Folder for Full mode)
- Templates exist on target with matching names
- "Allow Duplicate Secret Names" if re-running

### Tests Pass But Migration Fails

Unit tests don't cover network/API issues. Check:
- `ss-migrate-*.log` for detailed errors
- Network connectivity to both servers
- Rate limiting (increase ThrottleDelayMs if needed)

---

## 7. Test Artifacts

After testing, these files are created:

| File | Contains Secrets? | Action |
|------|-------------------|--------|
| `ss-migrate-*.log` | No (names only) | Keep for debugging |
| `ss-export-*.json` | **YES** | Delete after testing |
| `ss-migrate-checkpoint.json` | No | Delete to start fresh |
| `ss-migrate-failures.json` | No | Review failed items |
| `ss-migrate-idmap.json` | No | Useful for verification |

**Security**: Always delete `ss-export-*.json` after testing - it contains actual secret values.

---

## 8. Continuous Integration (Optional)

For automated testing in CI/CD:

```yaml
# Example GitHub Actions workflow
name: Unit Tests
on: [push, pull_request]

jobs:
  test:
    runs-on: ${{ matrix.os }}
    strategy:
      matrix:
        os: [ubuntu-latest, windows-latest, macos-latest]

    steps:
      - uses: actions/checkout@v4

      - name: Install PowerShell
        if: runner.os == 'Linux'
        run: |
          sudo apt-get update
          sudo apt-get install -y powershell

      - name: Run Unit Tests
        run: pwsh ./Test-SSMigrate.ps1

      - name: Run Infrastructure Tests
        run: pwsh ./Test-V3Infrastructure.ps1
```

---

## Quick Reference

```powershell
# Unit tests (always run these first)
pwsh ./Test-SSMigrate.ps1
pwsh ./Test-V3Infrastructure.ps1

# Generate test data on source
pwsh ./ss-generate.ps1 -Count 100

# Run migration
pwsh ./ss-migrate.ps1

# Resume interrupted migration
pwsh ./ss-migrate.ps1 -Resume

# Start fresh (delete checkpoint)
Remove-Item ss-migrate-checkpoint.json
pwsh ./ss-migrate.ps1
```

---

## Support

If tests fail unexpectedly:

1. Check `TROUBLESHOOTING.md` for common issues
2. Review log file: `Get-Content ss-migrate-*.log | Select-Object -Last 50`
3. Contact WW Architecture Team with:
   - PowerShell version (`$PSVersionTable`)
   - OS version
   - Test output / error messages
