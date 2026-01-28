# Secret Server Migration Toolkit - Architecture

## Overview

The SS Migration Toolkit is a single-file PowerShell script that migrates secrets between Secret Server instances using the REST API. It provides an interactive wizard interface with built-in validation, dry-run capability, and checkpoint-based resumability.

**Version:** 3.0.0

> **Note:** This toolkit is designed for **SE field portability** - a single `.ps1` file with no external dependencies that can be copied and run anywhere with PowerShell 7. It is NOT a replacement for Delinea Professional Services migration engagements.

---

## v3.0 Architecture: Full Migration Mode

### Dependency Order

Objects must be migrated in a specific order due to dependencies:

```
┌─────────────────────────────────────────────────────────────────┐
│              FULL MIGRATION DEPENDENCY GRAPH (v3.1)             │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   ┌────────┐      ┌───────────┐                                │
│   │ SITES  │      │ TEMPLATES │  (both read-only, mapping)     │
│   └────┬───┘      └─────┬─────┘                                │
│        │                │                                       │
│        └───────┬────────┘                                       │
│                │                                                 │
│                ▼                                                 │
│   ┌─────────────────────────────────────────────────────────┐  │
│   │           RPC INFRASTRUCTURE (v3.1)                      │  │
│   │                                                          │  │
│   │  ┌─────────┐      ┌────────────────┐      ┌───────┐     │  │
│   │  │ SCRIPTS │ ───▶ │ PASSWORD TYPES │      │ LISTS │     │  │
│   │  └─────────┘      └────────────────┘      └───────┘     │  │
│   │      (Password Types reference Scripts via scriptId)     │  │
│   └─────────────────────────────────────────────────────────┘  │
│                │                                                 │
│                ▼                                                 │
│   ┌──────────┐      ┌──────────┐                               │
│   │ FOLDERS  │      │ POLICIES │  (can be parallel)            │
│   └────┬─────┘      └────┬─────┘                               │
│        │                 │                                      │
│        └────────┬────────┘                                      │
│                 │                                                │
│            ┌────▼──────────┐                                    │
│            │ FOLDER-POLICY │ (assign policies to folders)       │
│            │ ASSIGNMENT    │                                    │
│            └───────┬───────┘                                    │
│                    │                                             │
│               ┌────▼────┐                                       │
│               │ SECRETS │ Pass 1: Create without RPC            │
│               │ PASS 1  │                                       │
│               └────┬────┘                                       │
│                    │                                             │
│               ┌────▼────┐                                       │
│               │ SECRETS │ Pass 2: Link privileged accounts      │
│               │ PASS 2  │ (skip circular references)            │
│               └─────────┘                                       │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

**v3.1 Addition:** Scripts → Password Types → Lists are now migrated automatically.
Password Types reference Scripts (heartbeatScriptId, rpcScriptId), so Scripts must
be created first. Lists are independent but grouped with RPC infrastructure.

### Why Two Passes for Secrets?

Secret A may use Secret B as its privileged account for Remote Password Changing (RPC). But Secret B may also use Secret A as ITS privileged account. This creates a **circular dependency**:

```
Secret A ───uses───▶ Secret B
    ▲                    │
    │                    │
    └────uses────────────┘
```

**Solution: Two-Pass Migration**

1. **Pass 1**: Create ALL secrets without RPC configuration
2. **Pass 2**: Now that all secrets exist on target, link privileged accounts

**Circular Reference Handling**

When A→B→A cycles are detected:
- Both secrets are created (Pass 1)
- One link is established (e.g., A→B)
- The circular link (B→A) is skipped with warning (E3006)
- Admin manually configures after migration

```
Detection Algorithm (DFS):
  for each secret with privilegedAccountId:
    follow the chain: A → B → C → ...
    if we return to a visited node → CYCLE DETECTED
