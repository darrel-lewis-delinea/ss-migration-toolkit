# Secret Server Migration Toolkit - Troubleshooting Guide

## Quick Diagnostics

Run these commands to gather diagnostic info:

```powershell
# Check PowerShell version
$PSVersionTable.PSVersion

# Check TLS
[Net.ServicePointManager]::SecurityProtocol

# Test connectivity to Secret Server
Test-NetConnection -ComputerName "your-server.secretservercloud.com" -Port 443
```

---

## Common Issues

### Installation Issues

#### "The term 'pwsh' is not recognized"

**Problem:** PowerShell 7 is not installed or not in PATH.

**Solution:**
```powershell
# Windows - install via winget
winget install Microsoft.PowerShell

# macOS - install via Homebrew
brew install powershell/tap/powershell

# After install, restart your terminal
```

#### "File cannot be loaded because running scripts is disabled"

**Problem:** PowerShell execution policy blocks scripts (Windows).

**Solution:**
```powershell
# Option 1: Change policy for current user
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser

# Option 2: Bypass for this session only
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process

# Option 3: Run with explicit bypass
pwsh -ExecutionPolicy Bypass -File ./ss-migrate.ps1
```

---

### Authentication Issues

#### "Authentication failed: 401 Unauthorized"

**Problem:** Invalid username or password.

**Solutions:**
1. Verify credentials work in the Secret Server web UI
2. Check if account is locked out
3. Ensure you're using the correct domain prefix (if required)
4. Check if MFA is required (API may not support MFA)

#### "Authentication failed: Unable to connect"

**Problem:** Cannot reach Secret Server.

**Solutions:**
```powershell
# Test connectivity
Test-NetConnection -ComputerName "your-server.secretservercloud.com" -Port 443

# Check DNS resolution
Resolve-DnsName "your-server.secretservercloud.com"

# Check for proxy requirements
$env:HTTPS_PROXY = "http://proxy.company.com:8080"
```

#### "Authentication failed: The underlying connection was closed"

**Problem:** TLS version mismatch.

**Solutions:**
```powershell
# Verify TLS is configured (script does this automatically)
[Net.ServicePointManager]::SecurityProtocol

# Should show: Tls12 or Tls13
# If not, the script sets this automatically - check for proxy/firewall interference
```

---

### Permission Issues

#### "Can list secrets: False"

**Problem:** User account lacks permission to view secrets.

**Solution:**
1. In Secret Server, go to Admin > Users
2. Find your API user account
3. Ensure it has "View Secret" role permission
4. Or add user to a group with appropriate permissions

#### "Can create secrets: False"

**Problem:** User account lacks permission to create secrets on target.

**Solution:**
1. Target instance needs "Create Secret" permission
2. User needs access to the target folders
3. Check if folder permissions are restricting creation

---

### Export Issues

#### "Export stalls at X secrets"

**Problem:** API timeout or rate limiting.

**Solutions:**
1. **Check checkpoint file** - you can resume:
   ```powershell
   ./ss-migrate.ps1 -Resume
   ```

2. **Reduce batch size** (edit script):
   ```powershell
   $script:Config.BatchSize = 250  # Default is 500
   ```

3. **Increase throttle delay** (edit script):
   ```powershell
   $script:Config.ThrottleDelayMs = 200  # Default is 100
   ```

#### "Export file is empty or corrupted"

**Problem:** Export was interrupted before completion.

**Solution:**
1. Delete the partial export file
2. Clear the checkpoint: delete `ss-migrate-checkpoint.json`
3. Re-run export

---

### Import Issues

#### "Failed: Secret name already exists"

**Problem:** Target has duplicate name restriction enabled.

**Solutions:**

**Option 1: Allow duplicates on target**
1. In target Secret Server: Settings > Configuration > General
2. Find "Allow Duplicate Secret Names"
3. Set to "Allow Duplicates"

**Option 2: Clean up existing secrets**
- If this is a fresh migration, ensure target is empty first

#### "Failed: Secret template not found"

