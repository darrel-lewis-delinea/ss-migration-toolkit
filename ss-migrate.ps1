#Requires -Version 7.0
<#
.SYNOPSIS
    Secret Server Interactive Migration Toolkit
.DESCRIPTION
    Interactive wizard for migrating secrets between Secret Server instances.
    Guides engineers through export, validation, dry-run, and import with
    full error handling and checkpoint-based resumability.
.EXAMPLE
    ./ss-migrate.ps1
    Runs the interactive wizard
.EXAMPLE
    ./ss-migrate.ps1 -Resume
    Resumes from last checkpoint
.EXAMPLE
    ./ss-migrate.ps1 -Help
    Shows detailed help
.NOTES
    Version: 3.0.0-alpha
    Author: Delinea WW Architecture Team
    Requires: PowerShell 7+, TLS 1.2/1.3

    v3.0.0 - Policy-Aware Migration
    - Pre-flight validation (sites, templates)
    - ID mapping infrastructure for multi-pass migration
    - Checkpoint schema v3.0 with ID mappings
    - Correlation IDs for log tracing
    - Foundation for folder/policy/RPC migration
#>

[CmdletBinding()]
param(
    [switch]$Resume,
    [switch]$Help,
    [ValidateSet('Quiet','Normal','Verbose','Debug')]
    [string]$LogLevel = 'Normal'
)

#region Configuration
$script:Config = @{
    Version = "3.0.0-alpha"
    BatchSize = 500
    ThrottleDelayMs = 200  # Conservative default for large migrations; increase if hitting rate limits
    ConnectionTimeoutSec = 30
    MaxRetries = 3
    MaxRateLimitRetries = 10  # Max retries specifically for 429 rate limits
    RetryDelayMs = 2000
    ValidationSamplePercent = 5
    CheckpointFile = "./ss-migrate-checkpoint.json"
    LogFile = "./ss-migrate-$(Get-Date -Format 'yyyy-MM-dd-HHmmss').log"
    ExportFile = "./ss-export-$(Get-Date -Format 'yyyy-MM-dd').json"
    FailedSecretsFile = "./ss-migrate-failures.json"  # Persisted failures for retry
    # Duplicate name handling: Fail, Skip, Rename, TrustTarget
    # TrustTarget = Skip all duplicate checking, let Secret Server handle it
    DuplicateNamePolicy = "TrustTarget"
    # Suffix for renamed duplicates (used when policy is Rename)
    DuplicateRenameSuffix = "-migrated"
}

# Track timing for ETA calculations
$script:StartTime = $null
$script:PhaseStartTime = $null

$script:State = @{
    SourceUrl = $null
    TargetUrl = $null
    SourceToken = $null
    TargetToken = $null
    ExportedSecrets = @()
    ExportedScripts = @()       # v3.1: Scripts for RPC
    ExportedPasswordTypes = @() # v3.1: Password changers for RPC
    ExportedLists = @()         # v3.1: Dropdown lists for templates
    ExportedFolders = @()       # v3.0: Folder hierarchy
    ExportedPolicies = @()      # v3.0: Secret policies
    ImportedSecrets = [System.Collections.ArrayList]::new()
    FailedSecrets = [System.Collections.ArrayList]::new()
    CurrentPhase = "Init"
    LastBatchIndex = 0
    # Token management for long-running migrations
    SourceTokenExpiry = $null
    TargetTokenExpiry = $null
}

# ID Mapping for policy-aware migration (v3.0)
# Maps source IDs to target IDs for each object type
$script:IdMap = @{
    Sites = @{}           # SourceSiteId → TargetSiteId
    Templates = @{}       # SourceTemplateId → TargetTemplateId
    Scripts = @{}         # SourceScriptId → TargetScriptId (v3.1)
    PasswordTypes = @{}   # SourcePasswordTypeId → TargetPasswordTypeId (v3.1)
    Lists = @{}           # SourceListId → TargetListId (v3.1)
    Folders = @{}         # SourceFolderId → TargetFolderId
    Policies = @{}        # SourcePolicyId → TargetPolicyId
    Secrets = @{}         # SourceSecretId → TargetSecretId
}

# Validation results for pre-flight checks
$script:ValidationReport = @{
    Sites = @{ Mapped = @(); Unmapped = @(); AffectedSecrets = @() }
    Templates = @{ Mapped = @(); Unmapped = @(); FieldMismatches = @() }
    Policies = @{ Conflicts = @(); Resolution = @() }
    Folders = @{ Conflicts = @(); Resolution = @() }
    CircularRefs = @{ Cycles = @(); AffectedSecrets = @() }
    Blocking = @()    # Issues that must be resolved
    Warnings = @()    # Issues that can be bypassed
}

# Migration mode: SecretsOnly (default), Full, FolderScope
$script:MigrationMode = "SecretsOnly"

# Correlation ID for tracing operations across logs
$script:CorrelationId = [guid]::NewGuid().ToString().Substring(0, 8)

# Force TLS 1.2+
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Error codes for structured error handling (v3.0)
# See TROUBLESHOOTING.md for resolution steps
$script:ErrorCodes = @{
    # FATAL (1xxx) - Immediate stop
    E1001 = "Authentication failed"
    E1002 = "Network unreachable"
    E1003 = "Invalid configuration"
    E1004 = "Incompatible API version"

    # BLOCKING (2xxx) - Stop phase, prompt user
    E2001 = "Site not found on target"
    E2002 = "Template not found on target"
    E2003 = "Folder path conflict"
    E2004 = "Policy name conflict"
    E2005 = "Required field missing"
    E2006 = "Insufficient permissions"

    # RECOVERABLE (3xxx) - Log, skip item, continue
    E3001 = "Template field mismatch"
    E3002 = "Folder not found for secret"
    E3003 = "Rate limit exceeded (retrying)"
    E3004 = "Single item API failure"
    E3005 = "Privileged account not found"
    E3006 = "Circular RPC reference"

    # WARNING (4xxx) - Log, continue
    E4001 = "Field value truncated"
    E4002 = "Duplicate name on target"
    E4003 = "Empty folder skipped"
    E4004 = "RPC config not migrated"
    E4010 = "Custom scripts detected"
    E4011 = "Custom password types detected"
    E4012 = "Lists detected"
    E4013 = "Custom launchers detected"
    E4014 = "Event pipelines detected"
}

function Get-ErrorMessage {
    <#
    .SYNOPSIS
        Get formatted error message with code and resolution hint
    #>
    param(
        [string]$Code,
        [string]$Details = "",
        [string]$Resolution = ""
    )

    $baseMsg = $script:ErrorCodes[$Code]
    if (-not $baseMsg) { $baseMsg = "Unknown error" }

    $msg = "[$Code] $baseMsg"
    if ($Details) { $msg += ": $Details" }
    if ($Resolution) { $msg += " → $Resolution" }

    return $msg
}
#endregion

#region Logging
$script:LogLevels = @{
    'Quiet' = 0
    'Normal' = 1
    'Verbose' = 2
    'Debug' = 3
}

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('Info','Success','Warning','Error','Debug')]
        [string]$Level = 'Info',
        [switch]$NoNewline
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"

    # Always write to log file (unless it's debug and we're not in debug mode)
    if ($Level -ne 'Debug' -or $LogLevel -eq 'Debug') {
        $logMessage | Out-File -FilePath $script:Config.LogFile -Append -Encoding UTF8
    }

    # Console output based on level
    $minLevel = switch ($Level) {
        'Error'   { 0 }
        'Warning' { 0 }
        'Success' { 1 }
        'Info'    { 1 }
        'Debug'   { 3 }
    }

    if ($script:LogLevels[$LogLevel] -ge $minLevel) {
        $color = switch ($Level) {
            'Success' { 'Green' }
            'Warning' { 'Yellow' }
            'Error'   { 'Red' }
            'Debug'   { 'Gray' }
            default   { 'White' }
        }

        $params = @{
            Object = $Message
            ForegroundColor = $color
        }
        if ($NoNewline) { $params.NoNewline = $true }

        Write-Host @params
    }
}

function Write-MaskedLog {
    param([string]$Message)
    # Mask anything that looks like a token, password, or secret
    # Case-insensitive patterns - require key + separator + value format
    $masked = $Message -replace '(?i)(Bearer\s+)[^\s]+', '$1[REDACTED]'
    $masked = $masked -replace '(?i)(password|passwd|pwd)([''"\s]*[=:][''"\s]*)([^\s,''"\}]+)', '$1$2[REDACTED]'
    $masked = $masked -replace '(?i)(access_token|api_key|apikey)([''"\s]*[=:][''"\s]*)([^\s,''"\}]+)', '$1$2[REDACTED]'
    # More specific pattern for "secret" and "token" to avoid false positives (JSON context only)
    $masked = $masked -replace '(?i)([''"])(secret|token)([''"])\s*:\s*[''"]([^''"]+)[''"]', '$1$2$3: "[REDACTED]"'
    # Mask credentials embedded in URLs
    $masked = $masked -replace '://[^:]+:[^@]+@', '://[REDACTED]:[REDACTED]@'
    Write-Log $masked -Level Debug
}
#endregion

#region UI Components
function Show-Banner {
    $banner = @"

  ╔═══════════════════════════════════════════════════════════════╗
  ║                                                               ║
  ║   SECRET SERVER MIGRATION TOOLKIT                             ║
  ║   Version $($script:Config.Version)                                            ║
  ║                                                               ║
  ║   Delinea WW Architecture Team                                ║
  ║                                                               ║
  ╚═══════════════════════════════════════════════════════════════╝

"@
    Write-Host $banner -ForegroundColor Cyan
}

function Show-Help {
    $help = @"

OVERVIEW
--------
This toolkit migrates secrets between Secret Server instances using the REST API.
Unlike CSV import, it preserves ALL fields including expiration dates.

PREREQUISITES
-------------
  • PowerShell 7 or later
  • API access enabled on both source and target Secret Server instances
  • User account with permissions to:
    - Read secrets on source
    - Create secrets on target
  • Network connectivity to both instances

WORKFLOW
--------
  1. CONNECT    - Provide URLs and authenticate to both instances
  2. PRE-FLIGHT - Validate connectivity, permissions, and compatibility
  3. EXPORT     - Pull all secrets from source (saved to file)
  4. DRY RUN    - Simulate import and show what would happen
  5. IMPORT     - Create secrets on target (requires confirmation)
  6. VALIDATE   - Compare source and target to verify success

MODES
-----
  Interactive (default)  - Guided wizard walks through all steps
  --Resume               - Continue from last checkpoint after interruption
  --Help                 - Show this help message

CONFIGURATION
-------------
  Batch Size:    $($script:Config.BatchSize) secrets per API call
  Throttle:      $($script:Config.ThrottleDelayMs)ms delay between calls
  Timeout:       $($script:Config.ConnectionTimeoutSec) seconds
  Sample Size:   $($script:Config.ValidationSamplePercent)% for validation spot-checks

FILES CREATED
-------------
  • ss-migrate-YYYY-MM-DD-HHmmss.log  - Detailed operation log
  • ss-export-YYYY-MM-DD.json         - Exported secrets (SENSITIVE!)
  • ss-migrate-checkpoint.json        - Resume state (auto-deleted on success)

SECURITY NOTES
--------------
  • Credentials are prompted interactively (never passed as parameters)
  • Passwords use SecureString and are cleared after use
  • Export file contains secrets in clear text - secure or delete after use
  • No credentials are written to log files

"@
    Write-Host $help
}

