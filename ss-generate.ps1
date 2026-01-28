#!/usr/bin/env pwsh
#Requires -Version 7.0

<#
.SYNOPSIS
    Secret Server Test Data Generator

.DESCRIPTION
    Interactive wizard for generating test secrets in a Secret Server tenant.
    Useful for testing migrations at scale.

.PARAMETER Help
    Show this help message

.PARAMETER Count
    Number of secrets to generate (can also be set interactively)

.EXAMPLE
    pwsh ./ss-generate.ps1

.EXAMPLE
    pwsh ./ss-generate.ps1 -Count 1000

.NOTES
    Version: 1.0.0
    Author: Delinea WW Architecture Team
    Companion tool to ss-migrate.ps1
#>

param(
    [switch]$Help,
    [int]$Count = 0
)

# ============================================================================
# Configuration
# ============================================================================

$script:Config = @{
    Version = "1.0.0"
    BatchSize = 50
    ThrottleDelayMs = 100
    ConnectionTimeoutSec = 30
    MaxRetries = 3
    MaxRateLimitRetries = 10
    RetryDelayMs = 2000
    DefaultCount = 500
    NamingPatterns = @(
        "Server-{0:D5}"
        "DB-{0:D5}"
        "App-{0:D5}"
        "Service-{0:D5}"
        "Admin-{0:D5}"
    )
    Domains = @("corp.local", "dev.internal", "prod.acme.com", "test.lab", "staging.net")
    Machines = @("srv", "db", "app", "web", "api", "batch", "worker", "node")
}

$script:State = @{
    Url = $null
    Token = $null
    TokenExpiry = $null
    Templates = @()
    Folders = @()
}

$script:PhaseStartTime = $null

# ============================================================================
# UI Helpers
# ============================================================================

function Show-Banner {
    $version = $script:Config.Version
    Write-Host ""
    Write-Host "  ╔═══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║   SECRET SERVER TEST DATA GENERATOR                           ║" -ForegroundColor Cyan
    Write-Host "  ║   Version $version                                               ║" -ForegroundColor Cyan
    Write-Host "  ╚═══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
}

function Write-Status {
    param(
        [string]$Message,
        [ValidateSet("Info", "Success", "Warning", "Error")]
        [string]$Level = "Info"
    )

    $prefix = switch ($Level) {
        "Success" { "[SUCCESS]"; }
        "Warning" { "[WARNING]"; }
        "Error"   { "[ERROR]"; }
        default   { "[INFO]"; }
    }

    $color = switch ($Level) {
        "Success" { "Green" }
        "Warning" { "Yellow" }
        "Error"   { "Red" }
        default   { "White" }
    }

    Write-Host "$prefix " -ForegroundColor $color -NoNewline
    Write-Host $Message
}

function Show-Progress {
    param(
        [string]$Activity,
        [int]$Current,
        [int]$Total,
        [string]$Status = ""
    )

    if ($Total -le 0) {
        Write-Host "`r  ${Activity}: $Current items processed    " -NoNewline
        return
    }

    $percent = [math]::Round(($Current / $Total) * 100)
    $barLength = 24
    $filled = [math]::Floor($barLength * $Current / $Total)
    $empty = $barLength - $filled
    $bar = ("█" * $filled) + ("░" * $empty)

    # Calculate ETA
    $eta = ""
    if ($script:PhaseStartTime -and $Current -gt 0) {
        $elapsed = (Get-Date) - $script:PhaseStartTime
        $itemsPerSecond = $Current / $elapsed.TotalSeconds
        if ($itemsPerSecond -gt 0) {
            $remaining = ($Total - $Current) / $itemsPerSecond
            if ($remaining -gt 3600) {
                $eta = " ETA: {0:N1}h" -f ($remaining / 3600)
            } elseif ($remaining -gt 60) {
                $eta = " ETA: {0:N0}m" -f ($remaining / 60)
            } elseif ($remaining -gt 0) {
                $eta = " ETA: <1m"
            }
        }
    }

    if ($Current -eq $Total -and $script:PhaseStartTime) {
        $elapsed = (Get-Date) - $script:PhaseStartTime
        if ($elapsed.TotalHours -ge 1) {
            $eta = " Completed in {0:N0}h {1:N0}m" -f [math]::Floor($elapsed.TotalHours), ($elapsed.Minutes)
        } elseif ($elapsed.TotalMinutes -ge 1) {
            $eta = " Completed in {0:N0}m {1:N0}s" -f [math]::Floor($elapsed.TotalMinutes), ($elapsed.Seconds)
        } else {
            $eta = " Completed in {0:N0}s" -f $elapsed.TotalSeconds
        }
    }

    Write-Host "`r  [$bar] $percent% ($Current/$Total)$eta    " -NoNewline

    if ($Current -eq $Total) {
        Write-Host ""
    }
}