**Problem:** Template IDs don't match between source and target.

**Solution:**
1. Ensure both instances have the same secret templates
2. Template IDs must match, or you need to create a mapping
3. For custom templates, recreate them on target first

#### "Failed: Folder not found"

**Problem:** Target doesn't have matching folder structure.

**Solutions:**
1. Create matching folder structure on target first
2. Or import to a single folder (modify folderId in export file)

#### "Import stalls after X secrets"

**Problem:** API timeout or rate limiting.

**Solution:**
```powershell
# Resume from checkpoint
./ss-migrate.ps1 -Resume
```

The checkpoint tracks exactly which secrets were imported. Resume will skip already-imported secrets.

---

### Validation Issues

#### "Count mismatch: Source X, Target Y"

**Problem:** Number of secrets doesn't match after migration.

**Causes:**
1. Some secrets failed to import (check log file)
2. Target had existing secrets before migration
3. Source has secrets in folders you can't access

**Solution:**
1. Check log file for "FAILED:" entries
2. Count only newly created secrets
3. Re-run failed secrets manually or via retry

#### "Spot check: X/Y secrets verified" (with failures)

**Problem:** Some secrets exist on source but not found on target.

**Causes:**
1. Search matching issues (special characters in names)
2. Secrets in inaccessible folders on target
3. Import failures

**Solution:**
1. Search for specific missing secrets in target web UI
2. Check if folder permissions are hiding them
3. Review log file for import errors

---

### Performance Issues

#### "Migration is taking too long"

**Expected performance (40,000 secrets):**
- Export: 60-90 minutes
- Import: 60-90 minutes
- Total: 2-3 hours

**To improve performance:**
```powershell
# Edit these values in the script
$script:Config.BatchSize = 1000        # Increase batch size
$script:Config.ThrottleDelayMs = 50    # Reduce delay
```

**Note:** July 2025 SSC release improved bulk operations by ~20% for large migrations.

---

### Recovery Procedures

#### Resume Failed Migration

```powershell
# Check if checkpoint exists
ls ss-migrate-checkpoint.json

# Resume from checkpoint
./ss-migrate.ps1 -Resume
```

#### Restart Fresh (Discard Progress)

```powershell
# Delete checkpoint and export
rm ss-migrate-checkpoint.json
rm ss-export-*.json

# Start over
./ss-migrate.ps1
```

#### Manual Cleanup After Failed Import

If you need to remove partially imported secrets from target:

1. Check the log file for imported secret IDs
2. In Secret Server web UI, search for recently created secrets
3. Delete or deactivate as needed
4. Re-run migration

---

## Log File Analysis

### Finding the Log File

```powershell
# Log files are timestamped
ls ss-migrate-*.log

# View recent entries
Get-Content ss-migrate-2026-01-27-*.log | Select-Object -Last 50
```

### Understanding Log Entries

```
[2026-01-27 15:30:00] [Info] Starting export from https://source.com
[2026-01-27 15:30:01] [Success] Authentication successful
[2026-01-27 15:35:00] [Warning] Retrying in 2 seconds...
[2026-01-27 15:40:00] [Error] FAILED: SecretName - Error message
```

### Finding All Failures

```powershell
# Extract all failed secrets
Select-String -Path ss-migrate-*.log -Pattern "FAILED:"
```

---

## Getting Help

If you encounter issues not covered here:

1. **Check the log file** - Most errors include detailed messages
2. **Review REFERENCES.md** - Links to Delinea documentation
3. **Contact WW Architecture Team** - For Delinea-internal support
4. **Delinea Support** - Note: Migration is not officially supported

### Information to Gather for Support

```powershell
# Collect this info before requesting help:

# 1. PowerShell version
$PSVersionTable | Format-List

# 2. Last 100 log lines
Get-Content ss-migrate-*.log | Select-Object -Last 100

# 3. Checkpoint state (if exists)
Get-Content ss-migrate-checkpoint.json

# 4. Error message (screenshot or copy)
```
