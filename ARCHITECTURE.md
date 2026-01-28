# Secret Server Migration Toolkit - Architecture

## Overview

The SS Migration Toolkit is a single-file PowerShell script that migrates secrets between Secret Server instances using the REST API. It provides an interactive wizard interface with built-in validation, dry-run capability, and checkpoint-based resumability.

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

### Checkpoint File (`ss-migrate-checkpoint.json`)

Saved after each batch to enable resume:

```json
{
  "Timestamp": "2026-01-27T15:30:00-08:00",
  "Phase": "Importing",
  "SourceUrl": "https://source.secretservercloud.com",
  "TargetUrl": "https://target.secretservercloud.com",
  "ExportFile": "./ss-export-2026-01-27.json",
  "LastBatchIndex": 2500,
  "ImportedCount": 2500,
  "FailedCount": 3,
  "ImportedIds": [10001, 10002, ...]
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

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/oauth2/token` | POST | Authenticate and get bearer token |
| `/api/v1/version` | GET | Test connectivity |
| `/api/v1/secrets` | GET | List secrets (paginated) |
| `/api/v1/secrets/{id}` | GET | Get full secret details |
| `/api/v1/secrets/stub` | GET | Get template for new secret |
| `/api/v1/secrets` | POST | Create new secret |
| `/api/v1/secret-templates` | GET | List available templates |

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
- Max retries: 3
- Initial delay: 2 seconds
- Backoff: Exponential (2s, 4s, 8s)

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
├── ss-migrate.ps1           # Main script (all-in-one)
├── README.md                # User guide
├── INSTALL.md               # Prerequisites & setup
├── ARCHITECTURE.md          # This file
├── TROUBLESHOOTING.md       # Common issues & fixes
├── REFERENCES.md            # Delinea documentation links
│
└── (generated at runtime)
    ├── ss-migrate-*.log         # Operation log
    ├── ss-export-*.json         # Exported secrets
    └── ss-migrate-checkpoint.json # Resume state
```
