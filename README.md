# Secret Server Migration Toolkit

Interactive wizard for migrating secrets between Secret Server instances using the REST API.

**Version:** 3.1.0
**Author:** Delinea WW Architecture Team
**Date:** January 2026

---

## Important Disclaimer

> **This toolkit is NOT a replacement for Delinea Professional Services migration offerings.**
>
> This is a **lightweight, field-portable tool** designed for:
> - **Proof of concept** migrations
> - **Testing** migration workflows before engaging Professional Services
> - **Small-scale** migrations (hundreds to low thousands of secrets)
> - **SE demonstrations** of migration capabilities
>
> For production migrations, especially:
> - Large scale (10,000+ secrets)
> - Complex environments (multiple sites, custom workflows)
> - Compliance-sensitive data
> - Mission-critical systems
>
> **Contact Delinea Professional Services** for fully supported migration engagement.

---

## Migration Scope

### What This Tool Migrates

| Object Type | Mode | Notes |
|-------------|------|-------|
| **Folders** | Create | Full hierarchy preserved, correct parent/child order |
| **Secret Policies** | Create | Checkout, expiration, session recording settings |
| **Secrets** | Create | All fields, custom fields, expiration dates |
| **RPC/Privileged Account Links** | Create | Two-pass handles dependencies |
| **Scripts** | Create | PowerShell/SQL scripts for RPC (v3.1) |
| **Password Types** | Create | Custom password changers with script remapping (v3.1) |
| **Lists** | Create | Dropdown options for template fields (v3.1) |
| **Sites** | Map Only | Must exist on target; IDs mapped automatically |
| **Secret Templates** | Map Only | Must exist on target with matching fields |

### What This Tool Does NOT Migrate

These objects require manual setup on target or Professional Services engagement:

| Object Type | Why Not Included | Recommendation |
|-------------|------------------|----------------|
| **Users** | Usually AD-synced | Configure AD sync on target |
| **Groups** | Usually AD-synced | Configure AD sync on target |
| **Roles** | Org-specific permissions | Recreate manually or use PS |
| **Launchers** | Session launch config | Configure manually |
| **Character Sets** | Password char rules | Quick to configure |
| **Password Requirements** | Complexity rules | Quick to configure |
| **Reports** | Custom reports | Recreate manually |
| **Teams** | Org-specific | Recreate manually |
| **Inbox Templates** | Notification templates | Recreate manually |
| **Event Pipelines** | Workflow automation | Complex; use PS |

### Post-Migration Manual Steps

After running this tool, you may need to:

1. **Launcher Settings** - Configure any custom launchers used by migrated secrets
2. **Verify AD Sync** - Ensure users/groups are synced to target before granting access
3. **Verify RPC** - Test password rotation after migration to confirm scripts and password types work

### When to Use Professional Services

Consider Delinea Professional Services if your migration involves:

- Event Pipelines or workflow automation
- Complex role/permission structures
- Multiple distributed engine sites
- Compliance requirements (SOX, HIPAA, PCI)
- 10,000+ secrets

---

## What's New in v3.0

### Full Migration Mode
Migrates the complete object graph, not just secrets:
- **Folders** - Hierarchy preserved, created in correct order
- **Secret Policies** - Checkout, expiration, and other policy settings
- **Secrets** - With folder and policy assignments
- **RPC/Privileged Account Links** - Two-pass migration handles dependencies

### Pre-Flight Validation
Catches problems before migration starts:
- Site mapping validation
- Template matching verification
- Circular dependency detection
- Blocking vs warning classification

