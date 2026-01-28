# Secret Server Migration Toolkit

Interactive wizard for migrating secrets between Secret Server instances using the REST API.

**Version:** 2.2.4
**Author:** Delinea WW Architecture Team
**Date:** January 2026

---

## Why This Tool?

Unlike CSV import, this toolkit preserves all secret fields including expiration dates. The July 2025 Secret Server release optimized bulk operations for "tens of thousands of secrets" with 20% performance improvement. This toolkit leverages those improvements.

---

## Quick Start

### 1. Install PowerShell 7+

```bash
# Windows
winget install Microsoft.PowerShell

# macOS
brew install powershell/tap/powershell

# Linux (Ubuntu)
sudo apt-get install powershell
```

### 2. Run the Wizard

```powershell
pwsh ./ss-migrate.ps1
```

### 3. Follow the Prompts

The interactive wizard guides you through:
1. **Connect** - Enter source and target URLs + credentials
2. **Pre-flight** - Validates connectivity and permissions
3. **Export** - Pulls all secrets from source
4. **Dry Run** - Shows what would be imported (no changes)
5. **Import** - Creates secrets on target (requires confirmation)
6. **Validate** - Compares source and target

---

## Features

**Interactive Wizard**
- Guided prompts for all inputs
- Color-coded output (green=success, yellow=warning, red=error)
- Progress bars with ETA

**Safety First**
- Mandatory dry-run before actual import
- Explicit confirmation for destructive operations
- Checkpoint-based resume if interrupted

**Full Field Preservation**
- Secret expiration dates (unlike CSV import)
- Custom fields
- Folder structure
- Auto-change settings

**Security**
- Credentials use SecureString
- Never logged to disk
- Cleared from memory after use

---

## Usage Modes

### Full Migration (Guided)

```powershell
pwsh ./ss-migrate.ps1
# Select option 1: "Full Migration"
```

### Export Only

```powershell
pwsh ./ss-migrate.ps1
# Select option 2: "Export only"
```

Useful for:
- Creating backups
- Preparing for later migration
- Auditing secret inventory

### Import from File

```powershell
pwsh ./ss-migrate.ps1
# Select option 3: "Import from file"
```

Use a previously created export file.

### Validate Existing Migration

```powershell
pwsh ./ss-migrate.ps1
# Select option 4: "Validate existing migration"
```

Compare source and target after migration.

### Resume Interrupted Migration

```powershell
pwsh ./ss-migrate.ps1 -Resume
```

Continues from the last checkpoint.

### Show Help

```powershell
pwsh ./ss-migrate.ps1 -Help
```

---

## Configuration

Default settings (edit in script if needed):

| Setting | Default | Description |
|---------|---------|-------------|
| BatchSize | 500 | Secrets per API call |
| ThrottleDelayMs | 200 | Delay between calls (ms) |
| ConnectionTimeoutSec | 30 | API timeout |
| MaxRetries | 3 | Retry attempts on failure |
| MaxRateLimitRetries | 10 | Max retries for 429 rate limits |
| ValidationSamplePercent | 5 | % of secrets to spot-check |
| DuplicateNamePolicy | TrustTarget | How to handle duplicate names |

### For Large Migrations (40K+ secrets)

```powershell
# Edit these in ss-migrate.ps1 for faster migration:
$script:Config.BatchSize = 1000
$script:Config.ThrottleDelayMs = 50
```

---

## Prerequisites

### On Your Machine
- PowerShell 7 or later
- Network access to both Secret Server instances

### On Secret Server (Source)
- Web Services enabled
- User account with View Secret permission

### On Secret Server (Target)
- Web Services enabled
- User account with Create Secret permission
- "Allow Duplicate Secret Names" enabled (if source has duplicates)

See `INSTALL.md` for detailed setup instructions.

### Duplicate Name Handling

The wizard prompts for a duplicate name policy:

| Policy | Use Case | Speed |
|--------|----------|-------|
| **Trust Target** | Bulk imports, empty target, SS allows duplicates | Fastest |
| Fail | Strict control, stop on any duplicate | Slower |
| Skip | Incremental sync, only import new secrets | Slower |
| Rename | Add suffix to duplicates | Slower |

**For bulk migrations (like 40K+ secrets): Use "Trust Target"** - it skips duplicate analysis entirely and lets Secret Server handle naming per its configuration.

---

## Files Created

| File | Purpose | Contains Secrets? |
|------|---------|-------------------|
| `ss-migrate-*.log` | Operation log | No (names only) |
| `ss-export-*.json` | Exported secrets | **YES - secure/delete after!** |
| `ss-migrate-checkpoint.json` | Resume state | No |
| `ss-migrate-failures.json` | Failed secrets for retry | No (IDs/names only) |

---

## Security Notes

1. **Credentials are never logged** - All passwords/tokens masked
2. **Export file contains secrets** - Delete or encrypt after migration
3. **Use dedicated service account** - Don't use your personal admin account
4. **Run from secure machine** - Export file will be stored locally

---

## Troubleshooting

See `TROUBLESHOOTING.md` for common issues:
- Authentication failures
- Permission errors
- Timeout/performance issues
- Resume procedures

---

## Documentation

| File | Description |
|------|-------------|
| `README.md` | This file - quick start guide |
| `INSTALL.md` | Prerequisites and installation |
| `ARCHITECTURE.md` | Technical design and diagrams |
| `TROUBLESHOOTING.md` | Common issues and solutions |
| `REFERENCES.md` | Delinea documentation links |

---

## Example Session