```

### Pre-Flight Validation

Before any data is written, v3.0 validates:

```
┌─────────────────────────────────────────────────────────────────┐
│                    PRE-FLIGHT VALIDATION                        │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌───────────────┐    ┌───────────────┐    ┌───────────────┐   │
│  │ SITE MAPPING  │    │   TEMPLATE    │    │   CIRCULAR    │   │
│  │               │    │   MATCHING    │    │   REFERENCE   │   │
│  │ Source sites  │    │               │    │   DETECTION   │   │
│  │ must exist    │    │ Template IDs  │    │               │   │
│  │ on target     │    │ must match    │    │ A→B→A cycles  │   │
│  │               │    │ or be mapped  │    │ identified    │   │
│  └───────┬───────┘    └───────┬───────┘    └───────┬───────┘   │
│          │                    │                    │            │
│          ▼                    ▼                    ▼            │
│    ┌─────────────────────────────────────────────────────┐     │
│    │              VALIDATION REPORT                       │     │
│    ├─────────────────────────────────────────────────────┤     │
│    │  BLOCKING issues  → Must fix before proceeding      │     │
│    │  WARNING issues   → Will proceed with degradation   │     │
│    └─────────────────────────────────────────────────────┘     │
│                              │                                  │
│              ┌───────────────┴───────────────┐                 │
│              │                               │                  │
│        ┌─────▼─────┐                   ┌─────▼─────┐           │
│        │ BLOCKING  │                   │ WARNINGS  │           │
│        │ User must │                   │ Proceed   │           │
│        │ fix first │                   │ with care │           │
│        └───────────┘                   └───────────┘           │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### ID Mapping Infrastructure

As objects are created on target, we track source→target ID mappings:

```powershell
$script:IdMaps = @{
    Sites     = @{ 1 = 10; 2 = 20 }     # sourceId → targetId
    Templates = @{ 6001 = 7001 }
    Folders   = @{ 100 = 500; 101 = 501 }
    Policies  = @{ 5 = 12 }
    Secrets   = @{ 1234 = 5678 }
}
```

These mappings:
- Enable Pass 2 RPC linking (find target secret ID)
- Support checkpoint/resume (persisted in checkpoint file)
- Allow rollback analysis (know what was created)

---

## Why REST API vs CSV/XML?

| Method | Preserves Expiry | Preserves All Fields | Bulk Performance | Supported |
|--------|-----------------|---------------------|------------------|-----------|
| CSV Import | No | Partial | Good | Yes |
| XML Import | Yes | Yes | Moderate | Limited |
| REST API | Yes | Yes | Excellent (July 2025+) | Yes |

**Key insight:** CSV import loses secret expiration dates. REST API preserves all fields.

## Component Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                      ss-migrate.ps1                             │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐ │
│  │   WIZARD        │  │   VALIDATION    │  │   MIGRATION     │ │
│  │   MODULE        │  │   MODULE        │  │   MODULE        │ │
│  │                 │  │                 │  │                 │ │
│  │ • Show-Banner   │  │ • Test-Url      │  │ • Export-       │ │
│  │ • Show-Menu     │  │ • Test-         │  │   Secrets       │ │
│  │ • Read-Prompt   │  │   Connection    │  │ • Import-       │ │
│  │ • Show-Progress │  │ • Test-         │  │   Secrets       │ │
│  │ • Read-         │  │   Permissions   │  │ • Test-         │ │
│  │   Confirmation  │  │                 │  │   Migration     │ │
│  └─────────────────┘  └─────────────────┘  └─────────────────┘ │
│           │                    │                    │          │
│           └────────────────────┼────────────────────┘          │
│                                │                               │
│  ┌─────────────────────────────┴─────────────────────────────┐ │
│  │                    COMMON SERVICES                        │ │
│  │                                                           │ │
│  │  • Invoke-SSApi      - REST client with retry logic       │ │
│  │  • Get-SSToken       - OAuth2 authentication              │ │
│  │  • Write-Log         - Console + file logging             │ │
│  │  • Save-Checkpoint   - State persistence                  │ │
│  │  • Restore-Checkpoint- Resume from failure                │ │
│  └───────────────────────────────────────────────────────────┘ │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
              ┌───────────────────────────────┐
              │        OUTPUT FILES           │
              │                               │
              │  • ss-migrate-*.log           │
              │  • ss-export-*.json           │
              │  • ss-migrate-checkpoint.json │
              └───────────────────────────────┘