### Two-Pass Secret Migration
Handles circular dependencies between secrets:
1. **Pass 1**: Create all secrets without RPC links
2. **Pass 2**: Link secrets to their privileged accounts

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                    SS-MIGRATE v3.0 FLOW                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐  │
│  │  AUTH    │───▶│ VALIDATE │───▶│  EXPORT  │───▶│  IMPORT  │  │
│  └──────────┘    └──────────┘    └──────────┘    └──────────┘  │
│       │               │               │               │         │
│       ▼               ▼               ▼               ▼         │
│  Source/Target   Sites/Templates  Folders/Policies  Pass 1/2   │
│  Credentials     Mapping Check    /Secrets          Creation   │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│  DEPENDENCY ORDER (Full Migration Mode):                        │
│                                                                 │
│  Sites ──▶ Templates ──▶ Folders ──▶ Policies ──▶ Secrets      │
│    │           │            │           │            │          │
│    │           │            │           │            ▼          │
│    │           │            │           │      RPC Pass 2       │
│    │           │            │           │      (link privd      │
│    │           │            │           │       accounts)       │
│    │           │            │           ▼                       │
│    │           │            └────▶ Folder Policy                │
│    │           │                   Assignment                   │
│    │           ▼                                                │
│    │      Template ID                                           │
│    │      Mapping                                               │
│    ▼                                                            │
│  Site ID Mapping                                                │
│  (read-only, no creation)                                       │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Circular Dependency Handling

A circular dependency occurs when secrets reference each other as privileged accounts:

```
Secret A uses Secret B for RPC
Secret B uses Secret A for RPC
```

This creates an A→B→A cycle that cannot be fully migrated because:
- Secret A needs Secret B to exist first
- Secret B needs Secret A to exist first

**How ss-migrate handles this:**
1. **Detection**: `Test-CircularRpcReferences` builds a dependency graph and detects cycles
2. **Warning**: User is shown which secrets are affected
3. **Graceful degradation**: Secrets are created without the circular RPC link
4. **Manual fix**: Admin can configure RPC manually after migration

Circular references are rare but can occur in complex environments with mutual authentication requirements.

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
3. **Migration Mode** - Choose Secrets Only or Full Migration
4. **Validation** - (Full mode) Check site/template mappings
5. **Export** - Pull objects from source
6. **Dry Run** - Shows what would be imported (no changes)
7. **Import** - Create objects on target (requires confirmation)
8. **RPC Linking** - (if applicable) Link privileged accounts
9. **Validate** - Compare source and target

**If interrupted:** Resume from where you left off:
```powershell
pwsh ./ss-migrate.ps1 -Resume
```

---

## Migration Modes

### Secrets Only (Default)
Migrates secrets into existing folder structure on target.

Best for:
- Target already has folders set up
- Quick migrations
- Testing

### Full Migration (v3.0)
Migrates complete object graph: folders, policies, and secrets.

Best for:
- Fresh target environment
- Preserving folder hierarchy
- Preserving policy assignments

```
Select migration mode:
  [1] Secrets Only - Migrate secrets to existing folder structure (fastest)
  [2] Full Migration - Migrate folders, policies, AND secrets (complete)
```

---

## Features

**Interactive Wizard**
- Guided prompts for all inputs
- Color-coded output (green=success, yellow=warning, red=error)
- Progress bars with ETA

**Safety First**
- Pre-flight validation catches issues early
- Mandatory dry-run before actual import
- Explicit confirmation for destructive operations
- Checkpoint-based resume if interrupted

**Full Field Preservation**
- Secret expiration dates (unlike CSV import)
- Custom fields
- Folder structure and policies
- RPC/privileged account links
- Auto-change settings

**Security**
- Credentials use SecureString
- Never logged to disk
- Cleared from memory after use
- TLS 1.2+ enforced
- **Token expiry tracking** - Prompts for re-auth before long operations if token expired

---

## Error Codes

The toolkit uses structured error codes for easier troubleshooting:

| Code | Severity | Description |
|------|----------|-------------|
| E1001 | FATAL | Authentication failed |
| E1002 | FATAL | Network unreachable |
| E2001 | BLOCKING | Site not found on target |
| E2002 | BLOCKING | Template not found on target |
| E2006 | BLOCKING | Insufficient permissions |
| E3005 | RECOVERABLE | Privileged account not found |
| E3006 | RECOVERABLE | Circular RPC reference |
| E4002 | WARNING | Duplicate name on target |

See `TROUBLESHOOTING.md` for resolution steps.

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
- (Full mode) Create Folder and Create Policy permissions
- "Allow Duplicate Secret Names" enabled (if source has duplicates)

---

## Files Created