function Read-SecurePrompt {
    param([string]$Prompt)

    Write-Host "$Prompt" -NoNewline
    $secure = Read-Host -AsSecureString
    return $secure
}

function Read-Prompt {
    param(
        [string]$Prompt,
        [string]$Default = ""
    )

    if ($Default) {
        Write-Host "$Prompt [$Default]: " -NoNewline
    } else {
        Write-Host "${Prompt}: " -NoNewline
    }

    $input = Read-Host
    if ([string]::IsNullOrWhiteSpace($input) -and $Default) {
        return $Default
    }
    return $input
}

function Read-Confirmation {
    param(
        [string]$Prompt,
        [bool]$DefaultYes = $false
    )

    $hint = if ($DefaultYes) { "[Y/n]" } else { "[y/N]" }
    Write-Host "$Prompt $hint" -NoNewline -ForegroundColor Yellow
    Write-Host ": " -NoNewline

    $response = Read-Host
    if ([string]::IsNullOrWhiteSpace($response)) {
        return $DefaultYes
    }
    return $response -match "^[Yy]"
}

# ============================================================================
# API Functions
# ============================================================================

function Invoke-SSApi {
    param(
        [string]$Endpoint,
        [string]$Method = "GET",
        [object]$Body = $null,
        [int]$Retry = 0
    )

    $url = "$($script:State.Url)/api/v1$Endpoint"

    $headers = @{
        "Authorization" = "Bearer $($script:State.Token)"
        "Content-Type" = "application/json"
    }

    $params = @{
        Uri = $url
        Method = $Method
        Headers = $headers
        TimeoutSec = $script:Config.ConnectionTimeoutSec
    }

    if ($Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 10)
    }

    try {
        $response = Invoke-RestMethod @params
        return $response
    }
    catch {
        $errorMsg = $_.Exception.Message

        $statusCode = $null
        if ($_.Exception.Response) {
            try {
                $statusCode = [int]$_.Exception.Response.StatusCode
            } catch { }
        }

        # Handle rate limiting (429)
        if ($statusCode -eq 429) {
            if ($Retry -ge $script:Config.MaxRateLimitRetries) {
                throw "Rate limit exceeded after $($script:Config.MaxRateLimitRetries) retries on $Endpoint"
            }

            $retryAfter = 60
            try {
                $retryHeader = $_.Exception.Response.Headers | Where-Object { $_.Key -eq "Retry-After" }
                if ($retryHeader) {
                    $retryAfter = [int]$retryHeader.Value[0]
                }
            } catch { }

            $retryAfter = [math]::Min($retryAfter, 300)
            Write-Status "Rate limited. Waiting $retryAfter seconds..." -Level Warning
            Start-Sleep -Seconds $retryAfter
            return Invoke-SSApi -Endpoint $Endpoint -Method $Method -Body $Body -Retry ($Retry + 1)
        }

        # Retry on transient errors
        if ($Retry -lt $script:Config.MaxRetries) {
            $delay = $script:Config.RetryDelayMs * [math]::Pow(2, $Retry)
            Start-Sleep -Milliseconds $delay
            return Invoke-SSApi -Endpoint $Endpoint -Method $Method -Body $Body -Retry ($Retry + 1)
        }

        throw "API Error on $Endpoint : $errorMsg"
    }
}

function Get-AuthToken {
    param(
        [string]$Url,
        [string]$Username,
        [SecureString]$Password
    )

    $tokenUrl = "$Url/oauth2/token"

    $credential = New-Object System.Management.Automation.PSCredential($Username, $Password)
    $plainPassword = $credential.GetNetworkCredential().Password

    $body = @{
        grant_type = "password"
        username = $Username
        password = $plainPassword
    }

    try {
        $response = Invoke-RestMethod -Uri $tokenUrl -Method Post -Body $body -ContentType "application/x-www-form-urlencoded" -TimeoutSec $script:Config.ConnectionTimeoutSec

        $script:State.Token = $response.access_token
        $script:State.TokenExpiry = (Get-Date).AddSeconds($response.expires_in - 60)

        return $true
    }
    catch {
        Write-Status "Authentication failed: $($_.Exception.Message)" -Level Error
        return $false
    }
    finally {
        # Clear sensitive data
        if ($body) { $body.password = $null }
        $plainPassword = $null
    }
}

