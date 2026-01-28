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
    Version: 2.1
    Author: Delinea WW Architecture Team
    Requires: PowerShell 7+, TLS 1.2/1.3
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
    Version = "2.2.3"
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
    ImportedSecrets = @()
    FailedSecrets = @()
    CurrentPhase = "Init"
    LastBatchIndex = 0
}

# Force TLS 1.2+
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
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

        return $response.access_token
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
#endregion

#region Checkpoint Management
function Save-Checkpoint {
    $checkpoint = @{
        Timestamp = Get-Date -Format "o"
        Phase = $script:State.CurrentPhase
        SourceUrl = $script:State.SourceUrl
        TargetUrl = $script:State.TargetUrl
        ExportFile = $script:Config.ExportFile
        LastBatchIndex = $script:State.LastBatchIndex
        ImportedCount = $script:State.ImportedSecrets.Count
        FailedCount = $script:State.FailedSecrets.Count
        ImportedIds = $script:State.ImportedSecrets | Select-Object -ExpandProperty TargetId -ErrorAction SilentlyContinue
    }

    $checkpoint | ConvertTo-Json -Depth 10 | Out-File $script:Config.CheckpointFile -Encoding UTF8
    Write-Log "Checkpoint saved" -Level Debug
}

function Restore-Checkpoint {
    if (-not (Test-Path $script:Config.CheckpointFile)) {
        return $false
    }

    try {
        $checkpoint = Get-Content $script:Config.CheckpointFile | ConvertFrom-Json

        Write-Log "Found checkpoint from $($checkpoint.Timestamp)" -Level Info
        Write-Log "  Phase: $($checkpoint.Phase)" -Level Info
        Write-Log "  Source: $($checkpoint.SourceUrl)" -Level Info
        Write-Log "  Target: $($checkpoint.TargetUrl)" -Level Info
        Write-Log "  Progress: $($checkpoint.ImportedCount) imported, $($checkpoint.FailedCount) failed" -Level Info

        if (Read-Confirmation "Resume from this checkpoint?") {
            $script:State.SourceUrl = $checkpoint.SourceUrl
            $script:State.TargetUrl = $checkpoint.TargetUrl
            $script:State.CurrentPhase = $checkpoint.Phase
            $script:State.LastBatchIndex = $checkpoint.LastBatchIndex
            $script:Config.ExportFile = $checkpoint.ExportFile
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

#region Validation Functions
function Test-Url {
    param([string]$Url)

    if (-not $Url.StartsWith("https://")) {
        return @{ Valid = $false; Error = "URL must start with https://" }
    }

    try {
        $uri = [System.Uri]::new($Url)
        if (-not $uri.Host) {
            return @{ Valid = $false; Error = "Invalid hostname" }
        }
        return @{ Valid = $true }
    }
    catch {
        return @{ Valid = $false; Error = "Invalid URL format" }
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

                $script:State.ImportedSecrets += $results.Success[-1]
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

            $script:State.FailedSecrets += $results.Failed[-1]
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
    $script:State.SourceUrl = Read-Prompt -Prompt "Source URL (e.g., https://company.secretservercloud.com)" -Required

    $urlCheck = Test-Url $script:State.SourceUrl
    if (-not $urlCheck.Valid) {
        Write-Log $urlCheck.Error -Level Error
        return
    }

    $sourceUser = Read-Prompt -Prompt "Source username" -Required
    $sourcePass = Read-SecurePrompt -Prompt "Source password: "

    # Target
    Write-Host "`nTARGET Secret Server (where secrets will go):" -ForegroundColor Yellow
    $script:State.TargetUrl = Read-Prompt -Prompt "Target URL" -Required

    $urlCheck = Test-Url $script:State.TargetUrl
    if (-not $urlCheck.Valid) {
        Write-Log $urlCheck.Error -Level Error
        return
    }

    $targetUser = Read-Prompt -Prompt "Target username" -Required
    $targetPass = Read-SecurePrompt -Prompt "Target password: "

    # Step 2: Pre-flight checks
    Write-Host "`nSTEP 2: Pre-flight Checks" -ForegroundColor Cyan
    Write-Host "-------------------------`n"

    Write-Log "Authenticating to source..." -Level Info
    try {
        $script:State.SourceToken = Get-SSToken -BaseUrl $script:State.SourceUrl -Username $sourceUser -Password $sourcePass
        Write-Log "Source authentication successful" -Level Success
    }
    catch {
        Write-Log "Source authentication failed: $_" -Level Error
        return
    }

    Write-Log "Authenticating to target..." -Level Info
    try {
        $script:State.TargetToken = Get-SSToken -BaseUrl $script:State.TargetUrl -Username $targetUser -Password $targetPass
        Write-Log "Target authentication successful" -Level Success
    }
    catch {
        Write-Log "Target authentication failed: $_" -Level Error
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
        Write-Log "Insufficient source permissions. Cannot proceed." -Level Error
        return
    }

    Write-Log "Checking target permissions..." -Level Info
    $targetPerms = Test-Permissions -BaseUrl $script:State.TargetUrl -Token $script:State.TargetToken -Role Target
    Write-Log "  Can create secrets: $($targetPerms.CanCreateSecrets)" -Level $(if ($targetPerms.CanCreateSecrets) { 'Success' } else { 'Error' })
    Write-Log "  Existing secrets: $($targetPerms.SecretCount)" -Level Info

    if (-not $targetPerms.CanCreateSecrets) {
        Write-Log "Insufficient target permissions. Cannot proceed." -Level Error
        return
    }

    Write-Log "Pre-flight checks passed!" -Level Success

    # Step 2b: Duplicate Name Policy
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
        1 { "TrustTarget" }
        2 { "Fail" }
        3 { "Skip" }
        4 { "Rename" }
    }

    Write-Log "Duplicate policy set to: $($script:Config.DuplicateNamePolicy)" -Level Info

    # Step 3: Export
    Write-Host "`nSTEP 3: Export Secrets" -ForegroundColor Cyan
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
                    2 {
                        $script:Config.DuplicateNamePolicy = "Skip"
                        Write-Log "Policy changed to: Skip" -Level Info
                    }
                    3 {
                        $script:Config.DuplicateNamePolicy = "Rename"
                        Write-Log "Policy changed to: Rename" -Level Info
                    }
                    4 {
                        $script:Config.DuplicateNamePolicy = "TrustTarget"
                        Write-Log "Policy changed to: TrustTarget" -Level Info
                    }
                    5 {
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
    Write-Host "`nSTEP 5: Import Secrets" -ForegroundColor Cyan
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

    $importResults = Import-Secrets -BaseUrl $script:State.TargetUrl -Token $script:State.TargetToken -Secrets $secrets -ExistingNames $existingNames

    # Step 6: Validate
    Write-Host "`nSTEP 6: Validation" -ForegroundColor Cyan
    Write-Host "------------------`n"

    $validation = Test-Migration -SourceUrl $script:State.SourceUrl -SourceToken $script:State.SourceToken -TargetUrl $script:State.TargetUrl -TargetToken $script:State.TargetToken

    # Final Summary
    Write-Host "`n═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "                    MIGRATION COMPLETE                          " -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════`n" -ForegroundColor Cyan

    Write-Host "Results:" -ForegroundColor Yellow
    Write-Host "  Exported:    $($secrets.Count)"
    Write-Host "  Imported:    $($importResults.Success.Count)"
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
        $script:State.SourceToken = Get-SSToken -BaseUrl $script:State.SourceUrl -Username $sourceUser -Password $sourcePass
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
        $script:State.TargetToken = Get-SSToken -BaseUrl $script:State.TargetUrl -Username $targetUser -Password $targetPass
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
        $script:State.SourceToken = Get-SSToken -BaseUrl $script:State.SourceUrl -Username $sourceUser -Password $sourcePass
        $script:State.TargetToken = Get-SSToken -BaseUrl $script:State.TargetUrl -Username $targetUser -Password $targetPass
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