| File | Purpose | Contains Secrets? |
|------|---------|-------------------|
| `ss-migrate-*.log` | Operation log | No (names only) |
| `ss-export-*.json` | Exported secrets | **YES - secure/delete after!** |
| `ss-migrate-checkpoint.json` | Resume state | No |
| `ss-migrate-failures.json` | Failed items for retry | No (IDs/names only) |
| `ss-migrate-idmap.json` | ID mapping export (debug) | No |

---

## Security Notes

1. **Credentials are never logged** - All passwords/tokens masked
2. **Export file contains secrets** - Delete or encrypt after migration
3. **Use dedicated service account** - Don't use your personal admin account
4. **Run from secure machine** - Export file will be stored locally
5. **TLS 1.2+ required** - Connections to Secret Server are encrypted

---

## Troubleshooting

See `TROUBLESHOOTING.md` for common issues:
- Authentication failures (E1001)
- Permission errors (E2006)
- Missing templates/sites (E2001, E2002)
- Circular dependencies (E3006)
- Timeout/performance issues
- Resume procedures

---

## Documentation

| File | Description |
|------|-------------|
| `README.md` | This file - quick start guide |
| `INSTALL.md` | Prerequisites and installation |
| `TESTING.md` | Running tests and E2E testing guide |
| `ARCHITECTURE.md` | Technical design and diagrams |
| `TROUBLESHOOTING.md` | Common issues and solutions |
| `REFERENCES.md` | Delinea documentation links |
| `CLAUDE.md` | Instructions for Claude Code assistance |

---

## Design Principles

This toolkit is designed for **SE field portability**:

1. **Single file** - Copy one `.ps1` file, run anywhere
2. **No external dependencies** - Pure PowerShell 7, no pip/npm/binaries
3. **Interactive wizard** - Run without reading docs first
4. **Offline capable** - Export file can be carried to air-gapped networks
5. **Idempotent** - Re-running doesn't create duplicates

---

## Changelog

### v3.1.0 (January 2026)
**RPC Object Migration**

- **Scripts Migration**: Export/import PowerShell and SQL scripts for RPC
- **Password Types Migration**: Export/import custom password changers with automatic script ID remapping
- **Lists Migration**: Export/import dropdown lists with all option items
- **Pre-Flight Updates**: Scripts, Password Types, and Lists now show as "will be migrated" (not warnings)
- **Dependency Order**: Sites → Templates → Scripts → Password Types → Lists → Folders → Policies → Secrets
- **New Wizard Steps**: 5a-Scripts, 5b-PasswordTypes, 5c-Lists, 5d-Folders, 5e-Policies, 5f-PolicyAssign

### v3.0.0 (January 2026)
**Full Migration Mode Release**

- **Full Migration**: Migrate folders, policies, and secrets together
- **Pre-Flight Validation**: Catch site/template mismatches before migration
- **Two-Pass Secret Migration**: Handle RPC/privileged account dependencies
- **Circular Dependency Detection**: Identify and gracefully handle A→B→A cycles
- **ID Mapping Infrastructure**: Track source→target IDs across all object types
- **Structured Error Codes**: E1xxx (fatal), E2xxx (blocking), E3xxx (recoverable), E4xxx (warning)
- **Checkpoint v3.0**: Persist ID mappings and correlation IDs for resume
- **51 Unit Tests**: Comprehensive test coverage for new features

### v2.2.5 (January 2026)
- Bugfix: Fixed menu index off-by-one error in duplicate policy selection

### v2.2.4 (January 2026)
- UX: URL validation with retry and auto-suggest https://

### v2.2.3 (January 2026)
- Security: SecureString cleanup with ZeroFreeBSTR

### v2.2.0 (January 2026)
- Rate limit handling with exponential backoff
- Performance: ArrayList for O(1) append
- Failure persistence for retry

### v2.1.0 (January 2026)
- Duplicate name handling policies
- TrustTarget mode for bulk imports

### v2.0.0 (January 2026)
- Initial release with interactive wizard

---

## Support

This toolkit is provided by the Delinea WW Architecture Team for internal use and customer assistance.

**Important:** This is a field tool for testing and proof of concept. For production migrations, contact **Delinea Professional Services**.

Per Delinea documentation: "Migration is not supported by Delinea Technical Support." This toolkit uses the documented REST API and is designed for self-service migrations.

For questions or issues, contact the WW Architecture Team.