# ============================================================================
# Discovery Functions
# ============================================================================

function Get-Templates {
    Write-Host "  Fetching secret templates..." -NoNewline

    try {
        $response = Invoke-SSApi -Endpoint "/secret-templates"
        $script:State.Templates = $response.records | Where-Object { $_.active -eq $true }
        Write-Host " Found $($script:State.Templates.Count) templates" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host ""
        Write-Status "Failed to fetch templates: $($_.Exception.Message)" -Level Error
        return $false
    }
}

function Get-Folders {
    Write-Host "  Fetching folders..." -NoNewline

    try {
        $response = Invoke-SSApi -Endpoint "/folders?take=1000"
        $script:State.Folders = $response.records
        Write-Host " Found $($script:State.Folders.Count) folders" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host ""
        Write-Status "Failed to fetch folders: $($_.Exception.Message)" -Level Error
        return $false
    }
}

function Get-SecretStub {
    param([int]$TemplateId)

    return Invoke-SSApi -Endpoint "/secrets/stub?secrettemplateid=$TemplateId"
}

# ============================================================================
# Generation Functions
# ============================================================================

function New-RandomPassword {
    param([int]$Length = 16)

    $chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*"
    $password = -join ((1..$Length) | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })
    return $password
}

function New-RandomUsername {
    $prefixes = @("svc", "app", "admin", "batch", "api", "sys", "db", "web")
    $suffix = Get-Random -Minimum 100 -Maximum 9999
    return "$($prefixes | Get-Random)_$suffix"
}

function New-SecretData {
    param(
        [int]$Index,
        [string]$NamingPattern,
        [object]$Stub,
        [int]$FolderId,
        [int]$TemplateId
    )

    # Clone the stub
    $secret = $Stub | ConvertTo-Json -Depth 10 | ConvertFrom-Json

    # Set basic properties
    $secret.name = $NamingPattern -f $Index
    $secret.secretTemplateId = $TemplateId
    $secret.folderId = $FolderId
    $secret.siteId = 1

    # Set field values based on common field names
    foreach ($item in $secret.items) {
        $fieldName = $item.fieldName.ToLower()

        switch -Wildcard ($fieldName) {
            "*password*" { $item.itemValue = New-RandomPassword }
            "*username*" { $item.itemValue = New-RandomUsername }
            "*user*" { $item.itemValue = New-RandomUsername }
            "*domain*" { $item.itemValue = $script:Config.Domains | Get-Random }
            "*machine*" { $item.itemValue = "$($script:Config.Machines | Get-Random)$(Get-Random -Minimum 1 -Maximum 999)" }
            "*server*" { $item.itemValue = "$($script:Config.Machines | Get-Random)$(Get-Random -Minimum 1 -Maximum 999)" }
            "*host*" { $item.itemValue = "$($script:Config.Machines | Get-Random)$(Get-Random -Minimum 1 -Maximum 999).local" }
            "*url*" { $item.itemValue = "https://$($script:Config.Machines | Get-Random)$(Get-Random -Minimum 1 -Maximum 999).example.com" }
            "*notes*" { $item.itemValue = "Generated test secret #$Index on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" }
            "*description*" { $item.itemValue = "Test secret for migration testing" }
        }
    }

    return $secret
}

function New-Secrets {
    param(
        [int]$Count,
        [int]$TemplateId,
        [int]$FolderId,
        [string]$NamingPattern
    )

    $script:PhaseStartTime = Get-Date

    # Get a stub to use as template
    Write-Host "  Fetching secret template stub..."
    $stub = Get-SecretStub -TemplateId $TemplateId

    $results = @{
        Success = [System.Collections.ArrayList]::new()
        Failed = [System.Collections.ArrayList]::new()
    }

    Write-Host ""

    for ($i = 1; $i -le $Count; $i++) {
        Show-Progress -Activity "Creating secrets" -Current $i -Total $Count

        try {
            $secretData = New-SecretData -Index $i -NamingPattern $NamingPattern -Stub $stub -FolderId $FolderId -TemplateId $TemplateId

            $created = Invoke-SSApi -Endpoint "/secrets" -Method POST -Body $secretData

            [void]$results.Success.Add(@{
                id = $created.id
                name = $secretData.name
            })
        }
        catch {
            [void]$results.Failed.Add(@{
                index = $i
                name = $NamingPattern -f $i
                error = $_.Exception.Message
            })
        }

        # Throttle
        if ($i % $script:Config.BatchSize -eq 0) {
            Start-Sleep -Milliseconds $script:Config.ThrottleDelayMs
        }
    }

    Write-Host ""
    return $results
}