```
  ╔═══════════════════════════════════════════════════════════════╗
  ║   SECRET SERVER MIGRATION TOOLKIT                             ║
  ║   Version 2.2.4                                               ║
  ╚═══════════════════════════════════════════════════════════════╝

What would you like to do?
--------------------------
  [1] Full Migration (guided wizard)
  [2] Export only (save secrets to file)
  [3] Import from file (use existing export)
  [4] Validate existing migration
  [5] Exit

Select option (1-5): 1

═══════════════════════════════════════════════════════════════
                    FULL MIGRATION WIZARD
═══════════════════════════════════════════════════════════════

STEP 1: Connection Information
------------------------------

SOURCE Secret Server (where secrets are now):
Source URL: https://company.secretservercloud.com
Source username: api-migration
Source password: ********

TARGET Secret Server (where secrets will go):
Target URL: https://company-platform.secretservercloud.com
Target username: api-migration
Target password: ********

STEP 2: Pre-flight Checks
-------------------------

Authenticating to source...
[SUCCESS] Source authentication successful
Authenticating to target...
[SUCCESS] Target authentication successful
Checking source permissions...
  Can list secrets: True
  Can read secrets: True
  Secret count: 40,000
Checking target permissions...
  Can create secrets: True
[SUCCESS] Pre-flight checks passed!

STEP 3: Export Secrets
----------------------

Ready to export 40,000 secrets from source? [Y/n]: y

  [████████████████████░░░░] 85% (34,000/40,000)

[SUCCESS] Exported 40,000 secrets to ./ss-export-2026-01-27.json
[WARNING] Export file contains secrets in clear text. Secure or delete after migration.

STEP 4: Dry Run
---------------

Performing dry run (no changes will be made)...
  [████████████████████████] 100% (40,000/40,000)

DRY RUN Complete
  Success: 40,000
  Failed:  0

Dry run summary:
  Would create: 40,000 secrets
  Would fail:   0 secrets

STEP 5: Import Secrets
----------------------

╔════════════════════════════════════════════════════════════╗
║  WARNING: This will create secrets on the target system!   ║
╚════════════════════════════════════════════════════════════╝

Proceed with import? [y/N]: y

  [████████████████████████] 100% (40,000/40,000)

IMPORT Complete
  Success: 40,000
  Failed:  0

STEP 6: Validation
------------------

Validating migration...
Source count: 40,000
Target count: 40,000
[SUCCESS] Counts match
Spot-checking 2,000 random secrets...
[SUCCESS] Spot check: 2,000/2,000 secrets verified

═══════════════════════════════════════════════════════════════
                    MIGRATION COMPLETE
═══════════════════════════════════════════════════════════════

Results:
  Exported:    40,000
  Imported:    40,000
  Failed:      0
  Validated:   2,000/2,000 spot checks passed

Files:
  Log:         ./ss-migrate-2026-01-27-153000.log
  Export:      ./ss-export-2026-01-27.json

[SUCCESS] Migration completed successfully!

REMINDER: Delete or secure the export file - it contains secrets in clear text.
```

---

## Changelog

### v2.2.4 (January 2026)
- **UX**: URL validation now offers retry instead of exiting on invalid input
- **UX**: Auto-suggests `https://` prefix when missing (prompts user to confirm)
- **UX**: Added example URL format to target prompt for consistency

### v2.2.3 (January 2026)
- **Security**: Added `ZeroFreeBSTR` to securely clear password from unmanaged memory after OAuth
- **Security**: Proper BSTR pointer cleanup in `Read-SecurePrompt` and `Get-SSToken`

### v2.2.2 (January 2026)
- **Bugfix**: Added missing `-ContentType "application/x-www-form-urlencoded"` to OAuth token request

### v2.2.1 (January 2026)
- **Bugfix**: Fixed `$Activity:` variable parsing error on line 310 (PowerShell interpreted colon as scope modifier)

### v2.2.0 (January 2026)
**Robustness & Debuggability Release**

- **Rate limit handling**: Max 10 retries for 429 errors with exponential backoff (prevents infinite loops)
- **Network error handling**: Safe status code extraction for connection failures
- **Performance**: ArrayList.Add() instead of array += for O(1) vs O(n²) append operations
- **Progress display**: ETA calculation and completion time ("Completed in Xh Xm")
- **Failure persistence**: Failed secrets saved to `ss-migrate-failures.json` for retry
- **Error messages**: Include endpoint name and status code for easier debugging
- **Export resilience**: Continues on single secret failure instead of stopping

### v2.1.0 (January 2026)
**Duplicate Name Handling Release**

- **TrustTarget policy**: Skip all duplicate checking for bulk imports (default)
- **Duplicate policies**: Fail, Skip, Rename options for stricter control
- **Wizard prompt**: Interactive duplicate policy selection
- **Duplicate analysis**: Pre-import analysis showing potential conflicts
- **Pure PowerShell tests**: `Test-SSMigrate.ps1` with no external dependencies

### v2.0.0 (January 2026)
**Initial Release**

- Interactive wizard for guided migrations
- Full field preservation (expiration dates, custom fields, folder structure)
- Mandatory dry-run before import
- Checkpoint-based resume for interrupted migrations
- SecureString credential handling
- Validation with spot-checking

---

## Roadmap

### Planned Enhancements

- [ ] **Secret Generator Tool** - Secondary script to generate test secrets for populating a source tenant (useful for testing migrations at scale)

---

## Support

This toolkit is provided by the Delinea WW Architecture Team for internal use and customer assistance.

**Note:** Per Delinea documentation, "Migration is not supported by Delinea Technical Support." This toolkit uses the documented REST API and is designed for self-service migrations.

For questions or issues, contact the WW Architecture Team.