```

## Execution Flow

```
                    ┌─────────────┐
                    │   START     │
                    └──────┬──────┘
                           │
                    ┌──────▼──────┐
                    │ Show Banner │
                    │ Check Args  │
                    └──────┬──────┘
                           │
              ┌────────────┼────────────┐
              │            │            │
        ┌─────▼─────┐ ┌────▼────┐ ┌────▼────┐
        │  --Help   │ │ --Resume│ │ Normal  │
        │  Show doc │ │ Restore │ │ Fresh   │
        │  Exit     │ │ state   │ │ start   │
        └───────────┘ └────┬────┘ └────┬────┘
                           │           │
                           └─────┬─────┘
                                 │
                          ┌──────▼──────┐
                          │  Main Menu  │
                          └──────┬──────┘
                                 │
         ┌───────────┬───────────┼───────────┬───────────┐
         │           │           │           │           │
    ┌────▼────┐ ┌────▼────┐ ┌────▼────┐ ┌────▼────┐ ┌───▼───┐
    │  Full   │ │ Export  │ │ Import  │ │Validate │ │ Exit  │
    │Migration│ │  Only   │ │  File   │ │  Only   │ │       │
    └────┬────┘ └────┬────┘ └────┬────┘ └────┬────┘ └───────┘
         │           │           │           │
         ▼           ▼           ▼           ▼
    ┌─────────────────────────────────────────────┐
    │              EXECUTION PHASES               │
    │                                             │
    │  1. Gather credentials (prompted)           │
    │  2. Authenticate to source/target           │
    │  3. Pre-flight checks (permissions)         │
    │  4. Export secrets (with progress)          │
    │  5. Dry run (simulate import)               │
    │  6. Import (with confirmation)              │
    │  7. Validate (compare counts, spot-check)   │
    │  8. Report (summary + file locations)       │
    │                                             │
    └─────────────────────────────────────────────┘
```

## State Management

### Checkpoint File (`ss-migrate-checkpoint.json`) - v3.0 Schema

Saved after each batch to enable resume:

```json
{
  "Version": "3.0",
  "Timestamp": "2026-01-27T15:30:00-08:00",
  "CorrelationId": "a1b2c3d4",
  "MigrationMode": "Full",
  "Phase": "SecretsPass2",
  "SourceUrl": "https://source.secretservercloud.com",
  "TargetUrl": "https://target.secretservercloud.com",
  "ExportFile": "./ss-export-2026-01-27.json",
  "LastBatchIndex": 2500,
  "ImportedCount": 2500,
  "FailedCount": 3,
  "ImportedIds": [10001, 10002, ...],
  "IdMaps": {
    "Sites": { "1": 10, "2": 20 },
    "Templates": { "6001": 7001 },
    "Folders": { "100": 500, "101": 501 },
    "Policies": { "5": 12 },
    "Secrets": { "1234": 5678, "1235": 5679 }
  }
}
```

### Export File (`ss-export-*.json`)

Contains secrets with metadata:

```json
{
  "Metadata": {
    "SourceUrl": "https://source.secretservercloud.com",
    "ExportTimestamp": "2026-01-27T15:00:00-08:00",
    "SecretCount": 40000,
    "Version": "2.0.0"
  },
  "Secrets": [
    {
      "id": 1234,
      "name": "Server01-Admin",
      "secretTemplateId": 6001,
      "folderId": 42,
      "items": [...],
      "expiration": "2026-06-01T00:00:00",
      ...
    }
  ]
}
```

## API Endpoints Used

### Core Endpoints

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/oauth2/token` | POST | Authenticate and get bearer token |
| `/api/v1/version` | GET | Test connectivity |
| `/api/v1/secrets` | GET | List secrets (paginated) |
| `/api/v1/secrets/{id}` | GET | Get full secret details |
| `/api/v1/secrets/stub` | GET | Get template for new secret |
| `/api/v1/secrets` | POST | Create new secret |
| `/api/v1/secrets/{id}` | PUT | Update secret (Pass 2 RPC linking) |
| `/api/v1/secret-templates` | GET | List available templates |

### v3.0 Full Migration Endpoints

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/api/v1/folders` | GET | List folders (export) |
| `/api/v1/folders/{id}` | GET | Get folder details |
| `/api/v1/folders` | POST | Create folder |
| `/api/v1/folders/{id}` | PUT | Update folder (policy assignment) |
| `/api/v1/secret-policies` | GET | List secret policies |
| `/api/v1/secret-policies/{id}` | GET | Get policy details |
| `/api/v1/secret-policies` | POST | Create policy |
| `/api/v1/sites` | GET | List sites (mapping only, no create) |

## Error Handling Strategy

```
┌──────────────────────────────────────────────────────────────┐
│                      API CALL                                │
└──────────────────────────┬───────────────────────────────────┘
                           │
                    ┌──────▼──────┐
                    │  Success?   │
                    └──────┬──────┘
                      Yes  │  No
              ┌────────────┴────────────┐
              │                         │
       ┌──────▼──────┐          ┌───────▼───────┐
       │   Return    │          │ Retry < Max?  │
       │   Result    │          └───────┬───────┘
       └─────────────┘             Yes  │  No
                           ┌────────────┴────────────┐
                           │                         │
                    ┌──────▼──────┐          ┌───────▼───────┐
                    │    Wait     │          │  Log Error    │
                    │ (exp backoff)│         │  Save State   │
                    │    Retry    │          │  Throw        │
                    └─────────────┘          └───────────────┘