# ============================================================================
# Wizard Functions
# ============================================================================

function Show-TemplateMenu {
    Write-Host ""
    Write-Host "Available Secret Templates:" -ForegroundColor Cyan
    Write-Host "─────────────────────────────────────────"

    $index = 1
    $templateMap = @{}

    foreach ($template in $script:State.Templates | Sort-Object name | Select-Object -First 20) {
        $templateMap[$index] = $template
        Write-Host "  [$index] $($template.name)" -ForegroundColor White
        $index++
    }

    if ($script:State.Templates.Count -gt 20) {
        Write-Host "  ... and $($script:State.Templates.Count - 20) more" -ForegroundColor DarkGray
    }

    Write-Host ""
    $selection = Read-Prompt -Prompt "Select template (1-$($templateMap.Count))"

    $selectedIndex = [int]$selection
    if ($templateMap.ContainsKey($selectedIndex)) {
        return $templateMap[$selectedIndex]
    }

    Write-Status "Invalid selection" -Level Error
    return $null
}

function Show-FolderMenu {
    Write-Host ""
    Write-Host "Available Folders:" -ForegroundColor Cyan
    Write-Host "─────────────────────────────────────────"

    $index = 1
    $folderMap = @{}

    # Show root folders and their immediate children
    $rootFolders = $script:State.Folders | Where-Object { $_.parentFolderId -eq -1 -or $null -eq $_.parentFolderId }

    foreach ($folder in $rootFolders | Sort-Object folderName | Select-Object -First 15) {
        $folderMap[$index] = $folder
        Write-Host "  [$index] $($folder.folderPath)" -ForegroundColor White
        $index++

        # Show immediate children
        $children = $script:State.Folders | Where-Object { $_.parentFolderId -eq $folder.id } | Select-Object -First 3
        foreach ($child in $children) {
            $folderMap[$index] = $child
            Write-Host "  [$index]   └─ $($child.folderName)" -ForegroundColor Gray
            $index++
        }
    }

    Write-Host ""
    $selection = Read-Prompt -Prompt "Select folder (1-$($folderMap.Count))"

    $selectedIndex = [int]$selection
    if ($folderMap.ContainsKey($selectedIndex)) {
        return $folderMap[$selectedIndex]
    }

    Write-Status "Invalid selection" -Level Error
    return $null
}

function Show-NamingPatternMenu {
    Write-Host ""
    Write-Host "Naming Pattern Options:" -ForegroundColor Cyan
    Write-Host "─────────────────────────────────────────"
    Write-Host "  [1] Server-00001, Server-00002, ..." -ForegroundColor White
    Write-Host "  [2] DB-00001, DB-00002, ..." -ForegroundColor White
    Write-Host "  [3] App-00001, App-00002, ..." -ForegroundColor White
    Write-Host "  [4] TestSecret-00001, TestSecret-00002, ..." -ForegroundColor White
    Write-Host "  [5] Custom pattern" -ForegroundColor White
    Write-Host ""

    $selection = Read-Prompt -Prompt "Select pattern (1-5)" -Default "1"

    switch ($selection) {
        "1" { return "Server-{0:D5}" }
        "2" { return "DB-{0:D5}" }
        "3" { return "App-{0:D5}" }
        "4" { return "TestSecret-{0:D5}" }
        "5" {
            Write-Host ""
            Write-Host "  Enter custom pattern using {0} for the number." -ForegroundColor DarkGray
            Write-Host "  Example: MySecret-{0:D5} produces MySecret-00001" -ForegroundColor DarkGray
            $custom = Read-Prompt -Prompt "Custom pattern"
            if ($custom -notmatch "\{0") {
                $custom = "$custom-{0:D5}"
            }
            return $custom
        }
        default { return "Server-{0:D5}" }
    }
}