function Read-SecurePrompt {
    param(
        [string]$Prompt,
        [switch]$AsPlainText
    )

    Write-Host "$Prompt" -ForegroundColor Yellow -NoNewline
    $secure = Read-Host -AsSecureString

    if ($AsPlainText) {
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try {
            return [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        }
        finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
    return $secure
}

function Read-Prompt {
    param(
        [string]$Prompt,
        [string]$Default = "",
        [switch]$Required
    )

    $displayPrompt = $Prompt
    if ($Default) { $displayPrompt += " [$Default]" }
    $displayPrompt += ": "

    Write-Host $displayPrompt -ForegroundColor Yellow -NoNewline
    $value = Read-Host

    if ([string]::IsNullOrWhiteSpace($value)) {
        if ($Default) { return $Default }
        if ($Required) {
            Write-Log "This field is required." -Level Warning
            return Read-Prompt -Prompt $Prompt -Default $Default -Required:$Required
        }
    }

    return $value
}

function Read-Confirmation {
    param(
        [string]$Prompt,
        [bool]$Default = $false
    )

    $hint = if ($Default) { "[Y/n]" } else { "[y/N]" }
    Write-Host "$Prompt $hint " -ForegroundColor Yellow -NoNewline
    $response = Read-Host

    if ([string]::IsNullOrWhiteSpace($response)) {
        return $Default
    }

    return $response -match '^[Yy]'
}

function Show-Menu {
    param(
        [string]$Title,
        [string[]]$Options
    )

    Write-Host "`n$Title" -ForegroundColor Cyan
    Write-Host ("-" * $Title.Length) -ForegroundColor Cyan

    for ($i = 0; $i -lt $Options.Count; $i++) {
        Write-Host "  [$($i + 1)] $($Options[$i])"
    }

    Write-Host ""
    $choice = Read-Prompt -Prompt "Select option (1-$($Options.Count))" -Required

    $index = -1
    $parsed = [int]::TryParse($choice, [ref]$index)
    $index--

    if (-not $parsed -or $index -lt 0 -or $index -ge $Options.Count) {
        Write-Log "Invalid selection. Please try again." -Level Warning
        return Show-Menu -Title $Title -Options $Options
    }

    return $index
}

function Show-Progress {
    param(
        [string]$Activity,
        [int]$Current,
        [int]$Total,
        [string]$Status = ""
    )

    # Protect against divide by zero
    if ($Total -le 0) {
        Write-Host "`r  ${Activity}: $Current items processed    " -NoNewline
        return
    }

    $percent = [math]::Min(100, [math]::Round(($Current / $Total) * 100))
    $barFilled = [math]::Floor($percent / 5)
    $bar = "[" + ("█" * $barFilled) + ("░" * (20 - $barFilled)) + "]"

    # Calculate ETA if we have timing data
    $eta = ""
    if ($script:PhaseStartTime -and $Current -gt 0) {
        $elapsed = (Get-Date) - $script:PhaseStartTime
        $itemsPerSecond = $Current / $elapsed.TotalSeconds
        if ($itemsPerSecond -gt 0) {
            $remaining = ($Total - $Current) / $itemsPerSecond
            if ($remaining -lt 60) {
                $eta = "ETA: <1m"
            }
            elseif ($remaining -lt 3600) {
                $eta = "ETA: $([math]::Round($remaining / 60))m"
            }
            else {
                $hours = [math]::Floor($remaining / 3600)
                $mins = [math]::Round(($remaining % 3600) / 60)
                $eta = "ETA: ${hours}h ${mins}m"
            }
        }
    }

    $statusDisplay = if ($Status) { " $Status" } else { "" }
    Write-Host "`r  $bar $percent% ($Current/$Total)$statusDisplay $eta    " -NoNewline

    if ($Current -eq $Total) {
        # Show completion time
        if ($script:PhaseStartTime) {
            $elapsed = (Get-Date) - $script:PhaseStartTime
            $elapsedStr = if ($elapsed.TotalMinutes -lt 1) {
                "$([math]::Round($elapsed.TotalSeconds))s"
            }
            elseif ($elapsed.TotalHours -lt 1) {
                "$([math]::Round($elapsed.TotalMinutes))m"
            }
            else {
                "$([math]::Floor($elapsed.TotalHours))h $([math]::Round($elapsed.Minutes))m"
            }
            Write-Host "`r  $bar 100% ($Total/$Total) Completed in $elapsedStr    "
        }
        else {
            Write-Host ""
        }
    }
}
#endregion

#region REST API Client
function Invoke-SSApi {
    param(
        [string]$BaseUrl,
        [string]$Endpoint,
        [string]$Token,
        [string]$Method = 'Get',
        [object]$Body = $null,
        [int]$Retry = 0
    )

    $uri = "$BaseUrl/api/v1/$Endpoint"

    # Validate URI hasn't been manipulated (path traversal protection)
    $parsedUri = [System.Uri]::new($uri)
    $parsedBase = [System.Uri]::new($BaseUrl)
    if ($parsedUri.Host -ne $parsedBase.Host) {
        throw "Security error: URL manipulation detected"
    }

    $headers = @{
        'Authorization' = "Bearer $Token"
        'Content-Type' = 'application/json'
    }

    $params = @{
        Uri = $uri
        Headers = $headers
        Method = $Method
        TimeoutSec = $script:Config.ConnectionTimeoutSec
    }

    if ($Body) {
        $params.Body = $Body | ConvertTo-Json -Depth 20
    }

    Write-MaskedLog "API $Method $Endpoint"

    try {
        $response = Invoke-RestMethod @params
        Start-Sleep -Milliseconds $script:Config.ThrottleDelayMs
        return $response
    }
    catch {
        $errorMsg = $_.Exception.Message

        # Safely extract status code (may be null for network errors)
        $statusCode = $null
        if ($_.Exception.Response) {
            try {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }
            catch {
                # StatusCode might not be accessible
            }
        }

        $statusDisplay = if ($statusCode) { " ($statusCode)" } else { "" }
        Write-MaskedLog "API Error$statusDisplay on $Endpoint : $errorMsg"

        # Handle rate limiting (429) with longer backoff
        if ($statusCode -eq 429) {
            if ($Retry -ge $script:Config.MaxRateLimitRetries) {
                throw "Rate limit exceeded after $($script:Config.MaxRateLimitRetries) retries on $Endpoint"
            }

            # Check for Retry-After header
            $delay = 30000 * [math]::Pow(2, [math]::Min($Retry, 5))  # Cap exponential growth
            try {
                $retryAfter = $_.Exception.Response.Headers['Retry-After']
                if ($retryAfter) {
                    $delay = [int]$retryAfter * 1000
                    Write-Log "Rate limited on $Endpoint. Server requested wait: $retryAfter seconds (attempt $($Retry + 1)/$($script:Config.MaxRateLimitRetries))" -Level Warning
                }
                else {
                    Write-Log "Rate limited on $Endpoint. Waiting $($delay/1000) seconds... (attempt $($Retry + 1)/$($script:Config.MaxRateLimitRetries))" -Level Warning
                }
            }
            catch {
                Write-Log "Rate limited on $Endpoint. Waiting $($delay/1000) seconds... (attempt $($Retry + 1)/$($script:Config.MaxRateLimitRetries))" -Level Warning
            }
            Start-Sleep -Milliseconds $delay
            return Invoke-SSApi -BaseUrl $BaseUrl -Endpoint $Endpoint -Token $Token -Method $Method -Body $Body -Retry ($Retry + 1)
        }

        # Handle other retryable errors (network, timeout, 5xx)
        $isRetryable = ($null -eq $statusCode) -or ($statusCode -ge 500) -or ($statusCode -eq 408)
        if ($isRetryable -and $Retry -lt $script:Config.MaxRetries) {
            $delay = $script:Config.RetryDelayMs * [math]::Pow(2, $Retry)
            Write-Log "Retryable error on $Endpoint. Waiting $($delay/1000) seconds... (attempt $($Retry + 1)/$($script:Config.MaxRetries))" -Level Warning
            Start-Sleep -Milliseconds $delay
            return Invoke-SSApi -BaseUrl $BaseUrl -Endpoint $Endpoint -Token $Token -Method $Method -Body $Body -Retry ($Retry + 1)
        }

        # Non-retryable error or max retries exceeded
        $retryInfo = if ($Retry -gt 0) { " after $Retry retries" } else { "" }
        throw "API call failed$retryInfo on $Endpoint : $errorMsg"
    }
}

function Get-SSToken {
    <#
    .SYNOPSIS
    Authenticates to Secret Server and returns token with expiry info.

    .DESCRIPTION
    Returns a hashtable with 'Token' and 'Expiry' (DateTime when token expires).
    Token typically expires in 1 hour - critical for long-running migrations.
    #>
    param(
        [string]$BaseUrl,
        [string]$Username,
        [SecureString]$Password
    )

    $plainPassword = $null
    $body = $null
    $bstr = $null

    try {
        # Convert SecureString to plain text for OAuth body
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
        $plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)

        $body = @{
            username = $Username
            password = $plainPassword
            grant_type = 'password'
        }

        Write-Log "Authenticating to $BaseUrl..." -Level Info
        $response = Invoke-RestMethod -Uri "$BaseUrl/oauth2/token" -Method Post -Body $body -ContentType "application/x-www-form-urlencoded" -TimeoutSec $script:Config.ConnectionTimeoutSec

        # Calculate token expiry (default 1 hour if not specified, with 5 minute buffer)
        $expiresIn = if ($response.expires_in) { $response.expires_in - 300 } else { 3300 }  # 55 minutes default
        $expiry = (Get-Date).AddSeconds($expiresIn)

        Write-Log "Token expires at $($expiry.ToString('HH:mm:ss')) (in $([math]::Round($expiresIn / 60)) minutes)" -Level Debug

        return @{
            Token = $response.access_token
            Expiry = $expiry
        }
    }
    catch {
        # Sanitize URL in error message (remove any embedded credentials)
        $safeUrl = $BaseUrl -replace '://[^:]+:[^@]+@', '://[REDACTED]@'
        throw "Authentication failed to $safeUrl : $($_.Exception.Message)"
    }
    finally {
        # Securely clear sensitive data from memory
        if ($bstr) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
        if ($body) { $body.password = $null }
        $plainPassword = $null
    }
}

function Test-TokenExpired {
    <#
    .SYNOPSIS
    Checks if a token is expired or about to expire.
    #>
    param(
        [DateTime]$Expiry
    )

    if ($null -eq $Expiry) { return $false }  # No expiry tracking, assume valid
    return (Get-Date) -gt $Expiry
}

function Request-TokenRefresh {
    <#
    .SYNOPSIS
    Prompts user to re-authenticate if token is expired.

    .DESCRIPTION
    Called before major phases. If token expired, prompts for re-auth.
    Returns $true if tokens are valid (or refreshed), $false if user declines.
    #>
    param(
        [string]$Phase = "continue"
    )

    $sourceExpired = Test-TokenExpired -Expiry $script:State.SourceTokenExpiry
    $targetExpired = Test-TokenExpired -Expiry $script:State.TargetTokenExpiry

    if (-not $sourceExpired -and -not $targetExpired) {
        return $true  # Tokens still valid
    }

    Write-Host ""
    Write-Host "╔═══════════════════════════════════════════════════════════════╗" -ForegroundColor Yellow
    Write-Host "║  TOKEN REFRESH REQUIRED                                       ║" -ForegroundColor Yellow
    Write-Host "╚═══════════════════════════════════════════════════════════════╝" -ForegroundColor Yellow
    Write-Host ""

    if ($sourceExpired) {
        Write-Host "  Source token has expired." -ForegroundColor Yellow
    }
    if ($targetExpired) {
        Write-Host "  Target token has expired." -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "  Re-authentication is required to $Phase." -ForegroundColor White
    Write-Host ""

    if (-not (Read-Confirmation "Re-authenticate now?")) {
        Write-Log "User declined re-authentication" -Level Warning
        return $false
    }

    # Re-authenticate to source if expired
    if ($sourceExpired) {
        Write-Host "`nSource Secret Server credentials:" -ForegroundColor Cyan
        $sourceUser = Read-Prompt -Prompt "Username"
        $sourcePass = Read-SecurePrompt -Prompt "Password"

        try {
            $authResult = Get-SSToken -BaseUrl $script:State.SourceUrl -Username $sourceUser -Password $sourcePass
            $script:State.SourceToken = $authResult.Token
            $script:State.SourceTokenExpiry = $authResult.Expiry
            Write-Log "Source re-authentication successful" -Level Success
        }
        catch {
            Write-Log "Source re-authentication failed: $_" -Level Error
            return $false
        }
        finally {
            $sourcePass = $null
            [GC]::Collect()
        }
    }

    # Re-authenticate to target if expired
    if ($targetExpired) {
        Write-Host "`nTarget Secret Server credentials:" -ForegroundColor Cyan
        $targetUser = Read-Prompt -Prompt "Username"
        $targetPass = Read-SecurePrompt -Prompt "Password"

        try {
            $authResult = Get-SSToken -BaseUrl $script:State.TargetUrl -Username $targetUser -Password $targetPass
            $script:State.TargetToken = $authResult.Token
            $script:State.TargetTokenExpiry = $authResult.Expiry
            Write-Log "Target re-authentication successful" -Level Success
        }
        catch {
            Write-Log "Target re-authentication failed: $_" -Level Error
            return $false
        }
        finally {
            $targetPass = $null
            [GC]::Collect()
        }
    }

    return $true
}
#endregion

#region Checkpoint Management
function Save-Checkpoint {
    # Convert integer keys to strings for JSON compatibility
    $idMapsForJson = @{}
    foreach ($type in @('Sites', 'Templates', 'Folders', 'Policies', 'Secrets')) {
        $idMapsForJson[$type] = @{}
        foreach ($key in $script:IdMap[$type].Keys) {
            $idMapsForJson[$type]["$key"] = $script:IdMap[$type][$key]
        }
    }

    $checkpoint = @{
        Timestamp = Get-Date -Format "o"
        Version = "3.0"  # Checkpoint schema version for compatibility
        CorrelationId = $script:CorrelationId
        Phase = $script:State.CurrentPhase
        MigrationMode = $script:MigrationMode
        SourceUrl = $script:State.SourceUrl
        TargetUrl = $script:State.TargetUrl
        ExportFile = $script:Config.ExportFile
        LastBatchIndex = $script:State.LastBatchIndex
        ImportedCount = $script:State.ImportedSecrets.Count
        FailedCount = $script:State.FailedSecrets.Count
        ImportedIds = $script:State.ImportedSecrets | Select-Object -ExpandProperty TargetId -ErrorAction SilentlyContinue
        # v3.0: Include ID mappings for policy-aware migration
        IdMaps = $idMapsForJson
    }

    $checkpoint | ConvertTo-Json -Depth 10 | Out-File $script:Config.CheckpointFile -Encoding UTF8
    Write-Log "[$script:CorrelationId] Checkpoint saved (Phase: $($script:State.CurrentPhase))" -Level Debug
}

function Restore-Checkpoint {
    if (-not (Test-Path $script:Config.CheckpointFile)) {
        return $false
    }

    try {
        # Validate checkpoint file size (security check)
        $fileSize = (Get-Item $script:Config.CheckpointFile).Length
        if ($fileSize -gt 100MB) {
            Write-Log "Checkpoint file suspiciously large ($($fileSize / 1MB) MB). Ignoring." -Level Warning
            return $false
        }

        $checkpoint = Get-Content $script:Config.CheckpointFile -Raw | ConvertFrom-Json

        # Validate checkpoint structure (prevent injection)
        $validPhases = @('Init', 'Connect', 'Preflight', 'Validation', 'Export', 'DryRun', 'Import', 'SecretsPass1', 'SecretsPass2', 'FoldersPass1', 'FoldersPass2', 'Policies', 'Validate', 'Complete')
        if ($checkpoint.Phase -and $checkpoint.Phase -notin $validPhases) {
            Write-Log "Invalid checkpoint phase: $($checkpoint.Phase). Ignoring." -Level Warning
            return $false
        }

        Write-Log "Found checkpoint from $($checkpoint.Timestamp)" -Level Info
        Write-Log "  Phase: $($checkpoint.Phase)" -Level Info
        Write-Log "  Source: $($checkpoint.SourceUrl)" -Level Info
        Write-Log "  Target: $($checkpoint.TargetUrl)" -Level Info
        Write-Log "  Progress: $($checkpoint.ImportedCount) imported, $($checkpoint.FailedCount) failed" -Level Info

        # v3.0: Show ID mapping summary if present
        if ($checkpoint.IdMaps) {
            $mapCounts = @()
            foreach ($type in @('Sites', 'Templates', 'Folders', 'Policies', 'Secrets')) {
                $count = 0
                if ($checkpoint.IdMaps.$type) {
                    # Handle both hashtable and PSCustomObject from JSON
                    $count = ($checkpoint.IdMaps.$type.PSObject.Properties | Measure-Object).Count
                }
                if ($count -gt 0) { $mapCounts += "$type`:$count" }
            }
            if ($mapCounts.Count -gt 0) {
                Write-Log "  ID Mappings: $($mapCounts -join ', ')" -Level Info
            }
        }

        if ($checkpoint.MigrationMode) {
            Write-Log "  Mode: $($checkpoint.MigrationMode)" -Level Info
        }

        if (Read-Confirmation "Resume from this checkpoint?") {
            $script:State.SourceUrl = $checkpoint.SourceUrl
            $script:State.TargetUrl = $checkpoint.TargetUrl
            $script:State.CurrentPhase = $checkpoint.Phase
            $script:State.LastBatchIndex = $checkpoint.LastBatchIndex
            $script:Config.ExportFile = $checkpoint.ExportFile

            # v3.0: Restore correlation ID if present
            if ($checkpoint.CorrelationId) {
                $script:CorrelationId = $checkpoint.CorrelationId
            }

            # v3.0: Restore migration mode if present
            if ($checkpoint.MigrationMode) {
                $script:MigrationMode = $checkpoint.MigrationMode
            }

            # v3.0: Restore ID mappings if present
            if ($checkpoint.IdMaps) {
                # Convert PSCustomObject properties back to hashtables
                foreach ($type in @('Sites', 'Templates', 'Folders', 'Policies', 'Secrets')) {
                    if ($checkpoint.IdMaps.$type) {
                        $script:IdMap[$type] = @{}
                        foreach ($prop in $checkpoint.IdMaps.$type.PSObject.Properties) {
                            $script:IdMap[$type][[int]$prop.Name] = [int]$prop.Value
                        }
                    }
                }
                Write-Log "Restored ID mappings from checkpoint" -Level Debug
            }

            return $true
        }
    }
    catch {
        Write-Log "Could not read checkpoint: $_" -Level Warning
    }

    return $false
}

function Clear-Checkpoint {
    if (Test-Path $script:Config.CheckpointFile) {
        Remove-Item $script:Config.CheckpointFile -Force
        Write-Log "Checkpoint cleared" -Level Debug
    }
}
#endregion

#region ID Mapping (v3.0 - Policy-Aware Migration)

function Set-IdMapping {
    <#
    .SYNOPSIS
        Store a source-to-target ID mapping
    .PARAMETER ObjectType
        Type of object: Sites, Templates, Folders, Policies, Secrets
    .PARAMETER SourceId
        ID from the source Secret Server
    .PARAMETER TargetId
        ID from the target Secret Server
    .PARAMETER Name
        Optional name for debugging
    #>
    param(
        [ValidateSet('Sites', 'Templates', 'Folders', 'Policies', 'Secrets')]
        [string]$ObjectType,
        [int]$SourceId,
        [int]$TargetId,
        [string]$Name = ""
    )

    $script:IdMap[$ObjectType][$SourceId] = $TargetId
    Write-Log "[$script:CorrelationId] Mapped $ObjectType : $SourceId -> $TargetId $(if ($Name) { "($Name)" })" -Level Debug
}

function Get-MappedId {
    <#
    .SYNOPSIS
        Get the target ID for a source ID
    .PARAMETER ObjectType
        Type of object: Sites, Templates, Folders, Policies, Secrets
    .PARAMETER SourceId
        ID from the source Secret Server
    .RETURNS
        Target ID if mapped, $null if not found
    #>
    param(
        [ValidateSet('Sites', 'Templates', 'Folders', 'Policies', 'Secrets')]
        [string]$ObjectType,
        [int]$SourceId
    )

    if ($script:IdMap[$ObjectType].ContainsKey($SourceId)) {
        return $script:IdMap[$ObjectType][$SourceId]
    }

    Write-Log "[$script:CorrelationId] WARNING: No mapping found for $ObjectType ID $SourceId" -Level Debug
    return $null
}

function Test-IdMapping {
    <#
    .SYNOPSIS
        Check if a source ID has been mapped
    #>
    param(
        [ValidateSet('Sites', 'Templates', 'Folders', 'Policies', 'Secrets')]
        [string]$ObjectType,
        [int]$SourceId
    )

    return $script:IdMap[$ObjectType].ContainsKey($SourceId)
}

function Get-IdMapSummary {
    <#
    .SYNOPSIS
        Get a summary of all ID mappings for display
    #>
    $summary = @()
    foreach ($type in @('Sites', 'Templates', 'Folders', 'Policies', 'Secrets')) {
        $count = $script:IdMap[$type].Count
        if ($count -gt 0) {
            $summary += "$type : $count"
        }
    }
    return $summary -join ", "
}

function Export-IdMap {
    <#
    .SYNOPSIS
        Export ID mappings to a JSON file for debugging/audit
    #>
    param([string]$Path = "./ss-migrate-idmap.json")

    # Convert integer keys to strings for JSON compatibility
    $mappingsForJson = @{}
    foreach ($type in @('Sites', 'Templates', 'Folders', 'Policies', 'Secrets')) {
        $mappingsForJson[$type] = @{}
        foreach ($key in $script:IdMap[$type].Keys) {
            $mappingsForJson[$type]["$key"] = $script:IdMap[$type][$key]
        }
    }

    $export = @{
        Timestamp = Get-Date -Format "o"
        CorrelationId = $script:CorrelationId
        SourceUrl = $script:State.SourceUrl
        TargetUrl = $script:State.TargetUrl
        Mappings = $mappingsForJson
    }

    $export | ConvertTo-Json -Depth 10 | Out-File $Path -Encoding UTF8
    Write-Log "ID mappings exported to $Path" -Level Info
}

function Clear-IdMaps {
    <#
    .SYNOPSIS
        Clear all ID mappings (for fresh migration)
    #>
    $script:IdMap = @{
        Sites = @{}
        Templates = @{}
        Folders = @{}
        Policies = @{}
        Secrets = @{}
    }
    Write-Log "ID mappings cleared" -Level Debug
}

#endregion

#region Validation Functions
function Test-Url {
    param([string]$Url)

    if (-not $Url.StartsWith("https://")) {
        return @{ Valid = $false; Error = "URL must start with https://"; Suggestion = "https://$Url" }
    }

    try {
        $uri = [System.Uri]::new($Url)
        if (-not $uri.Host) {
            return @{ Valid = $false; Error = "Invalid hostname" }
        }
        return @{ Valid = $true; Url = $Url }
    }
    catch {
        return @{ Valid = $false; Error = "Invalid URL format: $($_.Exception.Message)" }
    }
}

function Read-UrlWithRetry {
    param(
        [string]$Prompt,
        [string]$Label
    )

    while ($true) {
        $url = Read-Prompt -Prompt $Prompt -Required
        $urlCheck = Test-Url $url

        if ($urlCheck.Valid) {
            return $url
        }

        Write-Host "  [ERROR] $($urlCheck.Error)" -ForegroundColor Red

        # Offer suggestion if we have one
        if ($urlCheck.Suggestion) {
            $useSuggestion = Read-Prompt -Prompt "  Did you mean '$($urlCheck.Suggestion)'? [Y/n]"
            if ($useSuggestion -ne 'n' -and $useSuggestion -ne 'N') {
                $suggestionCheck = Test-Url $urlCheck.Suggestion
                if ($suggestionCheck.Valid) {
                    Write-Host "  Using: $($urlCheck.Suggestion)" -ForegroundColor Green
                    return $urlCheck.Suggestion
                }
            }
        }

        $retry = Read-Prompt -Prompt "  Try again? [Y/n]"
        if ($retry -eq 'n' -or $retry -eq 'N') {
            return $null
        }
        Write-Host ""
    }
}

function Test-Connection {
    param(
        [string]$BaseUrl,
        [string]$Token
    )

    try {
        $result = Invoke-SSApi -BaseUrl $BaseUrl -Endpoint "version" -Token $Token
        return @{
            Connected = $true
            Version = $result.version
        }
    }
    catch {
        return @{
            Connected = $false
            Error = $_.Exception.Message
        }
    }
}

function Test-Permissions {
    param(
        [string]$BaseUrl,
        [string]$Token,
        [ValidateSet('Source','Target')]
        [string]$Role
    )

    $results = @{
        CanListSecrets = $false
        CanReadSecrets = $false
        CanCreateSecrets = $false
        SecretCount = 0
    }

    try {
        # Test list
        $list = Invoke-SSApi -BaseUrl $BaseUrl -Endpoint "secrets?take=1" -Token $Token
        $results.CanListSecrets = $true
        $results.SecretCount = $list.total

        # Test read (if there are secrets)
        if ($list.records.Count -gt 0) {
            $secret = Invoke-SSApi -BaseUrl $BaseUrl -Endpoint "secrets/$($list.records[0].id)" -Token $Token
            $results.CanReadSecrets = $true
        }
        else {
            $results.CanReadSecrets = $true  # Assume true if no secrets to test
        }

        # Test create permission by getting a stub (doesn't actually create)
        if ($Role -eq 'Target') {
            $templates = Invoke-SSApi -BaseUrl $BaseUrl -Endpoint "secret-templates?take=1" -Token $Token
            if ($templates.records.Count -gt 0) {
                $stub = Invoke-SSApi -BaseUrl $BaseUrl -Endpoint "secrets/stub?filter.secrettemplateid=$($templates.records[0].id)" -Token $Token
                $results.CanCreateSecrets = $true
            }
        }
    }
    catch {
        Write-Log "Permission check error: $_" -Level Debug
    }

    return $results
}
#endregion

#region Pre-Flight Validation (v3.0 - Policy-Aware Migration)

function Get-SitesFromServer {
    <#
    .SYNOPSIS
        Fetch all sites from a Secret Server instance
    #>
    param(
        [string]$BaseUrl,
        [string]$Token
    )

    try {
        $response = Invoke-SSApi -BaseUrl $BaseUrl -Endpoint "sites" -Token $Token
        if ($response.records) {
            return $response.records
        }
        return @()
    }
    catch {
        Write-Log "[$script:CorrelationId] Could not fetch sites: $_" -Level Warning
        return @()
    }
}

function Test-SiteMapping {
    <#
    .SYNOPSIS
        Validate that all sites used by source secrets exist on target
    .DESCRIPTION
        Maps source sites to target sites by name. Returns report of:
        - Mapped sites (name match found)
        - Unmapped sites (no match on target)
        - Affected secrets (secrets using unmapped sites)
    #>
    param(
        [string]$SourceUrl,
        [string]$SourceToken,
        [string]$TargetUrl,
        [string]$TargetToken,
        [array]$SourceSecrets = @()
    )

    Write-Log "[$script:CorrelationId] Validating site mappings..." -Level Info

    $result = @{
        Mapped = @()
        Unmapped = @()
        AffectedSecrets = @()
        SourceSites = @()
        TargetSites = @()
    }

    # Get sites from both servers
    $sourceSites = Get-SitesFromServer -BaseUrl $SourceUrl -Token $SourceToken
    $targetSites = Get-SitesFromServer -BaseUrl $TargetUrl -Token $TargetToken
    $result.SourceSites = $sourceSites
    $result.TargetSites = $targetSites

    # Build target site lookup by name (case-insensitive)
    $targetSiteByName = @{}
    foreach ($site in $targetSites) {
        $targetSiteByName[$site.siteName.ToLower()] = $site
    }

    # Map source sites to target
    foreach ($site in $sourceSites) {
        $targetMatch = $targetSiteByName[$site.siteName.ToLower()]
        if ($targetMatch) {
            Set-IdMapping -ObjectType 'Sites' -SourceId $site.siteId -TargetId $targetMatch.siteId -Name $site.siteName
            $result.Mapped += @{
                SourceId = $site.siteId
                TargetId = $targetMatch.siteId
                Name = $site.siteName
            }
        }
        else {
            $result.Unmapped += @{
                SourceId = $site.siteId
                Name = $site.siteName
            }
        }
    }

    # Find secrets using unmapped sites
    if ($result.Unmapped.Count -gt 0 -and $SourceSecrets.Count -gt 0) {
        $unmappedIds = $result.Unmapped | ForEach-Object { $_.SourceId }
        foreach ($secret in $SourceSecrets) {
            if ($secret.siteId -and $secret.siteId -in $unmappedIds) {
                $result.AffectedSecrets += @{
                    SecretId = $secret.id
                    SecretName = $secret.name
                    SiteId = $secret.siteId
                }
            }
        }
    }

    # Update validation report
    $script:ValidationReport.Sites = $result

    if ($result.Unmapped.Count -gt 0) {
        $msg = "Site mapping: $($result.Mapped.Count) mapped, $($result.Unmapped.Count) UNMAPPED"
        if ($result.AffectedSecrets.Count -gt 0) {
            $msg += " ($($result.AffectedSecrets.Count) secrets affected)"
        }
        Write-Log "[$script:CorrelationId] $msg" -Level Warning
    }
    else {
        Write-Log "[$script:CorrelationId] Site mapping: $($result.Mapped.Count) sites mapped successfully" -Level Success
    }

    return $result
}

function Get-SecretTemplatesFromServer {
    <#
    .SYNOPSIS
        Fetch all secret templates from a Secret Server instance
    #>
    param(
        [string]$BaseUrl,
        [string]$Token
    )

    try {
        $response = Invoke-SSApi -BaseUrl $BaseUrl -Endpoint "secret-templates?take=1000" -Token $Token
        if ($response.records) {
            return $response.records
        }
        return @()
    }
    catch {
        Write-Log "[$script:CorrelationId] Could not fetch templates: $_" -Level Warning
        return @()
    }
}

function Get-TemplateFields {
    <#
    .SYNOPSIS
        Get field definitions for a specific template
    #>
    param(
        [string]$BaseUrl,
        [string]$Token,
        [int]$TemplateId
    )

    try {
        $template = Invoke-SSApi -BaseUrl $BaseUrl -Endpoint "secret-templates/$TemplateId" -Token $Token
        if ($template.fields) {
            return $template.fields
        }
        return @()
    }
    catch {
        Write-Log "[$script:CorrelationId] Could not fetch template fields for ID $TemplateId : $_" -Level Debug
        return @()
    }
}

function Test-TemplateMapping {
    <#
    .SYNOPSIS
        Validate that all templates used by source secrets exist on target
    .DESCRIPTION
        Maps source templates to target templates by name. Also compares field structures
        to identify potential data loss during migration.
    #>
    param(
        [string]$SourceUrl,
        [string]$SourceToken,
        [string]$TargetUrl,
        [string]$TargetToken,
        [array]$SourceSecrets = @()
    )

    Write-Log "[$script:CorrelationId] Validating template mappings..." -Level Info

    $result = @{
        Mapped = @()
        Unmapped = @()
        FieldMismatches = @()
        AffectedSecrets = @()
        SourceTemplates = @()
        TargetTemplates = @()
    }

    # Get templates from both servers
    $sourceTemplates = Get-SecretTemplatesFromServer -BaseUrl $SourceUrl -Token $SourceToken
    $targetTemplates = Get-SecretTemplatesFromServer -BaseUrl $TargetUrl -Token $TargetToken
    $result.SourceTemplates = $sourceTemplates
    $result.TargetTemplates = $targetTemplates

    # Build target template lookup by name
    $targetTemplateByName = @{}
    foreach ($template in $targetTemplates) {
        $targetTemplateByName[$template.name.ToLower()] = $template
    }

    # Determine which templates are actually used by secrets
    $usedTemplateIds = @{}
    foreach ($secret in $SourceSecrets) {
        if ($secret.secretTemplateId) {
            $usedTemplateIds[$secret.secretTemplateId] = $true
        }
    }

    # Map source templates to target
    foreach ($template in $sourceTemplates) {
        # Skip templates not used by any secrets we're migrating
        $isUsed = $usedTemplateIds.ContainsKey($template.id)

        $targetMatch = $targetTemplateByName[$template.name.ToLower()]
        if ($targetMatch) {
            Set-IdMapping -ObjectType 'Templates' -SourceId $template.id -TargetId $targetMatch.id -Name $template.name
            $result.Mapped += @{
                SourceId = $template.id
                TargetId = $targetMatch.id
                Name = $template.name
                IsUsed = $isUsed
            }
        }
        elseif ($isUsed) {
            # Only flag as unmapped if actually used
            $result.Unmapped += @{
                SourceId = $template.id
                Name = $template.name
            }
        }
    }

    # Find secrets using unmapped templates
    if ($result.Unmapped.Count -gt 0) {
        $unmappedIds = $result.Unmapped | ForEach-Object { $_.SourceId }
        foreach ($secret in $SourceSecrets) {
            if ($secret.secretTemplateId -in $unmappedIds) {
                $result.AffectedSecrets += @{
                    SecretId = $secret.id
                    SecretName = $secret.name
                    TemplateId = $secret.secretTemplateId
                }
            }
        }
    }

    # Update validation report
    $script:ValidationReport.Templates = $result

    if ($result.Unmapped.Count -gt 0) {
        $msg = "Template mapping: $($result.Mapped.Count) mapped, $($result.Unmapped.Count) UNMAPPED"
        if ($result.AffectedSecrets.Count -gt 0) {
            $msg += " ($($result.AffectedSecrets.Count) secrets affected)"
        }
        Write-Log "[$script:CorrelationId] $msg" -Level Warning
        $script:ValidationReport.Blocking += "[E2002] Missing templates: $($result.Unmapped.Name -join ', ')"
    }
    else {
        Write-Log "[$script:CorrelationId] Template mapping: $($result.Mapped.Count) templates mapped successfully" -Level Success
    }

    return $result
}

function Test-UnsupportedObjects {
    <#
    .SYNOPSIS
        Check for objects on source that this tool does not migrate
    .DESCRIPTION
        Detects Scripts, Password Types, Lists, Launchers, and Event Pipelines
        and adds warnings to the validation report. These are warnings, not blockers.
    #>
    param(
        [string]$SourceUrl,
        [string]$SourceToken
    )

    Write-Log "[$script:CorrelationId] Checking for unsupported objects on source..." -Level Info

    $headers = @{ Authorization = "Bearer $SourceToken" }
    $warnings = @()
    $manualWorkItems = @()

    # Check Scripts - v3.1: Now supported for migration
    try {
        $response = Invoke-RestMethod -Uri "$SourceUrl/api/v1/userscripts" -Headers $headers -Method Get -ErrorAction Stop
        $scriptCount = if ($response.records) { $response.records.Count } elseif ($response.Count) { $response.Count } else { 0 }
        if ($scriptCount -gt 0) {
            Write-Log "[$script:CorrelationId] Found $scriptCount scripts - will be migrated" -Level Info
        }
    }
    catch {
        Write-Log "[$script:CorrelationId] Could not check scripts: $($_.Exception.Message)" -Level Warning
    }

    # Check Password Types - v3.1: Now supported for migration
    try {
        $response = Invoke-RestMethod -Uri "$SourceUrl/api/v1/remote-password-changing/password-types" -Headers $headers -Method Get -ErrorAction Stop
        $pwTypes = if ($response.records) { $response.records } elseif ($response) { $response } else { @() }
        # Filter to non-default types (default types have lower IDs, typically < 100)
        $customPwTypes = @($pwTypes | Where-Object { $_.id -gt 100 -or $_.isCustom -eq $true })
        if ($customPwTypes.Count -gt 0) {
            Write-Log "[$script:CorrelationId] Found $($customPwTypes.Count) custom password types - will be migrated" -Level Info
        }
    }
    catch {
        Write-Log "[$script:CorrelationId] Could not check password types: $($_.Exception.Message)" -Level Warning
    }

    # Check Lists - v3.1: Now supported for migration
    try {
        $response = Invoke-RestMethod -Uri "$SourceUrl/api/v1/lists" -Headers $headers -Method Get -ErrorAction Stop
        $listCount = if ($response.records) { $response.records.Count } elseif ($response.Count) { $response.Count } else { 0 }
        if ($listCount -gt 0) {
            Write-Log "[$script:CorrelationId] Found $listCount lists - will be migrated" -Level Info
        }
    }
    catch {
        Write-Log "[$script:CorrelationId] Could not check lists: $($_.Exception.Message)" -Level Warning
    }

    # Check Launchers (custom ones)
    try {
        $response = Invoke-RestMethod -Uri "$SourceUrl/api/v1/launchers" -Headers $headers -Method Get -ErrorAction Stop
        $launchers = if ($response.records) { $response.records } elseif ($response) { $response } else { @() }
        $customLaunchers = @($launchers | Where-Object { $_.isCustom -eq $true -or $_.id -gt 20 })
        if ($customLaunchers.Count -gt 0) {
            $warnings += "[E4013] $($customLaunchers.Count) custom launchers detected - manual setup needed"
            $manualWorkItems += "Launchers ($($customLaunchers.Count)): Configure on target after migration"
            Write-Log "[$script:CorrelationId] [E4013] Found $($customLaunchers.Count) custom launchers" -Level Warning
        }
    }
    catch {
        Write-Log "[$script:CorrelationId] Could not check launchers: $($_.Exception.Message)" -Level Warning
    }

    # Check Event Pipelines
    try {
        $response = Invoke-RestMethod -Uri "$SourceUrl/api/v1/event-pipeline-policy/pipelines" -Headers $headers -Method Get -ErrorAction Stop
        $pipelineCount = if ($response.records) { $response.records.Count } elseif ($response.Count) { $response.Count } else { 0 }
        if ($pipelineCount -gt 0) {
            $warnings += "[E4014] $pipelineCount event pipelines detected - consider Professional Services"
            $manualWorkItems += "Event Pipelines ($pipelineCount): Complex automation - recommend PS engagement"
            Write-Log "[$script:CorrelationId] [E4014] Found $pipelineCount event pipelines" -Level Warning
        }
    }
    catch {
        Write-Log "[$script:CorrelationId] Could not check event pipelines: $($_.Exception.Message)" -Level Warning
    }

    # Add warnings to validation report
    foreach ($warning in $warnings) {
        $script:ValidationReport.Warnings += $warning
    }

    return @{
        Warnings = $warnings
        ManualWorkItems = $manualWorkItems
    }
}

function Show-ValidationReport {
    <#
    .SYNOPSIS
        Display the pre-flight validation report
    #>

    Write-Host ""
    Write-Host "┌─────────────────────────────────────────────────────────────┐" -ForegroundColor Cyan
    Write-Host "│  PRE-FLIGHT VALIDATION REPORT                               │" -ForegroundColor Cyan
    Write-Host "├─────────────────────────────────────────────────────────────┤" -ForegroundColor Cyan

    # Sites
    $sitesMapped = $script:ValidationReport.Sites.Mapped.Count
    $sitesUnmapped = $script:ValidationReport.Sites.Unmapped.Count
    $sitesAffected = $script:ValidationReport.Sites.AffectedSecrets.Count
    if ($sitesUnmapped -gt 0) {
        Write-Host "│  Sites:     $sitesMapped mapped, " -NoNewline -ForegroundColor White
        Write-Host "$sitesUnmapped UNMAPPED" -NoNewline -ForegroundColor Red
        Write-Host " ($sitesAffected secrets affected)" -ForegroundColor White
    }
    else {
        Write-Host "│  Sites:     $sitesMapped mapped " -NoNewline -ForegroundColor White
        Write-Host "✓" -ForegroundColor Green
    }

    # Templates
    $templatesMapped = $script:ValidationReport.Templates.Mapped.Count
    $templatesUnmapped = $script:ValidationReport.Templates.Unmapped.Count
    $templatesAffected = $script:ValidationReport.Templates.AffectedSecrets.Count
    if ($templatesUnmapped -gt 0) {
        Write-Host "│  Templates: $templatesMapped mapped, " -NoNewline -ForegroundColor White
        Write-Host "$templatesUnmapped UNMAPPED" -NoNewline -ForegroundColor Red
        Write-Host " ($templatesAffected secrets affected)" -ForegroundColor White

        # List unmapped templates
        foreach ($t in $script:ValidationReport.Templates.Unmapped) {
            Write-Host "│             • $($t.Name)" -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "│  Templates: $templatesMapped mapped " -NoNewline -ForegroundColor White
        Write-Host "✓" -ForegroundColor Green
    }

    # Summary
    Write-Host "├─────────────────────────────────────────────────────────────┤" -ForegroundColor Cyan

    $blockingCount = $script:ValidationReport.Blocking.Count
    $warningCount = $script:ValidationReport.Warnings.Count

    if ($blockingCount -gt 0) {
        Write-Host "│  BLOCKING ISSUES: " -NoNewline -ForegroundColor White
        Write-Host "$blockingCount" -ForegroundColor Red
        foreach ($issue in $script:ValidationReport.Blocking) {
            Write-Host "│  • $issue" -ForegroundColor Red
        }
    }

    if ($warningCount -gt 0) {
        Write-Host "│  WARNINGS: " -NoNewline -ForegroundColor White
        Write-Host "$warningCount" -ForegroundColor Yellow
        foreach ($warning in $script:ValidationReport.Warnings) {
            Write-Host "│  • $warning" -ForegroundColor Yellow
        }
    }

    if ($blockingCount -eq 0 -and $warningCount -eq 0) {
        Write-Host "│  " -NoNewline
        Write-Host "All pre-flight checks passed!" -ForegroundColor Green
    }

    Write-Host "└─────────────────────────────────────────────────────────────┘" -ForegroundColor Cyan
    Write-Host ""

    return $blockingCount -eq 0
}

function Invoke-PreFlightValidation {
    <#
    .SYNOPSIS
        Run all pre-flight validation checks
    .RETURNS
        $true if migration can proceed, $false if blocking issues
    #>
    param(
        [string]$SourceUrl,
        [string]$SourceToken,
        [string]$TargetUrl,
        [string]$TargetToken,
        [array]$SourceSecrets = @()
    )

    Write-Log "[$script:CorrelationId] Starting pre-flight validation..." -Level Info
    $script:State.CurrentPhase = "Validation"
    Save-Checkpoint

    # Clear previous validation results
    $script:ValidationReport.Blocking = @()
    $script:ValidationReport.Warnings = @()

    # Run validations
    $siteResult = Test-SiteMapping -SourceUrl $SourceUrl -SourceToken $SourceToken `
        -TargetUrl $TargetUrl -TargetToken $TargetToken -SourceSecrets $SourceSecrets

    $templateResult = Test-TemplateMapping -SourceUrl $SourceUrl -SourceToken $SourceToken `
        -TargetUrl $TargetUrl -TargetToken $TargetToken -SourceSecrets $SourceSecrets

    # Check for blocking site issues
    if ($siteResult.Unmapped.Count -gt 0 -and $siteResult.AffectedSecrets.Count -gt 0) {
        $script:ValidationReport.Blocking += "[E2001] $($siteResult.AffectedSecrets.Count) secrets use unmapped sites"
    }

    # Check for unsupported objects (warnings, not blocking)
    $unsupportedResult = Test-UnsupportedObjects -SourceUrl $SourceUrl -SourceToken $SourceToken

    # Show report
    $canProceed = Show-ValidationReport

    # Show manual work summary if there are unsupported objects
    if ($unsupportedResult.ManualWorkItems.Count -gt 0) {
        Write-Host ""
        Write-Host "┌─────────────────────────────────────────────────────────────┐" -ForegroundColor Yellow
        Write-Host "│  MANUAL WORK REQUIRED AFTER MIGRATION                       │" -ForegroundColor Yellow
        Write-Host "├─────────────────────────────────────────────────────────────┤" -ForegroundColor Yellow
        foreach ($item in $unsupportedResult.ManualWorkItems) {
            Write-Host "│  • $item" -ForegroundColor White
        }
        Write-Host "│                                                             │" -ForegroundColor Yellow
        Write-Host "│  See TROUBLESHOOTING.md for detailed steps.                 │" -ForegroundColor White
        Write-Host "└─────────────────────────────────────────────────────────────┘" -ForegroundColor Yellow
        Write-Host ""
    }

    if (-not $canProceed) {
        Write-Host "Migration cannot proceed until blocking issues are resolved." -ForegroundColor Red
        Write-Host "Options:" -ForegroundColor Yellow
        Write-Host "  1. Create missing sites/templates on target manually" -ForegroundColor White
        Write-Host "  2. Remove affected secrets from migration scope" -ForegroundColor White
        Write-Host "  3. Use -Force to proceed anyway (data loss may occur)" -ForegroundColor White
    }

    Save-Checkpoint
    return $canProceed
}

#endregion

#region Migration Functions

function Get-ExistingSecretNames {
    <#
    .SYNOPSIS
        Retrieves all secret names from target system for duplicate detection.
    .DESCRIPTION
        Fetches secret names in batches and returns a hashtable for O(1) lookup.
        Used by Import-Secrets to detect and handle duplicate names.
    #>
    param(
        [string]$BaseUrl,
        [string]$Token,
        [int]$FolderId = $null
    )

    Write-Log "Fetching existing secret names from target..." -Level Info

    $existingNames = @{}
    $skip = 0
    $hasMore = $true

    while ($hasMore) {
        $endpoint = "secrets?take=$($script:Config.BatchSize)&skip=$skip"
        if ($FolderId) {
            $endpoint += "&filter.folderId=$FolderId"
        }

        $batch = Invoke-SSApi -BaseUrl $BaseUrl -Endpoint $endpoint -Token $Token

        if ($batch.records.Count -eq 0) {
            $hasMore = $false
            continue
        }

        foreach ($secret in $batch.records) {
            # Store name (lowercase for case-insensitive comparison) with folder path
            $key = "$($secret.folderId)|$($secret.name.ToLower())"
            $existingNames[$key] = @{
                Id = $secret.id
                Name = $secret.name
                FolderId = $secret.folderId
            }
        }

        $skip += $script:Config.BatchSize
        Write-Log "  Fetched $skip names..." -Level Debug
    }

    Write-Log "Found $($existingNames.Count) existing secrets on target" -Level Info
    return $existingNames
}

function Test-DuplicateName {
    <#
    .SYNOPSIS
        Checks if a secret name already exists in the target folder.
    .RETURNS
        Hashtable with IsDuplicate flag and existing secret info if found.
    #>
    param(
        [string]$Name,
        [int]$FolderId,
        [hashtable]$ExistingNames
    )

    $key = "$FolderId|$($Name.ToLower())"

    if ($ExistingNames.ContainsKey($key)) {
        return @{
            IsDuplicate = $true
            ExistingSecret = $ExistingNames[$key]
        }
    }

    return @{ IsDuplicate = $false }
}

function Get-UniqueSecretName {
    <#
    .SYNOPSIS
        Generates a unique name for a secret by appending suffix and/or number.
    .DESCRIPTION
        Used when DuplicateNamePolicy is 'Rename'.
        Tries "Name-migrated", then "Name-migrated-2", etc.
    #>
    param(
        [string]$BaseName,
        [int]$FolderId,
        [hashtable]$ExistingNames,
        [string]$Suffix = $script:Config.DuplicateRenameSuffix
    )

    $newName = "$BaseName$Suffix"
    $counter = 1

    while ($true) {
        $key = "$FolderId|$($newName.ToLower())"
        if (-not $ExistingNames.ContainsKey($key)) {
            return $newName
        }

        $counter++
        $newName = "$BaseName$Suffix-$counter"

        # Safety limit to prevent infinite loops
        if ($counter -gt 1000) {
            throw "Unable to generate unique name for '$BaseName' after 1000 attempts"
        }
    }
}

function Show-DuplicateAnalysis {
    <#
    .SYNOPSIS
        Analyzes and displays potential duplicate name conflicts before import.
    #>
    param(
        [array]$Secrets,
        [hashtable]$ExistingNames
    )

    $duplicates = @()

    foreach ($secret in $Secrets) {
        $check = Test-DuplicateName -Name $secret.name -FolderId $secret.folderId -ExistingNames $ExistingNames
        if ($check.IsDuplicate) {
            $duplicates += [PSCustomObject]@{
                Name = $secret.name
                SourceId = $secret.id
                ExistingTargetId = $check.ExistingSecret.Id
                FolderId = $secret.folderId
            }
        }
    }

    if ($duplicates.Count -gt 0) {
        Write-Host ""
        Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Yellow
        Write-Host "║  DUPLICATE NAME CONFLICTS DETECTED                         ║" -ForegroundColor Yellow
        Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Yellow
        Write-Host ""
        Write-Log "Found $($duplicates.Count) secrets with names that already exist on target" -Level Warning

        # Show first 10
        $showCount = [Math]::Min(10, $duplicates.Count)
        Write-Host "Examples (showing $showCount of $($duplicates.Count)):" -ForegroundColor Yellow
        foreach ($dup in $duplicates | Select-Object -First $showCount) {
            Write-Host "  - '$($dup.Name)' (source ID: $($dup.SourceId), existing target ID: $($dup.ExistingTargetId))" -ForegroundColor Gray
        }

        Write-Host ""
        Write-Host "Current duplicate policy: $($script:Config.DuplicateNamePolicy)" -ForegroundColor Cyan
        Write-Host "  Fail   - Stop import on any duplicate (safest)" -ForegroundColor Gray
        Write-Host "  Skip   - Skip duplicates, import only new secrets" -ForegroundColor Gray
        Write-Host "  Rename - Append '$($script:Config.DuplicateRenameSuffix)' suffix to duplicates" -ForegroundColor Gray
    }

    return $duplicates
}

function Export-Secrets {
    param(
        [string]$BaseUrl,
        [string]$Token,
        [switch]$Resume
    )

    Write-Log "Starting export from $BaseUrl" -Level Info
    $script:PhaseStartTime = Get-Date

    # Use ArrayList for O(1) append instead of O(n) array +=
    $allSecrets = [System.Collections.ArrayList]::new()
    $skip = 0
    $hasMore = $true

    # Resume from checkpoint if requested and we have a partial export
    if ($Resume -and $script:State.LastBatchIndex -gt 0 -and $script:State.CurrentPhase -eq "Exporting") {
        $skip = $script:State.LastBatchIndex
        Write-Log "Resuming export from position $skip" -Level Warning

        # Load previously exported secrets from file if exists
        if (Test-Path $script:Config.ExportFile) {
            $partialExport = Get-Content $script:Config.ExportFile | ConvertFrom-Json
            if ($partialExport.Secrets) {
                $allSecrets = [System.Collections.ArrayList]@($partialExport.Secrets)
                Write-Log "Loaded $($allSecrets.Count) previously exported secrets" -Level Info
            }
        }
    }

    $script:State.CurrentPhase = "Exporting"

    # Get total count first
    $countResult = Invoke-SSApi -BaseUrl $BaseUrl -Endpoint "secrets?take=1" -Token $Token
    $total = $countResult.total

    Write-Log "Found $total secrets to export" -Level Info

    while ($hasMore) {
        $batch = Invoke-SSApi -BaseUrl $BaseUrl -Endpoint "secrets?take=$($script:Config.BatchSize)&skip=$skip" -Token $Token

        if ($batch.records.Count -eq 0) {
            $hasMore = $false
            continue
        }

        foreach ($summary in $batch.records) {
            try {
                $secret = Invoke-SSApi -BaseUrl $BaseUrl -Endpoint "secrets/$($summary.id)" -Token $Token

                # Capture RPC/privileged account configuration (v3.0)
                $rpcConfig = @{
                    autoChangeEnabled = $secret.autoChangeEnabled
                    autoChangeNextPassword = $secret.autoChangeNextPassword
                    enableInheritSecretPolicy = $secret.enableInheritSecretPolicy
                    passwordTypeWebScriptId = $secret.passwordTypeWebScriptId
                    # Privileged account reference - key for two-pass migration
                    launcherConnectAsSecretId = $secret.launcherConnectAsSecretId
                    # Additional RPC fields that may exist
                    isDoubleLock = $secret.isDoubleLock
                    doubleLockId = $secret.doubleLockId
                }

                [void]$allSecrets.Add([PSCustomObject]@{
                    id = $secret.id
                    name = $secret.name
                    secretTemplateId = $secret.secretTemplateId
                    secretTemplateName = $secret.secretTemplateName
                    folderId = $secret.folderId
                    folderPath = $secret.folderPath
                    siteId = $secret.siteId
                    active = $secret.active
                    items = $secret.items
                    expiration = $secret.expiration
                    autoChangeEnabled = $secret.autoChangeEnabled
                    requiresComment = $secret.requiresComment
                    checkOutEnabled = $secret.checkOutEnabled
                    # v3.0: RPC configuration for two-pass migration
                    rpcConfig = $rpcConfig
                    launcherConnectAsSecretId = $secret.launcherConnectAsSecretId
                })
            }
            catch {
                Write-Log "Failed to export secret ID $($summary.id) '$($summary.name)': $($_.Exception.Message)" -Level Error
                # Continue with next secret rather than failing entire export
            }

            Show-Progress -Activity "Exporting" -Current $allSecrets.Count -Total $total
        }

        $skip += $script:Config.BatchSize
        $script:State.LastBatchIndex = $skip
        Save-Checkpoint

        # Save partial export periodically (every 5 batches = 2500 secrets)
        if (($skip / $script:Config.BatchSize) % 5 -eq 0) {
            $partialExport = @{
                ExportDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                SourceUrl = $BaseUrl
                SecretCount = $allSecrets.Count
                TotalExpected = $total
                Partial = $true
                Secrets = $allSecrets
            }
            $partialExport | ConvertTo-Json -Depth 20 | Set-Content $script:Config.ExportFile
            Write-Log "Saved partial export ($($allSecrets.Count) secrets)" -Level Debug
        }

        if ($batch.records.Count -lt $script:Config.BatchSize) {
            $hasMore = $false
        }
    }

    # Save export with metadata
    $export = @{
        Metadata = @{
            SourceUrl = $BaseUrl
            ExportTimestamp = Get-Date -Format "o"
            SecretCount = $allSecrets.Count
            Version = $script:Config.Version
        }
        Secrets = $allSecrets
    }

    $export | ConvertTo-Json -Depth 20 | Out-File $script:Config.ExportFile -Encoding UTF8

    # Set restrictive file permissions (owner-only access)
    try {
        if ($IsWindows -or $env:OS -match 'Windows') {
            # Windows: Remove inheritance and set owner-only access
            $acl = Get-Acl $script:Config.ExportFile
            $acl.SetAccessRuleProtection($true, $false)
            $owner = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($owner, "FullControl", "Allow")
            $acl.SetAccessRule($rule)
            Set-Acl $script:Config.ExportFile $acl
            Write-Log "Export file permissions restricted to current user" -Level Debug
        }
        else {
            # Unix/macOS: Set 600 permissions (owner read/write only)
            chmod 600 $script:Config.ExportFile
            Write-Log "Export file permissions set to 600 (owner only)" -Level Debug
        }
    }
    catch {
        Write-Log "Warning: Could not restrict export file permissions: $_" -Level Warning
    }

    Write-Host ""
    Write-Log "Exported $($allSecrets.Count) secrets to $($script:Config.ExportFile)" -Level Success
    Write-Log "WARNING: Export file contains secrets in clear text. Secure or delete after migration." -Level Warning

    $script:State.ExportedSecrets = $allSecrets
    $script:State.CurrentPhase = "Exported"
    Save-Checkpoint

    return $allSecrets
}

function Import-Secrets {
    param(
        [string]$BaseUrl,
        [string]$Token,
        [array]$Secrets,
        [switch]$DryRun,
        [hashtable]$ExistingNames = $null
    )

    $mode = if ($DryRun) { "DRY RUN" } else { "IMPORT" }
    Write-Log "Starting $mode to $BaseUrl ($($Secrets.Count) secrets)" -Level Info
    Write-Log "Duplicate name policy: $($script:Config.DuplicateNamePolicy)" -Level Info
    $script:PhaseStartTime = Get-Date

    # For TrustTarget, skip all duplicate checking - fastest path
    $skipDuplicateCheck = ($script:Config.DuplicateNamePolicy -eq "TrustTarget")

    if (-not $skipDuplicateCheck) {
        # Fetch existing names if not provided (for duplicate detection)
        if ($null -eq $ExistingNames) {
            $ExistingNames = Get-ExistingSecretNames -BaseUrl $BaseUrl -Token $Token
        }
    }
    else {
        $ExistingNames = @{}
    }

    # Track names we're adding (for detecting duplicates within the import batch)
    $importBatchNames = @{}

    # Use ArrayList for O(1) append performance with large datasets
    $results = @{
        Success = [System.Collections.ArrayList]::new()
        Failed = [System.Collections.ArrayList]::new()
        Skipped = [System.Collections.ArrayList]::new()
        Renamed = [System.Collections.ArrayList]::new()
    }

    $count = 0
    foreach ($secret in $Secrets) {
        $count++
        $originalName = $secret.name
        $targetName = $secret.name

        try {
            # Skip duplicate checking for TrustTarget policy
            if (-not $skipDuplicateCheck) {
                # Check for duplicate name
                $dupCheck = Test-DuplicateName -Name $secret.name -FolderId $secret.folderId -ExistingNames $ExistingNames

                # Also check against names we're adding in this batch
                $batchKey = "$($secret.folderId)|$($secret.name.ToLower())"
                if ($importBatchNames.ContainsKey($batchKey)) {
                    $dupCheck = @{
                        IsDuplicate = $true
                        ExistingSecret = @{ Name = $secret.name; Id = "pending-in-batch" }
                    }
                }

                if ($dupCheck.IsDuplicate) {
                    switch ($script:Config.DuplicateNamePolicy) {
                        "Fail" {
                            throw "Duplicate name detected: '$($secret.name)' already exists on target (ID: $($dupCheck.ExistingSecret.Id)). Set DuplicateNamePolicy to 'Skip' or 'Rename' to handle duplicates."
                        }
                        "Skip" {
                            [void]$results.Skipped.Add([PSCustomObject]@{
                                SourceId = $secret.id
                                Name = $secret.name
                                Reason = "Duplicate name exists on target (ID: $($dupCheck.ExistingSecret.Id))"
                            })
                            Write-Log "Skipped (duplicate): $($secret.name)" -Level Debug
                            Show-Progress -Activity $mode -Current $count -Total $Secrets.Count
                            continue
                        }
                        "Rename" {
                            $targetName = Get-UniqueSecretName -BaseName $secret.name -FolderId $secret.folderId -ExistingNames $ExistingNames
                            # Also check against batch names
                            while ($importBatchNames.ContainsKey("$($secret.folderId)|$($targetName.ToLower())")) {
                                $targetName = Get-UniqueSecretName -BaseName $targetName -FolderId $secret.folderId -ExistingNames $ExistingNames
                            }
                            Write-Log "Renaming duplicate: '$originalName' -> '$targetName'" -Level Debug
                        }
                    }
                }
            }

            # Get stub for template
            $stub = Invoke-SSApi -BaseUrl $BaseUrl -Endpoint "secrets/stub?filter.secrettemplateid=$($secret.secretTemplateId)" -Token $Token

            # Populate stub (using potentially renamed name)
            $stub.name = $targetName
            $stub.folderId = $secret.folderId
            $stub.siteId = $secret.siteId
            $stub.autoChangeEnabled = $secret.autoChangeEnabled
            $stub.requiresComment = $secret.requiresComment
            $stub.checkOutEnabled = $secret.checkOutEnabled

            # Map field values
            foreach ($sourceItem in $secret.items) {
                $targetItem = $stub.items | Where-Object { $_.slug -eq $sourceItem.slug -or $_.fieldName -eq $sourceItem.fieldName }
                if ($targetItem) {
                    $targetItem.itemValue = $sourceItem.itemValue
                }
            }

            # Set expiration
            if ($secret.expiration) {
                $stub.expiration = $secret.expiration
            }

            if ($DryRun) {
                $action = if ($targetName -ne $originalName) { "Would create (renamed from '$originalName')" } else { "Would create" }
                [void]$results.Success.Add([PSCustomObject]@{
                    SourceId = $secret.id
                    Name = $targetName
                    OriginalName = $originalName
                    Action = $action
                })
                if ($targetName -ne $originalName) {
                    [void]$results.Renamed.Add([PSCustomObject]@{
                        SourceId = $secret.id
                        OriginalName = $originalName
                        NewName = $targetName
                    })
                }
            }
            else {
                $newSecret = Invoke-SSApi -BaseUrl $BaseUrl -Endpoint "secrets" -Token $Token -Method Post -Body $stub

                [void]$results.Success.Add([PSCustomObject]@{
                    SourceId = $secret.id
                    TargetId = $newSecret.id
                    Name = $targetName
                    OriginalName = $originalName
                })

                if ($targetName -ne $originalName) {
                    [void]$results.Renamed.Add([PSCustomObject]@{
                        SourceId = $secret.id
                        TargetId = $newSecret.id
                        OriginalName = $originalName
                        NewName = $targetName
                    })
                }

                [void]$script:State.ImportedSecrets.Add($results.Success[-1])
            }

            # Track this name in our batch (for detecting duplicates within import)
            $importBatchNames["$($secret.folderId)|$($targetName.ToLower())"] = $true

            Show-Progress -Activity $mode -Current $count -Total $Secrets.Count
        }
        catch {
            [void]$results.Failed.Add([PSCustomObject]@{
                SourceId = $secret.id
                Name = $secret.name
                Error = $_.Exception.Message
            })

            [void]$script:State.FailedSecrets.Add($results.Failed[-1])
            Write-Log "Failed to import secret ID $($secret.id) '$($secret.name)': $($_.Exception.Message)" -Level Error

            # If policy is Fail and this is a duplicate error, stop the import
            if ($script:Config.DuplicateNamePolicy -eq "Fail" -and $_.Exception.Message -like "*Duplicate name*") {
                Write-Log "Import stopped due to duplicate name (policy: Fail)" -Level Error
                break
            }
        }

        # Save checkpoint periodically
        if ($count % 100 -eq 0) {
            Save-Checkpoint
        }
    }

    Write-Host ""

    # Summary
    Write-Log "$mode Complete" -Level Success
    Write-Log "  Success: $($results.Success.Count)" -Level Info
    Write-Log "  Skipped: $($results.Skipped.Count)" -Level $(if ($results.Skipped.Count -gt 0) { 'Warning' } else { 'Info' })
    Write-Log "  Renamed: $($results.Renamed.Count)" -Level $(if ($results.Renamed.Count -gt 0) { 'Warning' } else { 'Info' })
    Write-Log "  Failed:  $($results.Failed.Count)" -Level $(if ($results.Failed.Count -gt 0) { 'Warning' } else { 'Info' })

    if ($results.Skipped.Count -gt 0) {
        Write-Log "Skipped secrets (duplicates):" -Level Warning
        foreach ($skipped in $results.Skipped | Select-Object -First 10) {
            Write-Log "  SKIPPED: $($skipped.Name) - $($skipped.Reason)" -Level Warning
        }
        if ($results.Skipped.Count -gt 10) {
            Write-Log "  ... and $($results.Skipped.Count - 10) more (see log file)" -Level Warning
        }
    }

    if ($results.Renamed.Count -gt 0) {
        Write-Log "Renamed secrets:" -Level Warning
        foreach ($renamed in $results.Renamed | Select-Object -First 10) {
            Write-Log "  RENAMED: '$($renamed.OriginalName)' -> '$($renamed.NewName)'" -Level Warning
        }
        if ($results.Renamed.Count -gt 10) {
            Write-Log "  ... and $($results.Renamed.Count - 10) more (see log file)" -Level Warning
        }
    }

    if ($results.Failed.Count -gt 0 -and -not $DryRun) {
        Write-Log "Failed secrets:" -Level Warning
        foreach ($failed in $results.Failed) {
            Write-Log "FAILED: $($failed.Name) (ID: $($failed.SourceId)) - $($failed.Error)" -Level Error
        }

        # Save failures to file for retry capability
        $failuresFile = $script:Config.FailedSecretsFile
        $failureData = @{
            Timestamp = Get-Date -Format "o"
            SourceUrl = $script:State.SourceUrl
            TargetUrl = $script:State.TargetUrl
            TotalFailed = $results.Failed.Count
            Failures = $results.Failed
        }
        $failureData | ConvertTo-Json -Depth 10 | Set-Content $failuresFile -Encoding UTF8
        Write-Log "Failed secrets saved to $failuresFile (can be used for retry)" -Level Warning
    }

    $script:State.CurrentPhase = if ($DryRun) { "DryRunComplete" } else { "ImportComplete" }
    Save-Checkpoint

    return $results
}

function Test-Migration {
    param(
        [string]$SourceUrl,
        [string]$SourceToken,
        [string]$TargetUrl,
        [string]$TargetToken
    )

    Write-Log "Validating migration..." -Level Info

    # Get counts
    $sourceCount = (Invoke-SSApi -BaseUrl $SourceUrl -Endpoint "secrets?take=1" -Token $SourceToken).total
    $targetCount = (Invoke-SSApi -BaseUrl $TargetUrl -Endpoint "secrets?take=1" -Token $TargetToken).total

    Write-Log "Source count: $sourceCount" -Level Info
    Write-Log "Target count: $targetCount" -Level Info

    $countMatch = $sourceCount -eq $targetCount
    if (-not $countMatch) {
        Write-Log "Count mismatch detected" -Level Warning
    }
    else {
        Write-Log "Counts match" -Level Success
    }

    # Spot check
    $sampleSize = [math]::Max(10, [math]::Ceiling($sourceCount * $script:Config.ValidationSamplePercent / 100))
    Write-Log "Spot-checking $sampleSize random secrets..." -Level Info

    $sourceSecrets = (Invoke-SSApi -BaseUrl $SourceUrl -Endpoint "secrets?take=$sampleSize" -Token $SourceToken).records

    $found = 0
    $missing = @()

    foreach ($source in $sourceSecrets) {
        $searchUrl = "secrets?filter.searchText=$([uri]::EscapeDataString($source.name))&take=5"
        $matches = (Invoke-SSApi -BaseUrl $TargetUrl -Endpoint $searchUrl -Token $TargetToken).records

        if ($matches | Where-Object { $_.name -eq $source.name }) {
            $found++
        }
        else {
            $missing += $source.name
        }
    }

    Write-Log "Spot check: $found/$sampleSize secrets verified" -Level $(if ($found -eq $sampleSize) { 'Success' } else { 'Warning' })

    if ($missing.Count -gt 0) {
        Write-Log "Missing secrets:" -Level Warning
        $missing | ForEach-Object { Write-Log "  - $_" -Level Warning }
    }

    return @{
        SourceCount = $sourceCount
        TargetCount = $targetCount
        CountMatch = $countMatch
        SampleSize = $sampleSize
        SampleFound = $found
        Missing = $missing
    }
}

#region Scripts Migration (v3.1)

function Export-Scripts {
    <#
    .SYNOPSIS
        Export all user scripts from source
    .DESCRIPTION
        Fetches scripts used for password changing, heartbeat, and other RPC operations.
        These are essential for RPC to work after migration.
    #>
    param(
        [string]$BaseUrl,
        [string]$Token
    )

    Write-Log "[$script:CorrelationId] Exporting scripts from source..." -Level Info

    $allScripts = [System.Collections.ArrayList]::new()

    try {
        $response = Invoke-SSApi -BaseUrl $BaseUrl -Endpoint "userscripts" -Token $Token
        $scripts = if ($response.records) { $response.records } elseif ($response) { @($response) } else { @() }

        foreach ($script in $scripts) {
            # Get full script details including the actual script content
            try {
                $details = Invoke-SSApi -BaseUrl $BaseUrl -Endpoint "userscripts/$($script.userScriptId)" -Token $Token
                [void]$allScripts.Add([PSCustomObject]@{
                    userScriptId = $details.userScriptId
                    name = $details.name
                    description = $details.description
                    script = $details.script
                    scriptType = $details.scriptType          # PowerShell, SQL, SSH
                    active = $details.active
                    version = $details.version
                    concurrencyId = $details.concurrencyId
                })
            }
            catch {
                Write-Log "[$script:CorrelationId] Failed to get details for script $($script.userScriptId): $_" -Level Warning
                # Add basic info without script content
                [void]$allScripts.Add([PSCustomObject]@{
                    userScriptId = $script.userScriptId
                    name = $script.name
                    description = $script.description
                    script = $null
                    scriptType = $script.scriptType
                    active = $script.active
                    version = $null
                    concurrencyId = $null
                })
            }
        }
    }
    catch {
        Write-Log "[$script:CorrelationId] Error fetching scripts: $_" -Level Error
        return @()
    }

    Write-Log "[$script:CorrelationId] Exported $($allScripts.Count) scripts" -Level Success
    return $allScripts
}

function Import-Scripts {
    <#
    .SYNOPSIS
        Import scripts to target
    .DESCRIPTION
        Creates scripts on target and records ID mapping for Password Type references.
    #>
    param(
        [string]$BaseUrl,
        [string]$Token,
        [array]$Scripts
    )

    if ($Scripts.Count -eq 0) {
        Write-Log "[$script:CorrelationId] No scripts to import" -Level Info
        return @{ Success = @(); Failed = @(); Skipped = @() }
    }

    Write-Log "[$script:CorrelationId] Importing $($Scripts.Count) scripts..." -Level Info

    $results = @{
        Success = [System.Collections.ArrayList]::new()
        Failed = [System.Collections.ArrayList]::new()
        Skipped = [System.Collections.ArrayList]::new()
    }

    # Get existing scripts on target for duplicate detection
    $existingScripts = @{}
    try {
        $response = Invoke-SSApi -BaseUrl $BaseUrl -Endpoint "userscripts" -Token $Token
        $targetScripts = if ($response.records) { $response.records } else { @() }
        foreach ($s in $targetScripts) {
            $existingScripts[$s.name.ToLower()] = $s
        }
    }
    catch {
        Write-Log "[$script:CorrelationId] Could not fetch existing scripts from target: $_" -Level Warning
    }

    $count = 0
    foreach ($script in $Scripts) {
        $count++
        Show-Progress -Activity "Importing scripts" -Current $count -Total $Scripts.Count

        # Check for duplicate by name
        $existingMatch = $existingScripts[$script.name.ToLower()]
        if ($existingMatch) {
            Write-Log "[$script:CorrelationId] Script '$($script.name)' already exists on target (ID: $($existingMatch.userScriptId)), mapping" -Level Info
            Set-IdMapping -ObjectType 'Scripts' -SourceId $script.userScriptId -TargetId $existingMatch.userScriptId -Name $script.name
            [void]$results.Skipped.Add([PSCustomObject]@{
                SourceId = $script.userScriptId
                TargetId = $existingMatch.userScriptId
                Name = $script.name
                Reason = "Already exists"
            })
            continue
        }

        # Skip if we don't have the script content
        if (-not $script.script) {
            Write-Log "[$script:CorrelationId] Script '$($script.name)' has no content, skipping" -Level Warning
            [void]$results.Failed.Add([PSCustomObject]@{
                SourceId = $script.userScriptId
                Name = $script.name
                Error = "No script content available"
            })
            continue
        }

        try {
            $body = @{
                name = $script.name
                description = $script.description
                script = $script.script
                scriptType = $script.scriptType
                active = $script.active
            }

            $result = Invoke-SSApi -BaseUrl $BaseUrl -Endpoint "userscripts" -Token $Token -Method Post -Body $body

            Set-IdMapping -ObjectType 'Scripts' -SourceId $script.userScriptId -TargetId $result.userScriptId -Name $script.name

            [void]$results.Success.Add([PSCustomObject]@{
                SourceId = $script.userScriptId
                TargetId = $result.userScriptId
                Name = $script.name
            })

            Write-Log "[$script:CorrelationId] Created script '$($script.name)' (Source: $($script.userScriptId) → Target: $($result.userScriptId))" -Level Info
        }
        catch {
            Write-Log "[$script:CorrelationId] Failed to create script '$($script.name)': $_" -Level Error
            [void]$results.Failed.Add([PSCustomObject]@{
                SourceId = $script.userScriptId
                Name = $script.name
                Error = $_.Exception.Message
            })
        }
    }

    Write-Log "[$script:CorrelationId] Scripts import complete: $($results.Success.Count) created, $($results.Skipped.Count) existing, $($results.Failed.Count) failed" -Level Success
    return $results
}

#endregion

#region Password Types Migration (v3.1)

function Export-PasswordTypes {
    <#
    .SYNOPSIS
        Export custom password types from source
    .DESCRIPTION
        Fetches password type definitions used for RPC (Remote Password Changing).
        These define how Secret Server changes passwords on different systems.
        May reference Scripts for custom password changing logic.
    #>
    param(
        [string]$BaseUrl,
        [string]$Token
    )

    Write-Log "[$script:CorrelationId] Exporting password types from source..." -Level Info

    $allPasswordTypes = [System.Collections.ArrayList]::new()

    try {
        $response = Invoke-SSApi -BaseUrl $BaseUrl -Endpoint "remote-password-changing/password-types" -Token $Token
        $pwTypes = if ($response.records) { $response.records } elseif ($response) { @($response) } else { @() }

        foreach ($pwType in $pwTypes) {
            # Only export custom types (built-in types exist on target)
            # Custom types typically have higher IDs or isCustom flag
            if ($pwType.passwordTypeId -gt 100 -or $pwType.isCustom -eq $true -or $pwType.customPort -ne $null) {
                try {
                    # Get full details
                    $details = Invoke-SSApi -BaseUrl $BaseUrl -Endpoint "remote-password-changing/password-types/$($pwType.passwordTypeId)" -Token $Token
                    [void]$allPasswordTypes.Add([PSCustomObject]@{
                        passwordTypeId = $details.passwordTypeId
                        name = $details.name
                        typeName = $details.typeName
                        active = $details.active
                        # Script references (will need ID mapping)
                        heartbeatScriptId = $details.heartbeatScriptId
                        rpcScriptId = $details.rpcScriptId
                        # Other settings
                        customPort = $details.customPort
                        scanItemTemplateId = $details.scanItemTemplateId
                        isCustom = $true
                        # Store full object for any additional fields
                        _raw = $details
                    })
                }
                catch {
                    Write-Log "[$script:CorrelationId] Failed to get details for password type $($pwType.passwordTypeId): $_" -Level Warning
                }
            }
        }
    }
    catch {
        Write-Log "[$script:CorrelationId] Error fetching password types: $_" -Level Error
        return @()
    }

    Write-Log "[$script:CorrelationId] Exported $($allPasswordTypes.Count) custom password types" -Level Success
    return $allPasswordTypes
}

function Import-PasswordTypes {
    <#
    .SYNOPSIS
        Import password types to target
    .DESCRIPTION
        Creates password types on target and records ID mapping.
        Remaps Script references using the Scripts IdMap.
    #>
    param(
        [string]$BaseUrl,
        [string]$Token,
        [array]$PasswordTypes
    )

    if ($PasswordTypes.Count -eq 0) {
        Write-Log "[$script:CorrelationId] No password types to import" -Level Info
        return @{ Success = @(); Failed = @(); Skipped = @() }
    }

    Write-Log "[$script:CorrelationId] Importing $($PasswordTypes.Count) password types..." -Level Info

    $results = @{
        Success = [System.Collections.ArrayList]::new()
        Failed = [System.Collections.ArrayList]::new()
        Skipped = [System.Collections.ArrayList]::new()
    }

    # Get existing password types on target for duplicate detection
    $existingTypes = @{}
    try {
        $response = Invoke-SSApi -BaseUrl $BaseUrl -Endpoint "remote-password-changing/password-types" -Token $Token
        $targetTypes = if ($response.records) { $response.records } else { @() }
        foreach ($t in $targetTypes) {
            $existingTypes[$t.name.ToLower()] = $t
        }
    }
    catch {
        Write-Log "[$script:CorrelationId] Could not fetch existing password types from target: $_" -Level Warning
    }

    $count = 0
    foreach ($pwType in $PasswordTypes) {
        $count++
        Show-Progress -Activity "Importing password types" -Current $count -Total $PasswordTypes.Count

        # Check for duplicate by name
        $existingMatch = $existingTypes[$pwType.name.ToLower()]
        if ($existingMatch) {
            Write-Log "[$script:CorrelationId] Password type '$($pwType.name)' already exists on target (ID: $($existingMatch.passwordTypeId)), mapping" -Level Info
            Set-IdMapping -ObjectType 'PasswordTypes' -SourceId $pwType.passwordTypeId -TargetId $existingMatch.passwordTypeId -Name $pwType.name
            [void]$results.Skipped.Add([PSCustomObject]@{
                SourceId = $pwType.passwordTypeId
                TargetId = $existingMatch.passwordTypeId
                Name = $pwType.name
                Reason = "Already exists"
            })
            continue
        }

        try {
            # Remap script IDs if present
            $targetHeartbeatScriptId = $null
            $targetRpcScriptId = $null

            if ($pwType.heartbeatScriptId) {
                $targetHeartbeatScriptId = Get-IdMapping -ObjectType 'Scripts' -SourceId $pwType.heartbeatScriptId
                if (-not $targetHeartbeatScriptId) {
                    Write-Log "[$script:CorrelationId] Warning: Heartbeat script $($pwType.heartbeatScriptId) not found in mapping for '$($pwType.name)'" -Level Warning
                }
            }

            if ($pwType.rpcScriptId) {
                $targetRpcScriptId = Get-IdMapping -ObjectType 'Scripts' -SourceId $pwType.rpcScriptId
                if (-not $targetRpcScriptId) {
                    Write-Log "[$script:CorrelationId] Warning: RPC script $($pwType.rpcScriptId) not found in mapping for '$($pwType.name)'" -Level Warning
                }
            }

            $body = @{
                name = $pwType.name
                typeName = $pwType.typeName
                active = $pwType.active
            }

            # Add script references if mapped
            if ($targetHeartbeatScriptId) { $body.heartbeatScriptId = $targetHeartbeatScriptId }
            if ($targetRpcScriptId) { $body.rpcScriptId = $targetRpcScriptId }
            if ($pwType.customPort) { $body.customPort = $pwType.customPort }

            $result = Invoke-SSApi -BaseUrl $BaseUrl -Endpoint "remote-password-changing/password-types" -Token $Token -Method Post -Body $body

            Set-IdMapping -ObjectType 'PasswordTypes' -SourceId $pwType.passwordTypeId -TargetId $result.passwordTypeId -Name $pwType.name

            [void]$results.Success.Add([PSCustomObject]@{
                SourceId = $pwType.passwordTypeId
                TargetId = $result.passwordTypeId
                Name = $pwType.name
            })

            Write-Log "[$script:CorrelationId] Created password type '$($pwType.name)' (Source: $($pwType.passwordTypeId) → Target: $($result.passwordTypeId))" -Level Info
        }
        catch {
            Write-Log "[$script:CorrelationId] Failed to create password type '$($pwType.name)': $_" -Level Error
            [void]$results.Failed.Add([PSCustomObject]@{
                SourceId = $pwType.passwordTypeId
                Name = $pwType.name
                Error = $_.Exception.Message
            })
        }
    }

    Write-Log "[$script:CorrelationId] Password types import complete: $($results.Success.Count) created, $($results.Skipped.Count) existing, $($results.Failed.Count) failed" -Level Success
    return $results
}

#endregion

#region Lists Migration (v3.1)

function Export-Lists {
    <#
    .SYNOPSIS
        Export all lists from source
    .DESCRIPTION
        Fetches dropdown lists used in secret template fields.
        Lists provide the available options for dropdown/list fields.
    #>
    param(
        [string]$BaseUrl,
        [string]$Token
    )

    Write-Log "[$script:CorrelationId] Exporting lists from source..." -Level Info

    $allLists = [System.Collections.ArrayList]::new()

    try {
        $response = Invoke-SSApi -BaseUrl $BaseUrl -Endpoint "lists" -Token $Token
        $lists = if ($response.records) { $response.records } elseif ($response) { @($response) } else { @() }

        foreach ($list in $lists) {
            try {
                # Get full list details including items
                $details = Invoke-SSApi -BaseUrl $BaseUrl -Endpoint "lists/$($list.categorizedListId)" -Token $Token

                # Also get the list items/options
                $itemsResponse = Invoke-SSApi -BaseUrl $BaseUrl -Endpoint "lists/$($list.categorizedListId)/options" -Token $Token -ErrorAction SilentlyContinue
                $items = if ($itemsResponse.records) { $itemsResponse.records } elseif ($itemsResponse) { @($itemsResponse) } else { @() }

                [void]$allLists.Add([PSCustomObject]@{
                    categorizedListId = $details.categorizedListId
                    name = $details.name
                    description = $details.description
                    active = $details.active
                    items = $items
                    _raw = $details
                })
            }
            catch {
                Write-Log "[$script:CorrelationId] Failed to get details for list $($list.categorizedListId): $_" -Level Warning
                # Add basic info without items
                [void]$allLists.Add([PSCustomObject]@{
                    categorizedListId = $list.categorizedListId
                    name = $list.name
                    description = $list.description
                    active = $list.active
                    items = @()
                    _raw = $null
                })
            }
        }
    }
    catch {
        Write-Log "[$script:CorrelationId] Error fetching lists: $_" -Level Error
        return @()
    }

    Write-Log "[$script:CorrelationId] Exported $($allLists.Count) lists" -Level Success
    return $allLists
}

function Import-Lists {
    <#
    .SYNOPSIS
        Import lists to target
    .DESCRIPTION
        Creates lists on target with their items/options.
        Records ID mapping for template field references.
    #>
    param(
        [string]$BaseUrl,
        [string]$Token,
        [array]$Lists
    )

    if ($Lists.Count -eq 0) {
        Write-Log "[$script:CorrelationId] No lists to import" -Level Info
        return @{ Success = @(); Failed = @(); Skipped = @() }
    }

    Write-Log "[$script:CorrelationId] Importing $($Lists.Count) lists..." -Level Info

    $results = @{
        Success = [System.Collections.ArrayList]::new()
        Failed = [System.Collections.ArrayList]::new()
        Skipped = [System.Collections.ArrayList]::new()
    }

    # Get existing lists on target for duplicate detection
    $existingLists = @{}
    try {
        $response = Invoke-SSApi -BaseUrl $BaseUrl -Endpoint "lists" -Token $Token
        $targetLists = if ($response.records) { $response.records } else { @() }
        foreach ($l in $targetLists) {
            $existingLists[$l.name.ToLower()] = $l
        }
    }
    catch {
        Write-Log "[$script:CorrelationId] Could not fetch existing lists from target: $_" -Level Warning
    }

    $count = 0
    foreach ($list in $Lists) {
        $count++
        Show-Progress -Activity "Importing lists" -Current $count -Total $Lists.Count

        # Check for duplicate by name
        $existingMatch = $existingLists[$list.name.ToLower()]
        if ($existingMatch) {
            Write-Log "[$script:CorrelationId] List '$($list.name)' already exists on target (ID: $($existingMatch.categorizedListId)), mapping" -Level Info
            Set-IdMapping -ObjectType 'Lists' -SourceId $list.categorizedListId -TargetId $existingMatch.categorizedListId -Name $list.name
            [void]$results.Skipped.Add([PSCustomObject]@{
                SourceId = $list.categorizedListId
                TargetId = $existingMatch.categorizedListId
                Name = $list.name
                Reason = "Already exists"
            })
            continue
        }

        try {
            # Create the list
            $body = @{
                name = $list.name
                description = $list.description
                active = $list.active
            }

            $result = Invoke-SSApi -BaseUrl $BaseUrl -Endpoint "lists" -Token $Token -Method Post -Body $body

            $newListId = $result.categorizedListId

            # Add list items/options
            $itemsCreated = 0
            if ($list.items -and $list.items.Count -gt 0) {
                foreach ($item in $list.items) {
                    try {
                        $itemBody = @{
                            value = $item.value
                            category = $item.category
                        }
                        Invoke-SSApi -BaseUrl $BaseUrl -Endpoint "lists/$newListId/options" -Token $Token -Method Post -Body $itemBody | Out-Null
                        $itemsCreated++
                    }
                    catch {
                        Write-Log "[$script:CorrelationId] Failed to add item '$($item.value)' to list '$($list.name)': $_" -Level Warning
                    }
                }
            }

            Set-IdMapping -ObjectType 'Lists' -SourceId $list.categorizedListId -TargetId $newListId -Name $list.name

            [void]$results.Success.Add([PSCustomObject]@{
                SourceId = $list.categorizedListId
                TargetId = $newListId
                Name = $list.name
                ItemsCreated = $itemsCreated
            })

            Write-Log "[$script:CorrelationId] Created list '$($list.name)' with $itemsCreated items (Source: $($list.categorizedListId) → Target: $newListId)" -Level Info
        }
        catch {
            Write-Log "[$script:CorrelationId] Failed to create list '$($list.name)': $_" -Level Error
            [void]$results.Failed.Add([PSCustomObject]@{
                SourceId = $list.categorizedListId
                Name = $list.name
                Error = $_.Exception.Message
            })
        }
    }

    Write-Log "[$script:CorrelationId] Lists import complete: $($results.Success.Count) created, $($results.Skipped.Count) existing, $($results.Failed.Count) failed" -Level Success
    return $results
}

#endregion

#region Folder Migration (v3.0)

function Export-Folders {
    <#
    .SYNOPSIS
        Export all folders from source with full hierarchy
    .DESCRIPTION
        Fetches folders and captures: id, name, parentFolderId, secretPolicyId, inheritSecretPolicy
    #>
    param(
        [string]$BaseUrl,
        [string]$Token
    )

    Write-Log "[$script:CorrelationId] Exporting folders from source..." -Level Info

    $allFolders = [System.Collections.ArrayList]::new()

    try {
        $response = Invoke-SSApi -BaseUrl $BaseUrl -Endpoint "folders?take=1000" -Token $Token
        if ($response.records) {
            foreach ($folder in $response.records) {
                [void]$allFolders.Add([PSCustomObject]@{
                    id = $folder.id
                    folderName = $folder.folderName
                    parentFolderId = $folder.parentFolderId
                    secretPolicyId = $folder.secretPolicyId
                    inheritSecretPolicy = $folder.inheritSecretPolicy
                    folderPath = $folder.folderPath
                })
            }
        }
    }
    catch {
        Write-Log "[$script:CorrelationId] Error fetching folders: $_" -Level Error
        return @()
    }

    Write-Log "[$script:CorrelationId] Exported $($allFolders.Count) folders" -Level Success
    return $allFolders
}

function Sort-FoldersByDepth {
    <#
    .SYNOPSIS
        Sort folders by hierarchy depth (parents before children)
    .DESCRIPTION
        Uses parentFolderId to determine depth. Root folders (parentFolderId = -1) come first.
    #>
    param(
        [array]$Folders
    )

    # Build depth map
    $depthMap = @{}
    foreach ($folder in $Folders) {
        $depth = 0
        $current = $folder
        $visited = @{}

        while ($current.parentFolderId -and $current.parentFolderId -ne -1) {
            if ($visited.ContainsKey($current.id)) {
                Write-Log "[$script:CorrelationId] Circular folder reference detected at folder $($current.id)" -Level Warning
                break
            }
            $visited[$current.id] = $true
            $depth++
            $parent = $Folders | Where-Object { $_.id -eq $current.parentFolderId }
            if (-not $parent) { break }
            $current = $parent
        }
        $depthMap[$folder.id] = $depth
    }

    # Sort by depth (ascending - parents first)
    return $Folders | Sort-Object { $depthMap[$_.id] }
}

function Import-FoldersPass1 {
    <#
    .SYNOPSIS
        Import folders WITHOUT policy assignments (Pass 1)
    .DESCRIPTION
        Creates folder hierarchy on target. Policies assigned in Pass 2 after policies are created.
    #>
    param(
        [string]$TargetUrl,
        [string]$TargetToken,
        [array]$Folders
    )

    Write-Log "[$script:CorrelationId] Creating folder structure on target (Pass 1)..." -Level Info

    $sorted = Sort-FoldersByDepth -Folders $Folders
    $created = 0
    $skipped = 0
    $failed = 0

    foreach ($folder in $sorted) {
        # Skip root folder (cannot create)
        if ($folder.parentFolderId -eq -1 -and $folder.folderName -eq "Root") {
            # Map root to root (usually ID 1 on both)
            Set-IdMapping -ObjectType 'Folders' -SourceId $folder.id -TargetId -1 -Name $folder.folderName
            $skipped++
            continue
        }

        try {
            # Map parent folder ID
            $targetParentId = Get-MappedId -ObjectType 'Folders' -SourceId $folder.parentFolderId
            if (-not $targetParentId -and $folder.parentFolderId -ne -1) {
                Write-Log "[$script:CorrelationId] Skipping folder '$($folder.folderName)' - parent not mapped" -Level Warning
                $skipped++
                continue
            }

            # Check if folder already exists
            $existing = Invoke-SSApi -BaseUrl $TargetUrl -Endpoint "folders?filter.searchText=$([uri]::EscapeDataString($folder.folderName))&take=100" -Token $TargetToken
            $match = $existing.records | Where-Object {
                $_.folderName -eq $folder.folderName -and $_.parentFolderId -eq $targetParentId
            }

            if ($match) {
                Set-IdMapping -ObjectType 'Folders' -SourceId $folder.id -TargetId $match.id -Name $folder.folderName
                Write-Log "[$script:CorrelationId] Folder '$($folder.folderName)' already exists (ID: $($match.id))" -Level Debug
                $skipped++
                continue
            }

            # Create folder (without policy - that's Pass 2)
            $body = @{
                folderName = $folder.folderName
                parentFolderId = if ($targetParentId) { $targetParentId } else { -1 }
                inheritSecretPolicy = $true  # Default to inherit until we set explicit policy
                secretPolicyId = -1
            }

            $result = Invoke-SSApi -BaseUrl $TargetUrl -Endpoint "folders" -Method POST -Body $body -Token $TargetToken
            Set-IdMapping -ObjectType 'Folders' -SourceId $folder.id -TargetId $result.id -Name $folder.folderName
            $created++

            Show-Progress -Activity "Creating folders" -Current ($created + $skipped + $failed) -Total $sorted.Count
        }
        catch {
            Write-Log "[$script:CorrelationId] Failed to create folder '$($folder.folderName)': $_" -Level Error
            $failed++
        }
    }

    Write-Host ""
    Write-Log "[$script:CorrelationId] Folder Pass 1: $created created, $skipped skipped, $failed failed" -Level $(if ($failed -eq 0) { 'Success' } else { 'Warning' })

    return @{
        Created = $created
        Skipped = $skipped
        Failed = $failed
    }
}

function Export-SecretPolicies {
    <#
    .SYNOPSIS
        Export all secret policies from source
    #>
    param(
        [string]$BaseUrl,
        [string]$Token
    )

    Write-Log "[$script:CorrelationId] Exporting secret policies from source..." -Level Info

    $allPolicies = [System.Collections.ArrayList]::new()

    try {
        $response = Invoke-SSApi -BaseUrl $BaseUrl -Endpoint "secret-policies?take=1000" -Token $Token
        if ($response.records) {
            foreach ($policy in $response.records) {
                # Get full policy details
                try {
                    $fullPolicy = Invoke-SSApi -BaseUrl $BaseUrl -Endpoint "secret-policies/$($policy.id)" -Token $Token
                    [void]$allPolicies.Add($fullPolicy)
                }
                catch {
                    Write-Log "[$script:CorrelationId] Could not fetch details for policy $($policy.id): $_" -Level Warning
                    [void]$allPolicies.Add($policy)
                }
            }
        }
    }
    catch {
        Write-Log "[$script:CorrelationId] Error fetching policies: $_" -Level Error
        return @()
    }

    Write-Log "[$script:CorrelationId] Exported $($allPolicies.Count) secret policies" -Level Success
    return $allPolicies
}

function Import-SecretPolicies {
    <#
    .SYNOPSIS
        Import secret policies to target
    .DESCRIPTION
        Creates policies on target. Handles duplicates based on policy name.
    #>
    param(
        [string]$TargetUrl,
        [string]$TargetToken,
        [array]$Policies,
        [ValidateSet('Skip', 'Rename', 'Fail')]
        [string]$ConflictPolicy = 'Skip'
    )

    Write-Log "[$script:CorrelationId] Importing secret policies to target..." -Level Info

    # Get existing policies on target for duplicate check
    $existingPolicies = @{}
    try {
        $existing = Invoke-SSApi -BaseUrl $TargetUrl -Endpoint "secret-policies?take=1000" -Token $TargetToken
        foreach ($p in $existing.records) {
            $existingPolicies[$p.secretPolicyName.ToLower()] = $p
        }
    }
    catch {
        Write-Log "[$script:CorrelationId] Could not fetch existing policies: $_" -Level Warning
    }

    $created = 0
    $skipped = 0
    $failed = 0

    foreach ($policy in $Policies) {
        $policyName = $policy.secretPolicyName

        # Check for existing policy
        $match = $existingPolicies[$policyName.ToLower()]
        if ($match) {
            if ($ConflictPolicy -eq 'Skip') {
                Set-IdMapping -ObjectType 'Policies' -SourceId $policy.secretPolicyId -TargetId $match.secretPolicyId -Name $policyName
                Write-Log "[$script:CorrelationId] Policy '$policyName' already exists - mapping to existing" -Level Debug
                $skipped++
                continue
            }
            elseif ($ConflictPolicy -eq 'Rename') {
                $policyName = "$policyName-migrated"
            }
            elseif ($ConflictPolicy -eq 'Fail') {
                Write-Log "[$script:CorrelationId] Policy '$policyName' already exists - stopping" -Level Error
                throw "Policy name conflict: $policyName"
            }
        }

        try {
            # Create policy - stripping source-specific IDs
            $body = @{
                secretPolicyName = $policyName
                secretPolicyDescription = $policy.secretPolicyDescription
                active = $policy.active
            }

            # Add policy items if present (settings like checkout, expiration, etc.)
            if ($policy.secretPolicyItems) {
                $body.secretPolicyItems = $policy.secretPolicyItems
            }

            $result = Invoke-SSApi -BaseUrl $TargetUrl -Endpoint "secret-policies" -Method POST -Body $body -Token $TargetToken
            Set-IdMapping -ObjectType 'Policies' -SourceId $policy.secretPolicyId -TargetId $result.secretPolicyId -Name $policyName
            $created++

            Show-Progress -Activity "Creating policies" -Current ($created + $skipped + $failed) -Total $Policies.Count
        }
        catch {
            Write-Log "[$script:CorrelationId] Failed to create policy '$policyName': $_" -Level Error
            $failed++
        }
    }

    Write-Host ""
    Write-Log "[$script:CorrelationId] Policy import: $created created, $skipped skipped, $failed failed" -Level $(if ($failed -eq 0) { 'Success' } else { 'Warning' })

    return @{
        Created = $created
        Skipped = $skipped
        Failed = $failed
    }
}

function Update-FolderPolicies {
    <#
    .SYNOPSIS
        Assign policies to folders (Pass 2)
    .DESCRIPTION
        After policies are created, update folders that had specific policy assignments.
    #>
    param(
        [string]$TargetUrl,
        [string]$TargetToken,
        [array]$SourceFolders
    )

    Write-Log "[$script:CorrelationId] Assigning policies to folders (Pass 2)..." -Level Info

    $updated = 0
    $skipped = 0
    $failed = 0

    foreach ($folder in $SourceFolders) {
        # Skip folders that inherit or have no policy
        if ($folder.inheritSecretPolicy -or -not $folder.secretPolicyId -or $folder.secretPolicyId -eq -1) {
            $skipped++
            continue
        }

        $targetFolderId = Get-MappedId -ObjectType 'Folders' -SourceId $folder.id
        $targetPolicyId = Get-MappedId -ObjectType 'Policies' -SourceId $folder.secretPolicyId

        if (-not $targetFolderId) {
            Write-Log "[$script:CorrelationId] Skipping folder '$($folder.folderName)' - not mapped" -Level Debug
            $skipped++
            continue
        }

        if (-not $targetPolicyId) {
            Write-Log "[$script:CorrelationId] Skipping folder '$($folder.folderName)' - policy not mapped" -Level Warning
            $skipped++
            continue
        }

        try {
            $body = @{
                id = $targetFolderId
                secretPolicyId = $targetPolicyId
                inheritSecretPolicy = $false
            }

            Invoke-SSApi -BaseUrl $TargetUrl -Endpoint "folders/$targetFolderId" -Method PUT -Body $body -Token $TargetToken
            $updated++

            Show-Progress -Activity "Assigning policies" -Current ($updated + $skipped + $failed) -Total $SourceFolders.Count
        }
        catch {
            Write-Log "[$script:CorrelationId] Failed to update folder '$($folder.folderName)' policy: $_" -Level Error
            $failed++
        }
    }

    Write-Host ""
    Write-Log "[$script:CorrelationId] Folder Pass 2: $updated updated, $skipped skipped, $failed failed" -Level $(if ($failed -eq 0) { 'Success' } else { 'Warning' })

    return @{
        Updated = $updated
        Skipped = $skipped
        Failed = $failed
    }
}

#endregion Folder Migration

#region Two-Pass Secret Migration (v3.0 - RPC/Privileged Account Linking)

function Get-SecretsWithRpc {
    <#
    .SYNOPSIS
        Identify secrets that have RPC/privileged account configuration
    .DESCRIPTION
        Returns secrets that reference other secrets as privileged accounts.
        These need Pass 2 processing to link after all secrets exist.
    #>
    param(
        [array]$Secrets
    )

    $secretsWithRpc = @()
    foreach ($secret in $Secrets) {
        # Check for privileged account reference
        if ($secret.launcherConnectAsSecretId -and $secret.launcherConnectAsSecretId -gt 0) {
            $secretsWithRpc += $secret
        }
        # Also check rpcConfig if present
        elseif ($secret.rpcConfig -and $secret.rpcConfig.launcherConnectAsSecretId -and $secret.rpcConfig.launcherConnectAsSecretId -gt 0) {
            $secretsWithRpc += $secret
        }
    }

    return $secretsWithRpc
}

function Test-CircularRpcReferences {
    <#
    .SYNOPSIS
        Detect circular references in privileged account chains
    .DESCRIPTION
        A->B->A is a circular reference. These secrets cannot have RPC
        enabled on both ends during migration. Returns cycles found.
    #>
    param(
        [array]$Secrets
    )

    Write-Log "[$script:CorrelationId] Checking for circular RPC references..." -Level Debug

    # Build adjacency map: secretId -> privilegedSecretId
    $graph = @{}
    foreach ($secret in $Secrets) {
        $privId = $secret.launcherConnectAsSecretId
        if (-not $privId -and $secret.rpcConfig) {
            $privId = $secret.rpcConfig.launcherConnectAsSecretId
        }
        if ($privId -and $privId -gt 0) {
            $graph[$secret.id] = $privId
        }
    }

    $cycles = @()
    $visited = @{}
    $inStack = @{}

    function Find-Cycle($nodeId, $path) {
        if ($inStack[$nodeId]) {
            # Found cycle - extract the cycle portion
            $cycleStart = $path.IndexOf($nodeId)
            return $path[$cycleStart..($path.Count - 1)]
        }
        if ($visited[$nodeId]) {
            return $null
        }

        $visited[$nodeId] = $true
        $inStack[$nodeId] = $true
        $path += $nodeId

        if ($graph.ContainsKey($nodeId)) {
            $nextId = $graph[$nodeId]
            $cycle = Find-Cycle $nextId $path
            if ($cycle) {
                return $cycle
            }
        }

        $inStack[$nodeId] = $false
        return $null
    }

    foreach ($secretId in $graph.Keys) {
        if (-not $visited[$secretId]) {
            $cycle = Find-Cycle $secretId @()
            if ($cycle -and $cycle.Count -gt 0) {
                $cycles += ,@($cycle)
            }
        }
    }

    if ($cycles.Count -gt 0) {
        Write-Log "[$script:CorrelationId] Found $($cycles.Count) circular RPC reference(s)" -Level Warning
        $script:ValidationReport.CircularRefs = @{
            Cycles = $cycles
            AffectedSecrets = $cycles | ForEach-Object { $_ } | Select-Object -Unique
        }
    }
    else {
        Write-Log "[$script:CorrelationId] No circular RPC references found" -Level Debug
    }

    return $cycles
}

function Update-SecretRpcConfig {
    <#
    .SYNOPSIS
        Update secrets with RPC/privileged account references (Pass 2)
    .DESCRIPTION
        After all secrets are created, update those that reference privileged
        accounts with the mapped target secret IDs.
    #>
    param(
        [string]$TargetUrl,
        [string]$TargetToken,
        [array]$SourceSecrets,
        [array]$CircularSecretIds = @()
    )

    Write-Log "[$script:CorrelationId] Updating secrets with RPC configuration (Pass 2)..." -Level Info

    $secretsWithRpc = Get-SecretsWithRpc -Secrets $SourceSecrets
    if ($secretsWithRpc.Count -eq 0) {
        Write-Log "[$script:CorrelationId] No secrets with RPC configuration to update" -Level Info
        return @{ Updated = 0; Skipped = 0; Failed = 0 }
    }

    Write-Log "[$script:CorrelationId] Found $($secretsWithRpc.Count) secrets with privileged account references" -Level Info

    $updated = 0
    $skipped = 0
    $failed = 0

    foreach ($secret in $secretsWithRpc) {
        # Get source privileged account ID
        $sourcePrivId = $secret.launcherConnectAsSecretId
        if (-not $sourcePrivId -and $secret.rpcConfig) {
            $sourcePrivId = $secret.rpcConfig.launcherConnectAsSecretId
        }

        # Skip circular references (these can't be linked)
        if ($secret.id -in $CircularSecretIds) {
            Write-Log "[$script:CorrelationId] Skipping '$($secret.name)' - circular reference" -Level Warning
            $script:ValidationReport.Warnings += "Secret '$($secret.name)' has circular RPC reference - created without RPC link"
            $skipped++
            continue
        }

        # Get mapped target IDs
        $targetSecretId = Get-MappedId -ObjectType 'Secrets' -SourceId $secret.id
        $targetPrivId = Get-MappedId -ObjectType 'Secrets' -SourceId $sourcePrivId

        if (-not $targetSecretId) {
            Write-Log "[$script:CorrelationId] Skipping '$($secret.name)' - not mapped to target" -Level Warning
            $skipped++
            continue
        }

        if (-not $targetPrivId) {
            Write-Log "[$script:CorrelationId] Skipping '$($secret.name)' - privileged account (source ID: $sourcePrivId) not mapped" -Level Warning
            $script:ValidationReport.Warnings += "Secret '$($secret.name)' privileged account not found on target"
            $skipped++
            continue
        }

        try {
            # Update secret with privileged account reference
            $body = @{
                launcherConnectAsSecretId = $targetPrivId
            }

            # Enable auto-change if it was enabled on source
            if ($secret.autoChangeEnabled -or ($secret.rpcConfig -and $secret.rpcConfig.autoChangeEnabled)) {
                $body.autoChangeEnabled = $true
            }

            Invoke-SSApi -BaseUrl $TargetUrl -Endpoint "secrets/$targetSecretId" -Method PUT -Body $body -Token $TargetToken
            $updated++

            Write-Log "[$script:CorrelationId] Linked '$($secret.name)' to privileged account (target ID: $targetPrivId)" -Level Debug
            Show-Progress -Activity "Linking RPC" -Current ($updated + $skipped + $failed) -Total $secretsWithRpc.Count
        }
        catch {
            Write-Log "[$script:CorrelationId] Failed to update RPC for '$($secret.name)': $_" -Level Error
            $failed++
        }
    }

    Write-Host ""
    Write-Log "[$script:CorrelationId] RPC Pass 2: $updated linked, $skipped skipped, $failed failed" -Level $(if ($failed -eq 0) { 'Success' } else { 'Warning' })

    return @{
        Updated = $updated
        Skipped = $skipped
        Failed = $failed
    }
}

#endregion Two-Pass Secret Migration

#endregion

#region Main Wizard
function Start-MigrationWizard {
    Show-Banner

    # Check for checkpoint
    if ($Resume -or (Test-Path $script:Config.CheckpointFile)) {
        if (Restore-Checkpoint) {
            Write-Log "Resuming from checkpoint..." -Level Info
        }
    }

    # Main menu
    $menuChoice = Show-Menu -Title "What would you like to do?" -Options @(
        "Full Migration (guided wizard)"
        "Export only (save secrets to file)"
        "Import from file (use existing export)"
        "Validate existing migration"
        "Exit"
    )

    switch ($menuChoice) {
        0 { Start-FullMigration }
        1 { Start-ExportOnly }
        2 { Start-ImportFromFile }
        3 { Start-ValidationOnly }
        4 {
            Write-Log "Goodbye!" -Level Info
            return
        }
    }
}

function Start-FullMigration {
    Write-Host "`n═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "                    FULL MIGRATION WIZARD                       " -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════`n" -ForegroundColor Cyan

    # Step 1: Gather connection info
    Write-Host "STEP 1: Connection Information" -ForegroundColor Cyan
    Write-Host "------------------------------`n"

    # Source
    Write-Host "SOURCE Secret Server (where secrets are now):" -ForegroundColor Yellow
    $script:State.SourceUrl = Read-UrlWithRetry -Prompt "Source URL (e.g., https://company.secretservercloud.com)" -Label "Source"
    if (-not $script:State.SourceUrl) {
        Write-Log "Source URL required. Exiting." -Level Error
        return
    }

    $sourceUser = Read-Prompt -Prompt "Source username" -Required
    $sourcePass = Read-SecurePrompt -Prompt "Source password: "

    # Target
    Write-Host "`nTARGET Secret Server (where secrets will go):" -ForegroundColor Yellow
    $script:State.TargetUrl = Read-UrlWithRetry -Prompt "Target URL (e.g., https://company.secretservercloud.com)" -Label "Target"
    if (-not $script:State.TargetUrl) {
        Write-Log "Target URL required. Exiting." -Level Error
        return
    }

    $targetUser = Read-Prompt -Prompt "Target username" -Required
    $targetPass = Read-SecurePrompt -Prompt "Target password: "

    # Step 2: Pre-flight checks
    Write-Host "`nSTEP 2: Pre-flight Checks" -ForegroundColor Cyan
    Write-Host "-------------------------`n"

    Write-Log "Authenticating to source..." -Level Info
    try {
        $authResult = Get-SSToken -BaseUrl $script:State.SourceUrl -Username $sourceUser -Password $sourcePass
        $script:State.SourceToken = $authResult.Token
        $script:State.SourceTokenExpiry = $authResult.Expiry
        Write-Log "Source authentication successful" -Level Success
    }
    catch {
        $errMsg = Get-ErrorMessage -Code "E1001" -Details "Source: $_" -Resolution "Check credentials and API access"
        Write-Log $errMsg -Level Error
        return
    }

    Write-Log "Authenticating to target..." -Level Info
    try {
        $authResult = Get-SSToken -BaseUrl $script:State.TargetUrl -Username $targetUser -Password $targetPass
        $script:State.TargetToken = $authResult.Token
        $script:State.TargetTokenExpiry = $authResult.Expiry
        Write-Log "Target authentication successful" -Level Success
    }
    catch {
        $errMsg = Get-ErrorMessage -Code "E1001" -Details "Target: $_" -Resolution "Check credentials and API access"
        Write-Log $errMsg -Level Error
        return
    }

    # Clear passwords
    $sourcePass = $null
    $targetPass = $null
    [GC]::Collect()

    # Test permissions
    Write-Log "Checking source permissions..." -Level Info
    $sourcePerms = Test-Permissions -BaseUrl $script:State.SourceUrl -Token $script:State.SourceToken -Role Source
    Write-Log "  Can list secrets: $($sourcePerms.CanListSecrets)" -Level $(if ($sourcePerms.CanListSecrets) { 'Success' } else { 'Error' })
    Write-Log "  Can read secrets: $($sourcePerms.CanReadSecrets)" -Level $(if ($sourcePerms.CanReadSecrets) { 'Success' } else { 'Error' })
    Write-Log "  Secret count: $($sourcePerms.SecretCount)" -Level Info

    if (-not $sourcePerms.CanListSecrets -or -not $sourcePerms.CanReadSecrets) {
        $errMsg = Get-ErrorMessage -Code "E2006" -Details "Source needs List and Read Secrets" -Resolution "Grant 'View Secret' role to user"
        Write-Log $errMsg -Level Error
        return
    }

    Write-Log "Checking target permissions..." -Level Info
    $targetPerms = Test-Permissions -BaseUrl $script:State.TargetUrl -Token $script:State.TargetToken -Role Target
    Write-Log "  Can create secrets: $($targetPerms.CanCreateSecrets)" -Level $(if ($targetPerms.CanCreateSecrets) { 'Success' } else { 'Error' })
    Write-Log "  Existing secrets: $($targetPerms.SecretCount)" -Level Info

    if (-not $targetPerms.CanCreateSecrets) {
        $errMsg = Get-ErrorMessage -Code "E2006" -Details "Target needs Create Secrets" -Resolution "Grant 'Add Secret' role to user"
        Write-Log $errMsg -Level Error
        return
    }

    Write-Log "Pre-flight checks passed!" -Level Success

    # Step 2b: Migration Mode Selection (v3.0)
    Write-Host "`nMIGRATION MODE" -ForegroundColor Cyan
    Write-Host "--------------`n"

    Write-Host "Choose what to migrate:" -ForegroundColor Yellow
    Write-Host ""

    $modeChoice = Show-Menu -Title "Migration Mode" -Options @(
        "Secrets Only - Migrate secrets to existing folder structure (fastest)"
        "Full Migration - Migrate folders, policies, AND secrets (complete)"
    )

    $script:MigrationMode = switch ($modeChoice) {
        0 { "SecretsOnly" }
        1 { "Full" }
    }

    Write-Log "Migration mode: $script:MigrationMode" -Level Info

    # Full mode: Run pre-flight validation for sites/templates
    if ($script:MigrationMode -eq "Full") {
        Write-Host "`nPRE-FLIGHT VALIDATION" -ForegroundColor Cyan
        Write-Host "---------------------`n"

        Write-Log "Running pre-flight validation for Full migration..." -Level Info

        # Get secrets for validation (lightweight list)
        $secretList = (Invoke-SSApi -BaseUrl $script:State.SourceUrl -Endpoint "secrets?take=10000" -Token $script:State.SourceToken).records

        $canProceed = Invoke-PreFlightValidation `
            -SourceUrl $script:State.SourceUrl -SourceToken $script:State.SourceToken `
            -TargetUrl $script:State.TargetUrl -TargetToken $script:State.TargetToken `
            -SourceSecrets $secretList

        if (-not $canProceed) {
            Write-Host ""
            $forceChoice = Show-Menu -Title "Blocking issues detected. How to proceed?" -Options @(
                "Abort migration"
                "Continue anyway (may cause failures)"
                "Switch to Secrets Only mode"
            )

            switch ($forceChoice) {
                0 {
                    Write-Log "Migration aborted due to blocking issues." -Level Warning
                    return
                }
                1 {
                    Write-Log "Continuing despite blocking issues (user override)" -Level Warning
                }
                2 {
                    $script:MigrationMode = "SecretsOnly"
                    Write-Log "Switched to SecretsOnly mode" -Level Info
                }
            }
        }
        else {
            Write-Log "Pre-flight validation passed!" -Level Success
        }
    }

    # Step 2c: Duplicate Name Policy
    Write-Host "`nDUPLICATE NAME HANDLING" -ForegroundColor Cyan
    Write-Host "-----------------------`n"

    Write-Host "If a secret name already exists on the target, how should it be handled?" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Note: Secret Server can be configured to allow duplicate names." -ForegroundColor Gray
    Write-Host "      If your target allows duplicates, use 'Trust Target' for fastest import." -ForegroundColor Gray
    Write-Host ""

    $policyChoice = Show-Menu -Title "Duplicate Name Policy" -Options @(
        "Trust Target - Skip duplicate checking, let Secret Server handle it (Recommended for bulk)"
        "Fail - Stop import on any duplicate (safest)"
        "Skip - Skip duplicates, import only new secrets"
        "Rename - Append '$($script:Config.DuplicateRenameSuffix)' suffix to duplicates"
    )

    $script:Config.DuplicateNamePolicy = switch ($policyChoice) {
        0 { "TrustTarget" }
        1 { "Fail" }
        2 { "Skip" }
        3 { "Rename" }
    }

    Write-Log "Duplicate policy set to: $($script:Config.DuplicateNamePolicy)" -Level Info

    # Step 3: Export
    # Step 3: Export (scripts/password types/folders/policies if Full mode, then secrets)
    if ($script:MigrationMode -eq "Full") {
        Write-Host "`nSTEP 3a: Export RPC Config, Folders & Policies" -ForegroundColor Cyan
        Write-Host "----------------------------------------------`n"

        Write-Log "Exporting scripts from source..." -Level Info
        $script:State.ExportedScripts = Export-Scripts -BaseUrl $script:State.SourceUrl -Token $script:State.SourceToken

        Write-Log "Exporting password types from source..." -Level Info
        $script:State.ExportedPasswordTypes = Export-PasswordTypes -BaseUrl $script:State.SourceUrl -Token $script:State.SourceToken

        Write-Log "Exporting lists from source..." -Level Info
        $script:State.ExportedLists = Export-Lists -BaseUrl $script:State.SourceUrl -Token $script:State.SourceToken

        Write-Log "Exporting folders from source..." -Level Info
        $script:State.ExportedFolders = Export-Folders -BaseUrl $script:State.SourceUrl -Token $script:State.SourceToken

        Write-Log "Exporting secret policies from source..." -Level Info
        $script:State.ExportedPolicies = Export-SecretPolicies -BaseUrl $script:State.SourceUrl -Token $script:State.SourceToken

        Write-Host "  Scripts: $($script:State.ExportedScripts.Count)" -ForegroundColor Green
        Write-Host "  Password Types: $($script:State.ExportedPasswordTypes.Count)" -ForegroundColor Green
        Write-Host "  Lists: $($script:State.ExportedLists.Count)" -ForegroundColor Green
        Write-Host "  Folders: $($script:State.ExportedFolders.Count)" -ForegroundColor Green
        Write-Host "  Policies: $($script:State.ExportedPolicies.Count)" -ForegroundColor Green
    }

    Write-Host "`nSTEP 3$(if ($script:MigrationMode -eq 'Full') { 'b' } else { '' }): Export Secrets" -ForegroundColor Cyan
    Write-Host "----------------------`n"

    if (-not (Read-Confirmation "Ready to export $($sourcePerms.SecretCount) secrets from source?")) {
        Write-Log "Export cancelled." -Level Warning
        return
    }

    $secrets = Export-Secrets -BaseUrl $script:State.SourceUrl -Token $script:State.SourceToken

    # Step 4: Dry Run (and optional duplicate analysis)
    Write-Host "`nSTEP 4: Dry Run" -ForegroundColor Cyan
    Write-Host "---------------`n"

    $existingNames = @{}

    if ($script:Config.DuplicateNamePolicy -eq "TrustTarget") {
        # Skip duplicate analysis entirely - fastest path for bulk imports
        Write-Log "Trust Target mode - skipping duplicate analysis (Secret Server will handle duplicates)" -Level Info
        Write-Log "Performing dry run (no changes will be made)..." -Level Info
        $dryRunResults = Import-Secrets -BaseUrl $script:State.TargetUrl -Token $script:State.TargetToken -Secrets $secrets -DryRun

        Write-Host "`nDry run summary:" -ForegroundColor Yellow
        Write-Host "  Would create: $($dryRunResults.Success.Count) secrets"
        Write-Host "  Would fail:   $($dryRunResults.Failed.Count) secrets"
    }
    else {
        # Fetch existing names for duplicate detection (slower, but needed for Skip/Rename/Fail policies)
        Write-Log "Analyzing target for potential duplicate names..." -Level Info
        $existingNames = Get-ExistingSecretNames -BaseUrl $script:State.TargetUrl -Token $script:State.TargetToken

        # Show duplicate analysis
        $duplicates = Show-DuplicateAnalysis -Secrets $secrets -ExistingNames $existingNames

        if ($duplicates.Count -gt 0) {
            Write-Host ""
            Write-Host "Policy '$($script:Config.DuplicateNamePolicy)' will be applied to $($duplicates.Count) duplicates." -ForegroundColor Yellow

            if ($script:Config.DuplicateNamePolicy -eq "Fail") {
                Write-Host ""
                Write-Host "WARNING: With 'Fail' policy, the import will stop at the first duplicate." -ForegroundColor Red
                Write-Host "Consider switching to 'Skip' or 'Rename' policy if you want to proceed." -ForegroundColor Red
                Write-Host ""

                $changePolicy = Show-Menu -Title "Change duplicate policy?" -Options @(
                    "Continue with 'Fail' policy"
                    "Change to 'Skip' (skip duplicates)"
                    "Change to 'Rename' (add suffix)"
                    "Change to 'Trust Target' (let SS handle it)"
                    "Cancel migration"
                )

                switch ($changePolicy) {
                    0 {
                        # Continue with Fail policy - no change needed
                    }
                    1 {
                        $script:Config.DuplicateNamePolicy = "Skip"
                        Write-Log "Policy changed to: Skip" -Level Info
                    }
                    2 {
                        $script:Config.DuplicateNamePolicy = "Rename"
                        Write-Log "Policy changed to: Rename" -Level Info
                    }
                    3 {
                        $script:Config.DuplicateNamePolicy = "TrustTarget"
                        Write-Log "Policy changed to: TrustTarget" -Level Info
                    }
                    4 {
                        Write-Log "Migration cancelled." -Level Warning
                        return
                    }
                }
            }
        }
        else {
            Write-Log "No duplicate names detected - all secrets have unique names" -Level Success
        }

        Write-Host ""
        Write-Log "Performing dry run (no changes will be made)..." -Level Info
        $dryRunResults = Import-Secrets -BaseUrl $script:State.TargetUrl -Token $script:State.TargetToken -Secrets $secrets -DryRun -ExistingNames $existingNames

        Write-Host "`nDry run summary:" -ForegroundColor Yellow
        Write-Host "  Would create: $($dryRunResults.Success.Count) secrets"
        Write-Host "  Would skip:   $($dryRunResults.Skipped.Count) secrets (duplicates)"
        Write-Host "  Would rename: $($dryRunResults.Renamed.Count) secrets"
        Write-Host "  Would fail:   $($dryRunResults.Failed.Count) secrets"
    }

    # Step 5: Import
    # Step 5: Import (scripts/password types/folders/policies if Full mode, then secrets)
    if ($script:MigrationMode -eq "Full") {
        # Scripts first (Password Types depend on them)
        if ($script:State.ExportedScripts -and $script:State.ExportedScripts.Count -gt 0) {
            Write-Host "`nSTEP 5a: Import Scripts" -ForegroundColor Cyan
            Write-Host "-----------------------`n"

            if (-not (Read-Confirmation "Create $($script:State.ExportedScripts.Count) scripts on target?")) {
                Write-Log "Script import cancelled." -Level Warning
                return
            }

            $scriptResults = Import-Scripts -BaseUrl $script:State.TargetUrl -Token $script:State.TargetToken -Scripts $script:State.ExportedScripts
            Write-Host "  Created: $($scriptResults.Success.Count), Existing: $($scriptResults.Skipped.Count), Failed: $($scriptResults.Failed.Count)" -ForegroundColor $(if ($scriptResults.Failed.Count -gt 0) { 'Yellow' } else { 'Green' })
            Save-Checkpoint
        }

        # Password Types second (depend on Scripts, needed by Secrets for RPC)
        if ($script:State.ExportedPasswordTypes -and $script:State.ExportedPasswordTypes.Count -gt 0) {
            Write-Host "`nSTEP 5b: Import Password Types" -ForegroundColor Cyan
            Write-Host "------------------------------`n"

            if (-not (Read-Confirmation "Create $($script:State.ExportedPasswordTypes.Count) password types on target?")) {
                Write-Log "Password type import cancelled." -Level Warning
                return
            }

            $pwTypeResults = Import-PasswordTypes -BaseUrl $script:State.TargetUrl -Token $script:State.TargetToken -PasswordTypes $script:State.ExportedPasswordTypes
            Write-Host "  Created: $($pwTypeResults.Success.Count), Existing: $($pwTypeResults.Skipped.Count), Failed: $($pwTypeResults.Failed.Count)" -ForegroundColor $(if ($pwTypeResults.Failed.Count -gt 0) { 'Yellow' } else { 'Green' })
            Save-Checkpoint
        }

        # Step 5c: Import Lists
        if ($script:State.ExportedLists -and $script:State.ExportedLists.Count -gt 0) {
            Write-Host "`nSTEP 5c: Import Lists (Dropdown Options)" -ForegroundColor Cyan
            Write-Host "-----------------------------------------`n"

            if (-not (Read-Confirmation "Create $($script:State.ExportedLists.Count) lists on target?")) {
                Write-Log "Lists import cancelled." -Level Warning
                return
            }

            $listResults = Import-Lists -BaseUrl $script:State.TargetUrl -Token $script:State.TargetToken -Lists $script:State.ExportedLists
            Write-Host "  Created: $($listResults.Success.Count), Existing: $($listResults.Skipped.Count), Failed: $($listResults.Failed.Count)" -ForegroundColor $(if ($listResults.Failed.Count -gt 0) { 'Yellow' } else { 'Green' })
            Save-Checkpoint
        }

        Write-Host "`nSTEP 5d: Import Folders (Structure)" -ForegroundColor Cyan
        Write-Host "-----------------------------------`n"

        Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Red
        Write-Host "║  WARNING: This will create folders on the target system!   ║" -ForegroundColor Red
        Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Red
        Write-Host ""

        if (-not (Read-Confirmation "Create $($script:State.ExportedFolders.Count) folders on target?")) {
            Write-Log "Folder import cancelled." -Level Warning
            return
        }

        $folderResults = Import-FoldersPass1 -TargetUrl $script:State.TargetUrl -TargetToken $script:State.TargetToken -Folders $script:State.ExportedFolders
        Save-Checkpoint

        Write-Host "`nSTEP 5e: Import Secret Policies" -ForegroundColor Cyan
        Write-Host "-------------------------------`n"

        if ($script:State.ExportedPolicies.Count -gt 0) {
            if (-not (Read-Confirmation "Create $($script:State.ExportedPolicies.Count) policies on target?")) {
                Write-Log "Policy import cancelled." -Level Warning
                return
            }

            $policyResults = Import-SecretPolicies -TargetUrl $script:State.TargetUrl -TargetToken $script:State.TargetToken -Policies $script:State.ExportedPolicies
            Save-Checkpoint
        }
        else {
            Write-Log "No policies to import" -Level Info
        }
    }

    Write-Host "`nSTEP 5$(if ($script:MigrationMode -eq 'Full') { 'c' } else { '' }): Import Secrets" -ForegroundColor Cyan
    Write-Host "----------------------`n"

    Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Red
    Write-Host "║  WARNING: This will create secrets on the target system!   ║" -ForegroundColor Red
    Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Red
    Write-Host ""

    if ($script:Config.DuplicateNamePolicy -eq "TrustTarget") {
        Write-Host "Mode: TRUST TARGET - All $($secrets.Count) secrets will be imported as-is" -ForegroundColor Cyan
        Write-Host "      Secret Server will handle any duplicate names per its configuration" -ForegroundColor Gray
    }
    else {
        if ($dryRunResults.Skipped.Count -gt 0) {
            Write-Host "Note: $($dryRunResults.Skipped.Count) secrets will be SKIPPED (duplicates)" -ForegroundColor Yellow
        }
        if ($dryRunResults.Renamed.Count -gt 0) {
            Write-Host "Note: $($dryRunResults.Renamed.Count) secrets will be RENAMED (duplicates)" -ForegroundColor Yellow
        }
    }
    Write-Host ""

    if (-not (Read-Confirmation "Proceed with import?")) {
        Write-Log "Import cancelled. Export file saved at: $($script:Config.ExportFile)" -Level Warning
        return
    }

    # Check token validity before long-running import (tokens typically expire in 1 hour)
    if (-not (Request-TokenRefresh -Phase "proceed with import")) {
        Write-Log "Import cancelled - authentication required" -Level Warning
        return
    }

    $importResults = Import-Secrets -BaseUrl $script:State.TargetUrl -Token $script:State.TargetToken -Secrets $secrets -ExistingNames $existingNames

    # Step 5d: Update folder policies (Full mode - Pass 2)
    if ($script:MigrationMode -eq "Full" -and $script:State.ExportedFolders.Count -gt 0) {
        Write-Host "`nSTEP 5f: Assign Policies to Folders" -ForegroundColor Cyan
        Write-Host "-----------------------------------`n"

        $foldersWithPolicies = $script:State.ExportedFolders | Where-Object {
            -not $_.inheritSecretPolicy -and $_.secretPolicyId -and $_.secretPolicyId -ne -1
        }

        if ($foldersWithPolicies.Count -gt 0) {
            Write-Log "Assigning policies to $($foldersWithPolicies.Count) folders..." -Level Info
            $policyUpdateResults = Update-FolderPolicies -TargetUrl $script:State.TargetUrl -TargetToken $script:State.TargetToken -SourceFolders $script:State.ExportedFolders
            Save-Checkpoint
        }
        else {
            Write-Log "No folder policy assignments needed" -Level Info
        }
    }

    # Step 5e: RPC/Privileged Account Linking (Pass 2 of two-pass secret migration)
    Write-Host "`nSTEP 5$(if ($script:MigrationMode -eq 'Full') { 'e' } else { 'b' }): Link Privileged Accounts (RPC)" -ForegroundColor Cyan
    Write-Host "-------------------------------------------`n"

    # Check for secrets with RPC configuration
    $secretsWithRpc = Get-SecretsWithRpc -Secrets $secrets
    if ($secretsWithRpc.Count -gt 0) {
        Write-Log "Found $($secretsWithRpc.Count) secrets with privileged account references" -Level Info

        # Check for circular references
        $cycles = Test-CircularRpcReferences -Secrets $secrets
        $circularIds = @()
        if ($cycles.Count -gt 0) {
            Write-Host ""
            Write-Host "WARNING: $($cycles.Count) circular RPC reference(s) detected!" -ForegroundColor Yellow
            Write-Host "These secrets will be created without RPC linking:" -ForegroundColor Yellow
            foreach ($cycle in $cycles) {
                $cycleNames = $cycle | ForEach-Object {
                    $id = $_
                    ($secrets | Where-Object { $_.id -eq $id }).name
                }
                Write-Host "  • $($cycleNames -join ' → ') → ..." -ForegroundColor Gray
                $circularIds += $cycle
            }
            Write-Host ""
        }

        if (-not (Read-Confirmation "Link $($secretsWithRpc.Count) secrets to their privileged accounts?")) {
            Write-Log "RPC linking skipped by user" -Level Warning
        }
        else {
            $rpcResults = Update-SecretRpcConfig -TargetUrl $script:State.TargetUrl -TargetToken $script:State.TargetToken `
                -SourceSecrets $secrets -CircularSecretIds $circularIds
            Save-Checkpoint
        }
    }
    else {
        Write-Log "No secrets have privileged account references - RPC linking not needed" -Level Info
    }

    # Step 6: Validate
    Write-Host "`nSTEP 6: Validation" -ForegroundColor Cyan
    Write-Host "------------------`n"

    $validation = Test-Migration -SourceUrl $script:State.SourceUrl -SourceToken $script:State.SourceToken -TargetUrl $script:State.TargetUrl -TargetToken $script:State.TargetToken

    # Final Summary
    Write-Host "`n═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "                    MIGRATION COMPLETE                          " -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════`n" -ForegroundColor Cyan

    Write-Host "Migration Mode: $script:MigrationMode" -ForegroundColor Cyan
    Write-Host ""

    # Full mode: Show folder/policy results
    if ($script:MigrationMode -eq "Full") {
        Write-Host "Folders:" -ForegroundColor Yellow
        Write-Host "  Created:     $($folderResults.Created)"
        Write-Host "  Skipped:     $($folderResults.Skipped) (existing)"
        Write-Host "  Failed:      $($folderResults.Failed)"
        Write-Host ""

        if ($policyResults) {
            Write-Host "Policies:" -ForegroundColor Yellow
            Write-Host "  Created:     $($policyResults.Created)"
            Write-Host "  Skipped:     $($policyResults.Skipped) (existing)"
            Write-Host "  Failed:      $($policyResults.Failed)"
            Write-Host ""
        }

        if ($policyUpdateResults) {
            Write-Host "Folder Policy Assignments:" -ForegroundColor Yellow
            Write-Host "  Updated:     $($policyUpdateResults.Updated)"
            Write-Host "  Skipped:     $($policyUpdateResults.Skipped)"
            Write-Host "  Failed:      $($policyUpdateResults.Failed)"
            Write-Host ""
        }
    }

    Write-Host "Secrets:" -ForegroundColor Yellow
    Write-Host "  Exported:    $($secrets.Count)"
    Write-Host "  Imported:    $($importResults.Success.Count)"

    # Show RPC linking results if applicable
    if ($rpcResults) {
        Write-Host ""
        Write-Host "RPC/Privileged Account Linking:" -ForegroundColor Yellow
        Write-Host "  Linked:      $($rpcResults.Updated)"
        Write-Host "  Skipped:     $($rpcResults.Skipped)"
        Write-Host "  Failed:      $($rpcResults.Failed)"
    }
    Write-Host "  Skipped:     $($importResults.Skipped.Count) (duplicates)"
    Write-Host "  Renamed:     $($importResults.Renamed.Count)"
    Write-Host "  Failed:      $($importResults.Failed.Count)"
    Write-Host "  Validated:   $($validation.SampleFound)/$($validation.SampleSize) spot checks passed"
    Write-Host ""
    Write-Host "Duplicate Policy: $($script:Config.DuplicateNamePolicy)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Files:" -ForegroundColor Yellow
    Write-Host "  Log:         $($script:Config.LogFile)"
    Write-Host "  Export:      $($script:Config.ExportFile)"
    Write-Host ""

    if ($importResults.Failed.Count -eq 0 -and $validation.CountMatch) {
        Write-Log "Migration completed successfully!" -Level Success
        Clear-Checkpoint
    }
    else {
        Write-Log "Migration completed with issues. Review log file for details." -Level Warning
    }

    Write-Host "REMINDER: Delete or secure the export file - it contains secrets in clear text." -ForegroundColor Red
}

function Start-ExportOnly {
    Write-Host "`n═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "                       EXPORT ONLY                              " -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════`n" -ForegroundColor Cyan

    Write-Host "SOURCE Secret Server:" -ForegroundColor Yellow
    $script:State.SourceUrl = Read-Prompt -Prompt "Source URL" -Required

    $urlCheck = Test-Url $script:State.SourceUrl
    if (-not $urlCheck.Valid) {
        Write-Log $urlCheck.Error -Level Error
        return
    }

    $sourceUser = Read-Prompt -Prompt "Username" -Required
    $sourcePass = Read-SecurePrompt -Prompt "Password: "

    try {
        $authResult = Get-SSToken -BaseUrl $script:State.SourceUrl -Username $sourceUser -Password $sourcePass
        $script:State.SourceToken = $authResult.Token
        $script:State.SourceTokenExpiry = $authResult.Expiry
        Write-Log "Authentication successful" -Level Success
    }
    catch {
        Write-Log "Authentication failed: $_" -Level Error
        return
    }

    $sourcePass = $null
    [GC]::Collect()

    $secrets = Export-Secrets -BaseUrl $script:State.SourceUrl -Token $script:State.SourceToken

    Write-Log "Export complete. File: $($script:Config.ExportFile)" -Level Success
}

function Start-ImportFromFile {
    Write-Host "`n═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "                    IMPORT FROM FILE                            " -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════`n" -ForegroundColor Cyan

    $exportFile = Read-Prompt -Prompt "Export file path" -Default $script:Config.ExportFile -Required

    if (-not (Test-Path $exportFile)) {
        Write-Log "File not found: $exportFile" -Level Error
        return
    }

    $export = Get-Content $exportFile | ConvertFrom-Json
    Write-Log "Loaded export from $($export.Metadata.ExportTimestamp)" -Level Info
    Write-Log "  Source: $($export.Metadata.SourceUrl)" -Level Info
    Write-Log "  Secrets: $($export.Metadata.SecretCount)" -Level Info

    Write-Host "`nTARGET Secret Server:" -ForegroundColor Yellow
    $script:State.TargetUrl = Read-Prompt -Prompt "Target URL" -Required

    $targetUser = Read-Prompt -Prompt "Username" -Required
    $targetPass = Read-SecurePrompt -Prompt "Password: "

    try {
        $authResult = Get-SSToken -BaseUrl $script:State.TargetUrl -Username $targetUser -Password $targetPass
        $script:State.TargetToken = $authResult.Token
        $script:State.TargetTokenExpiry = $authResult.Expiry
        Write-Log "Authentication successful" -Level Success
    }
    catch {
        Write-Log "Authentication failed: $_" -Level Error
        return
    }

    $targetPass = $null
    [GC]::Collect()

    # Dry run first
    Write-Log "Performing dry run..." -Level Info
    $dryRun = Import-Secrets -BaseUrl $script:State.TargetUrl -Token $script:State.TargetToken -Secrets $export.Secrets -DryRun

    if (-not (Read-Confirmation "`nProceed with actual import?")) {
        Write-Log "Import cancelled." -Level Warning
        return
    }

    $results = Import-Secrets -BaseUrl $script:State.TargetUrl -Token $script:State.TargetToken -Secrets $export.Secrets

    Write-Log "Import complete. $($results.Success.Count) succeeded, $($results.Failed.Count) failed." -Level $(if ($results.Failed.Count -eq 0) { 'Success' } else { 'Warning' })
}

function Start-ValidationOnly {
    Write-Host "`n═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "                    VALIDATE MIGRATION                          " -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════`n" -ForegroundColor Cyan

    Write-Host "SOURCE Secret Server:" -ForegroundColor Yellow
    $script:State.SourceUrl = Read-Prompt -Prompt "Source URL" -Required
    $sourceUser = Read-Prompt -Prompt "Username" -Required
    $sourcePass = Read-SecurePrompt -Prompt "Password: "

    Write-Host "`nTARGET Secret Server:" -ForegroundColor Yellow
    $script:State.TargetUrl = Read-Prompt -Prompt "Target URL" -Required
    $targetUser = Read-Prompt -Prompt "Username" -Required
    $targetPass = Read-SecurePrompt -Prompt "Password: "

    try {
        $sourceAuth = Get-SSToken -BaseUrl $script:State.SourceUrl -Username $sourceUser -Password $sourcePass
        $script:State.SourceToken = $sourceAuth.Token
        $script:State.SourceTokenExpiry = $sourceAuth.Expiry

        $targetAuth = Get-SSToken -BaseUrl $script:State.TargetUrl -Username $targetUser -Password $targetPass
        $script:State.TargetToken = $targetAuth.Token
        $script:State.TargetTokenExpiry = $targetAuth.Expiry
    }
    catch {
        Write-Log "Authentication failed: $_" -Level Error
        return
    }

    $sourcePass = $null
    $targetPass = $null
    [GC]::Collect()

    Test-Migration -SourceUrl $script:State.SourceUrl -SourceToken $script:State.SourceToken -TargetUrl $script:State.TargetUrl -TargetToken $script:State.TargetToken
}
#endregion

#region Entry Point

# Guard: Don't run entry point if script is being dot-sourced (for testing)
$isBeingSourced = $MyInvocation.InvocationName -eq '.' -or $MyInvocation.Line -match '^\s*\.\s+'
if ($isBeingSourced) {
    Write-Host "Script loaded for testing. Functions available." -ForegroundColor Gray
    return
}

if ($Help) {
    Show-Banner
    Show-Help
    exit 0
}

try {
    Start-MigrationWizard
}
catch {
    Write-Log "Unexpected error: $_" -Level Error
    Write-Log $_.ScriptStackTrace -Level Debug
    Save-Checkpoint
    exit 1
}
finally {
    # Clear sensitive data
    $script:State.SourceToken = $null
    $script:State.TargetToken = $null
    [GC]::Collect()
}
#endregion