```

**Retry Configuration:**
- Max retries: 3 (standard errors)
- Max retries: 10 (rate limit 429 errors)
- Initial delay: 2 seconds
- Backoff: Exponential (2s, 4s, 8s...)

### Structured Error Codes (v3.0)

All errors use a severity-based code system:

| Severity | Code Range | Behavior | Example |
|----------|------------|----------|---------|
| **FATAL** | E1xxx | Immediate stop | E1001: Authentication failed |
| **BLOCKING** | E2xxx | Stop phase, prompt user | E2001: Site not found |
| **RECOVERABLE** | E3xxx | Log, skip item, continue | E3006: Circular RPC reference |
| **WARNING** | E4xxx | Log, continue normally | E4002: Duplicate name |

See `TROUBLESHOOTING.md` for full error code reference with resolutions.

## Security Model

### Credential Handling

```
┌─────────────────────────────────────────────────────────────┐
│  User Input                                                 │
│  ┌─────────────┐                                           │
│  │  Password   │ ──► SecureString (encrypted in memory)    │
│  └─────────────┘                                           │
│         │                                                   │
│         ▼                                                   │
│  ┌─────────────┐                                           │
│  │  Get Token  │ ──► Decrypt only for API call             │
│  └─────────────┘     Clear immediately after               │
│         │                                                   │
│         ▼                                                   │
│  ┌─────────────┐                                           │
│  │   Token     │ ──► Stored in script scope only           │
│  └─────────────┘     Cleared on exit/error                 │
│         │                                                   │
│         ▼                                                   │
│  ┌─────────────┐                                           │
│  │   Logging   │ ──► All credentials masked                │
│  └─────────────┘     (Bearer [REDACTED])                   │
└─────────────────────────────────────────────────────────────┘
```

### What Gets Logged (and What Doesn't)

| Data | Logged? | Notes |
|------|---------|-------|
| URLs | Yes | Source and target endpoints |
| Usernames | Yes | For audit trail |
| Passwords | **No** | Never written to disk |
| Tokens | **No** | Masked as [REDACTED] |
| Secret names | Yes | For tracking |
| Secret values | **No** | Never in logs |
| Secret IDs | Yes | For validation |

## Performance Characteristics

### Batch Processing

```
Total Secrets: 40,000
Batch Size: 500
Batches: 80

Per Batch:
  - 1 list call (500 summaries)
  - 500 detail calls (full secrets)
  - ~100ms throttle per call

Estimated Time (export):
  - 80 batches × 501 calls × 100ms = ~67 minutes

With July 2025 optimizations:
  - Bulk operations handle large requests better
  - ~20% faster than previous versions
```

### Checkpoint Frequency

State saved:
- After each batch (every 500 secrets)
- On any error
- Before prompts that might timeout

This ensures maximum recoverability with minimal overhead.

## File Structure

```
ss-migration-toolkit/
├── ss-migrate.ps1              # Main script (all-in-one, single file)
├── Test-V3Infrastructure.ps1   # Unit tests (51 tests)
├── README.md                   # User guide
├── INSTALL.md                  # Prerequisites & setup
├── ARCHITECTURE.md             # This file
├── TROUBLESHOOTING.md          # Error codes & fixes
├── REFERENCES.md               # Delinea documentation links
│
└── (generated at runtime)
    ├── ss-migrate-*.log            # Operation log
    ├── ss-export-*.json            # Exported data (secrets, folders, policies)
    ├── ss-migrate-checkpoint.json  # Resume state (v3.0 with ID mappings)
    ├── ss-migrate-failures.json    # Failed items for retry
    └── ss-migrate-idmap.json       # ID mapping export (debug)
```

### Design Principles

1. **Single file** - Copy one `.ps1` file, run anywhere
2. **No external dependencies** - Pure PowerShell 7, no pip/npm/binaries
3. **Interactive wizard** - Run without reading docs first
4. **Offline capable** - Export file can be carried to air-gapped networks
5. **Idempotent** - Re-running doesn't create duplicates
