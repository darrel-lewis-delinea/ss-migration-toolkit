# CLAUDE.md - Instructions for Claude Code

This file helps Claude Code understand the SS Migration Toolkit project.

## Project Overview

**What this is**: A PowerShell toolkit for migrating secrets between Delinea Secret Server instances.

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

### Migration Scope

- Migrates: Folders, Policies, Secrets, Scripts, Password Types, Lists
- Maps only: Sites, Templates (must exist on target)
- Does NOT migrate: Users, Groups, Roles, Event Pipelines, Launchers

## Runtime Notes

- Requires PowerShell 7+ (`pwsh`, not Windows `powershell`).
- Resume after interruption: `pwsh ./ss-migrate.ps1 -Resume` reads `ss-migrate-checkpoint.json` and continues from the last successful point.
- Error codes are documented in TROUBLESHOOTING.md. E3006 (circular RPC reference) is handled gracefully; the migration continues.

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
