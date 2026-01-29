# CLAUDE.md - Instructions for Claude Code

This file helps Claude Code understand the SS Migration Toolkit project.

## Project Overview

**What this is**: A PowerShell toolkit for migrating secrets between Delinea Secret Server instances.

**Version**: 3.1.0 (January 2026)

**Author**: Delinea WW Architecture Team (Darrel Lewis)

## File Structure

```
ss-migration-toolkit/
├── ss-migrate.ps1           # Main migration script (4000+ lines)
├── ss-generate.ps1          # Test data generator
├── Test-SSMigrate.ps1       # Unit tests (core logic)
├── Test-V3Infrastructure.ps1 # Unit tests (v3.0 ID mapping, checkpoints)
├── README.md                # User documentation
├── INSTALL.md               # Installation guide (Mac/Windows/Linux)
├── TESTING.md               # How to run tests and E2E testing
├── TROUBLESHOOTING.md       # Error codes and common issues
├── ARCHITECTURE.md          # Technical design and diagrams
├── REFERENCES.md            # Links to Delinea documentation
└── CLAUDE.md                # This file
```

## Key Concepts

### Migration Modes

1. **Secrets Only**: Migrates secrets into existing folder structure on target
2. **Full Migration**: Migrates folders, policies, AND secrets (preserves hierarchy)

### Object Dependency Order (v3.1)

```
Sites → Templates → Scripts → Password Types → Lists → Folders → Policies → Secrets
```

- Sites and Templates are **mapped only** (must exist on target)
- Everything else is **created** on target

### Two-Pass Secret Migration

1. **Pass 1**: Create all secrets without RPC links
2. **Pass 2**: Link secrets to their privileged accounts (handles circular dependencies)

### ID Mapping

Source IDs ≠ Target IDs. The script tracks mappings in `$script:IdMap`:
```powershell
$script:IdMap = @{
    Sites = @{}           # Read-only mapping
    Templates = @{}       # Read-only mapping
    Scripts = @{}         # v3.1: Created on target
    PasswordTypes = @{}   # v3.1: Created on target
    Lists = @{}           # v3.1: Created on target
    Folders = @{}         # Created on target
    Policies = @{}        # Created on target
    Secrets = @{}         # Created on target
}
```

## Common Tasks

### Running Unit Tests

```powershell
# No Secret Server needed - tests core logic
pwsh ./Test-SSMigrate.ps1
pwsh ./Test-V3Infrastructure.ps1
```

Both should pass. If they don't, check PowerShell version (`pwsh --version` must be 7+).

### Running the Migration

```powershell
pwsh ./ss-migrate.ps1
```

Interactive wizard guides through:
1. Enter source/target URLs and credentials
2. Pre-flight validation
3. Export from source
4. Dry run (preview)
5. Import to target
6. Validation

### Resuming After Interruption

```powershell
pwsh ./ss-migrate.ps1 -Resume
```

Reads `ss-migrate-checkpoint.json` and continues from last successful point.

### Generating Test Data

```powershell
pwsh ./ss-generate.ps1 -Count 100
```

Creates test secrets on a Secret Server tenant.

## Error Codes

| Prefix | Severity | Action |
|--------|----------|--------|
| E1xxx | FATAL | Cannot continue - fix and restart |
| E2xxx | BLOCKING | Must resolve before proceeding |
| E3xxx | RECOVERABLE | Logged, migration continues |
| E4xxx | WARNING/INFO | Informational, no action needed |

Key codes:
- **E1001**: Authentication failed
- **E2001**: Site not found on target
- **E2002**: Template not found on target
- **E3006**: Circular RPC reference (handled gracefully)
- **E4010-E4012**: Scripts/PasswordTypes/Lists detected (now migrated in v3.1)

## v3.1 Features (Latest)

Added migration support for RPC infrastructure:
- **Scripts**: PowerShell/SQL scripts for password changing
- **Password Types**: Define how to change passwords (reference Scripts)
- **Lists**: Dropdown options for template fields

These were previously manual-only. Now auto-migrated with ID remapping.

## Security Notes

- Credentials use SecureString, never logged
- Export file (`ss-export-*.json`) contains actual secrets - delete after testing
- TLS 1.2+ enforced
- No Invoke-Expression (code injection safe)

## When Helping Users

### If tests fail:
1. Check PowerShell version: `pwsh --version` (must be 7+)
2. On Windows, ensure using `pwsh` not `powershell`
3. Check execution policy: `Set-ExecutionPolicy RemoteSigned -Scope CurrentUser`

### If migration fails:
1. Check log file: `Get-Content ss-migrate-*.log | Select-Object -Last 50`
2. Look up error code in TROUBLESHOOTING.md
3. Common issues: wrong URL, missing permissions, template mismatch

### If asking about capabilities:
- Migrates: Folders, Policies, Secrets, Scripts, Password Types, Lists
- Maps only: Sites, Templates (must exist on target)
- Does NOT migrate: Users, Groups, Roles, Event Pipelines, Launchers

## Reading the Code

The main script (`ss-migrate.ps1`) is organized in regions:

```powershell
#region Configuration
#region Logging
#region API Functions
#region Authentication
#region Pre-Flight Validation
#region ID Mapping
#region Scripts Migration (v3.1)
#region Password Types Migration (v3.1)
#region Lists Migration (v3.1)
#region Folder Migration
#region Policy Migration
#region Secret Migration
#region Two-Pass Secret Migration
#region Wizard
```

To understand a feature, search for its region or function name.

## Quick Commands Reference

```powershell
# Check syntax without running
pwsh -Command ". ./ss-migrate.ps1"

# Run with verbose logging
pwsh ./ss-migrate.ps1 -Verbose

# View available functions after loading
pwsh -Command ". ./ss-migrate.ps1; Get-Command -CommandType Function | Where-Object { $_.Source -eq '' }"

# Check IdMap structure
pwsh -Command ". ./ss-migrate.ps1; $script:IdMap.Keys"

# Check error codes
pwsh -Command ". ./ss-migrate.ps1; $script:ErrorCodes"
```

## Contact

This toolkit was built by the Delinea WW Architecture Team.
For questions, contact Darrel Lewis or the Architecture team.