function Start-Wizard {
    Show-Banner

    Write-Host "This tool generates test secrets in a Secret Server tenant."
    Write-Host "Useful for testing migrations at scale."
    Write-Host ""

    # ─────────────────────────────────────────────────────────────────────────
    # Step 1: Connection
    # ─────────────────────────────────────────────────────────────────────────

    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "                    STEP 1: CONNECTION" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""

    $url = Read-Prompt -Prompt "Secret Server URL (e.g., https://company.secretservercloud.com)"
    $url = $url.TrimEnd('/')
    $script:State.Url = $url

    $username = Read-Prompt -Prompt "Username"
    $password = Read-SecurePrompt -Prompt "Password: "

    Write-Host ""
    Write-Host "Authenticating..." -NoNewline

    if (-not (Get-AuthToken -Url $url -Username $username -Password $password)) {
        return
    }

    Write-Host " " -NoNewline
    Write-Status "Connected" -Level Success

    # ─────────────────────────────────────────────────────────────────────────
    # Step 2: Discovery
    # ─────────────────────────────────────────────────────────────────────────

    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "                    STEP 2: DISCOVERY" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""

    if (-not (Get-Templates)) { return }
    if (-not (Get-Folders)) { return }

    # ─────────────────────────────────────────────────────────────────────────
    # Step 3: Configuration
    # ─────────────────────────────────────────────────────────────────────────

    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "                    STEP 3: CONFIGURATION" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan

    # Select template
    $template = Show-TemplateMenu
    if (-not $template) { return }
    Write-Status "Selected template: $($template.name)" -Level Success

    # Select folder
    $folder = Show-FolderMenu
    if (-not $folder) { return }
    Write-Status "Selected folder: $($folder.folderPath)" -Level Success

    # Select naming pattern
    $namingPattern = Show-NamingPatternMenu
    Write-Status "Naming pattern: $($namingPattern -f 1)" -Level Success

    # Get count
    Write-Host ""
    $countStr = Read-Prompt -Prompt "Number of secrets to generate" -Default "$($script:Config.DefaultCount)"
    $secretCount = [int]$countStr

    if ($secretCount -le 0) {
        Write-Status "Invalid count" -Level Error
        return
    }

    # ─────────────────────────────────────────────────────────────────────────
    # Step 4: Confirmation
    # ─────────────────────────────────────────────────────────────────────────

    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "                    STEP 4: CONFIRMATION" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""

    Write-Host "  Server:    $url" -ForegroundColor White
    Write-Host "  Template:  $($template.name)" -ForegroundColor White
    Write-Host "  Folder:    $($folder.folderPath)" -ForegroundColor White
    Write-Host "  Pattern:   $namingPattern" -ForegroundColor White
    Write-Host "  Count:     $secretCount secrets" -ForegroundColor White
    Write-Host ""

    Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Yellow
    Write-Host "║  This will CREATE $secretCount secrets on the target!            ║" -ForegroundColor Yellow
    Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Yellow
    Write-Host ""

    if (-not (Read-Confirmation -Prompt "Proceed with generation?")) {
        Write-Status "Cancelled by user" -Level Warning
        return
    }

    # ─────────────────────────────────────────────────────────────────────────
    # Step 5: Generation
    # ─────────────────────────────────────────────────────────────────────────

    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "                    STEP 5: GENERATION" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""

    $results = New-Secrets -Count $secretCount -TemplateId $template.id -FolderId $folder.id -NamingPattern $namingPattern

    # ─────────────────────────────────────────────────────────────────────────
    # Results
    # ─────────────────────────────────────────────────────────────────────────

    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "                    GENERATION COMPLETE" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""

    Write-Host "Results:" -ForegroundColor White
    Write-Host "  Created:  $($results.Success.Count)" -ForegroundColor Green
    Write-Host "  Failed:   $($results.Failed.Count)" -ForegroundColor $(if ($results.Failed.Count -gt 0) { "Red" } else { "Green" })
    Write-Host ""

    if ($results.Failed.Count -gt 0) {
        Write-Host "Failed secrets:" -ForegroundColor Red
        foreach ($failure in $results.Failed | Select-Object -First 10) {
            Write-Host "  - $($failure.name): $($failure.error)" -ForegroundColor Red
        }
        if ($results.Failed.Count -gt 10) {
            Write-Host "  ... and $($results.Failed.Count - 10) more" -ForegroundColor DarkGray
        }
        Write-Host ""
    }

    if ($results.Success.Count -gt 0) {
        Write-Status "Generated $($results.Success.Count) test secrets successfully!" -Level Success
    }
}

# ============================================================================
# Main
# ============================================================================

if ($Help) {
    Get-Help $MyInvocation.MyCommand.Path -Detailed
    exit 0
}

# Override default count if provided via parameter
if ($Count -gt 0) {
    $script:Config.DefaultCount = $Count
}

try {
    Start-Wizard
}
catch {
    Write-Host ""
    Write-Status "Unexpected error: $($_.Exception.Message)" -Level Error
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    exit 1
}
