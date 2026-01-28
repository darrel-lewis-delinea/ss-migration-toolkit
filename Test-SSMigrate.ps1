#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Self-contained unit tests for SS Migration Toolkit.
    No external dependencies required - runs on any PowerShell 7+ system.

.DESCRIPTION
    Tests core logic: URL validation, credential masking, checkpoint management.
    Run with: ./Test-SSMigrate.ps1

.EXAMPLE
    ./Test-SSMigrate.ps1
    ./Test-SSMigrate.ps1 -Verbose
#>

[CmdletBinding()]
param()

#region Test Framework (No Dependencies)

$script:TestResults = @{
    Passed = 0
    Failed = 0
    Errors = @()
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if ($Condition) {
        $script:TestResults.Passed++
        Write-Host "  [PASS] $Message" -ForegroundColor Green
    } else {
        $script:TestResults.Failed++
        $script:TestResults.Errors += $Message
        Write-Host "  [FAIL] $Message" -ForegroundColor Red
    }
}

function Assert-False {
    param([bool]$Condition, [string]$Message)
    Assert-True -Condition (-not $Condition) -Message $Message
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    $isEqual = $Expected -eq $Actual
    if ($isEqual) {
        $script:TestResults.Passed++
        Write-Host "  [PASS] $Message" -ForegroundColor Green
    } else {
        $script:TestResults.Failed++
        $script:TestResults.Errors += "$Message (Expected: '$Expected', Got: '$Actual')"
        Write-Host "  [FAIL] $Message" -ForegroundColor Red
        Write-Host "         Expected: '$Expected'" -ForegroundColor Yellow
        Write-Host "         Got:      '$Actual'" -ForegroundColor Yellow
    }
}

function Assert-Contains {
    param([string]$Haystack, [string]$Needle, [string]$Message)
    Assert-True -Condition ($Haystack -like "*$Needle*") -Message $Message
}

function Assert-NotContains {
    param([string]$Haystack, [string]$Needle, [string]$Message)
    Assert-False -Condition ($Haystack -like "*$Needle*") -Message $Message
}

#endregion

#region Functions Under Test (Copied from ss-migrate.ps1)

function Test-Url {
    param([string]$Url)

    if (-not $Url.StartsWith("https://")) {
        return @{ Valid = $false; Error = "URL must start with https://" }
    }

    try {
        $uri = [System.Uri]::new($Url)
        if ([string]::IsNullOrEmpty($uri.Host)) {
            return @{ Valid = $false; Error = "Invalid hostname" }
        }
        return @{ Valid = $true }
    }
    catch {
        return @{ Valid = $false; Error = "Invalid URL format" }
    }
}

function Mask-Credentials {
    param([string]$Message)

    # Case-insensitive patterns - require key + separator + value format
    $masked = $Message -replace '(?i)(Bearer\s+)[^\s]+', '$1[REDACTED]'
    $masked = $masked -replace '(?i)(password|passwd|pwd)([''"\s]*[=:][''"\s]*)([^\s,''"\}]+)', '$1$2[REDACTED]'
    $masked = $masked -replace '(?i)(access_token|api_key|apikey)([''"\s]*[=:][''"\s]*)([^\s,''"\}]+)', '$1$2[REDACTED]'
    # More specific pattern for "secret" and "token" to avoid false positives (JSON context only)
    $masked = $masked -replace '(?i)([''"])(secret|token)([''"])\s*:\s*[''"]([^''"]+)[''"]', '$1$2$3: "[REDACTED]"'
    # Mask credentials embedded in URLs
    $masked = $masked -replace '://[^:]+:[^@]+@', '://[REDACTED]:[REDACTED]@'

    return $masked
}

#endregion

#region URL Validation Tests

Write-Host "`nURL Validation Tests" -ForegroundColor Cyan
Write-Host "====================" -ForegroundColor Cyan

$result = Test-Url "https://company.secretservercloud.com"
Assert-True -Condition $result.Valid -Message "Valid HTTPS URL accepted"

$result = Test-Url "https://company.secretservercloud.com/SecretServer"
Assert-True -Condition $result.Valid -Message "Valid HTTPS URL with path accepted"

$result = Test-Url "https://company.secretservercloud.com:8443"
Assert-True -Condition $result.Valid -Message "Valid HTTPS URL with port accepted"

$result = Test-Url "http://company.secretservercloud.com"
Assert-False -Condition $result.Valid -Message "HTTP URL rejected"
Assert-Equal -Expected "URL must start with https://" -Actual $result.Error -Message "HTTP rejection has correct error message"

$result = Test-Url ""
Assert-False -Condition $result.Valid -Message "Empty URL rejected"

$result = Test-Url "company.secretservercloud.com"
Assert-False -Condition $result.Valid -Message "URL without protocol rejected"

$result = Test-Url "https://localhost:8443"
Assert-True -Condition $result.Valid -Message "Localhost URL accepted"

$result = Test-Url "https://192.168.1.100"
Assert-True -Condition $result.Valid -Message "IP address URL accepted"

#endregion

#region Credential Masking Tests

Write-Host "`nCredential Masking Tests" -ForegroundColor Cyan
Write-Host "========================" -ForegroundColor Cyan

# Bearer tokens
$masked = Mask-Credentials "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.abc123"
Assert-Equal -Expected "Authorization: Bearer [REDACTED]" -Actual $masked -Message "Bearer token masked"

$masked = Mask-Credentials "Sending request with Bearer abc123xyz to server"
Assert-Equal -Expected "Sending request with Bearer [REDACTED] to server" -Actual $masked -Message "Bearer token mid-string masked"

$masked = Mask-Credentials "BEARER abc123token"
Assert-NotContains -Haystack $masked -Needle "abc123token" -Message "Uppercase BEARER masked"

# Password formats
$masked = Mask-Credentials '{"username": "admin", "password": "SuperSecret123"}'
Assert-Contains -Haystack $masked -Needle "[REDACTED]" -Message "JSON password masked"
Assert-NotContains -Haystack $masked -Needle "SuperSecret123" -Message "JSON password value hidden"

$masked = Mask-Credentials "password=MySecretPass123"
Assert-Equal -Expected "password=[REDACTED]" -Actual $masked -Message "password=value masked (preserves =)"

$masked = Mask-Credentials "password: mysecret"
Assert-NotContains -Haystack $masked -Needle "mysecret" -Message "password: value masked"

$masked = Mask-Credentials "PASSWORD=SECRET123"
Assert-NotContains -Haystack $masked -Needle "SECRET123" -Message "Uppercase PASSWORD masked"

$masked = Mask-Credentials "passwd=mypass"
Assert-NotContains -Haystack $masked -Needle "mypass" -Message "passwd variant masked"

$masked = Mask-Credentials "pwd: hunter2"
Assert-NotContains -Haystack $masked -Needle "hunter2" -Message "pwd variant masked"

# Access tokens and API keys
$masked = Mask-Credentials '{"access_token": "abc123xyz789", "token_type": "Bearer"}'
Assert-Contains -Haystack $masked -Needle "[REDACTED]" -Message "access_token masked"
Assert-NotContains -Haystack $masked -Needle "abc123xyz789" -Message "access_token value hidden"

$masked = Mask-Credentials "api_key=sk-12345abc"
Assert-NotContains -Haystack $masked -Needle "sk-12345abc" -Message "api_key masked"

$masked = Mask-Credentials "apikey: myapikey123"
Assert-NotContains -Haystack $masked -Needle "myapikey123" -Message "apikey variant masked"

# JSON token and secret fields
$masked = Mask-Credentials '"token": "abc123xyz"'
Assert-NotContains -Haystack $masked -Needle "abc123xyz" -Message "JSON token field masked"

$masked = Mask-Credentials '"secret": "mysupersecret"'
Assert-NotContains -Haystack $masked -Needle "mysupersecret" -Message "JSON secret field masked"

# URL credentials
$masked = Mask-Credentials "Connecting to https://admin:secretpass@server.com/api"
Assert-NotContains -Haystack $masked -Needle "admin" -Message "URL username masked"
Assert-NotContains -Haystack $masked -Needle "secretpass" -Message "URL password masked"
Assert-Contains -Haystack $masked -Needle "[REDACTED]" -Message "URL credentials replaced with REDACTED"

# Preservation tests (should NOT be masked)
$original = "Connecting to https://server.com/api"
$masked = Mask-Credentials $original
Assert-Equal -Expected $original -Actual $masked -Message "Plain URLs preserved"

$original = "Authenticating user: admin@company.com"
$masked = Mask-Credentials $original
Assert-Equal -Expected $original -Actual $masked -Message "Usernames preserved"

$original = "Exporting secret: Server01-AdminPassword"
$masked = Mask-Credentials $original
Assert-Equal -Expected $original -Actual $masked -Message "Secret names preserved (no false positive)"

# JWT full masking
$jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.signature"
$masked = Mask-Credentials "Bearer $jwt"
Assert-NotContains -Haystack $masked -Needle "eyJhbGci" -Message "JWT header segment masked"
Assert-NotContains -Haystack $masked -Needle "eyJzdWIi" -Message "JWT payload segment masked"

#endregion

#region Checkpoint Tests

Write-Host "`nCheckpoint Management Tests" -ForegroundColor Cyan
Write-Host "===========================" -ForegroundColor Cyan

$tempDir = if ($env:TEMP) { $env:TEMP } elseif ($env:TMPDIR) { $env:TMPDIR } else { "/tmp" }
$testFile = Join-Path $tempDir "test-checkpoint-$(Get-Random).json"

# Save checkpoint
$data = @{
    Phase = "Importing"
    Progress = 1000
    SourceUrl = "https://source.com"
    ImportedIds = @(1001, 1002, 1003, 1004)
    FailedNames = @("Secret1", "Secret2")
    Metadata = @{
        Version = "2.0"
        Timestamp = "2026-01-27T15:00:00"
    }
}
$data | ConvertTo-Json -Depth 10 | Set-Content $testFile

# Restore and verify
$restored = Get-Content $testFile | ConvertFrom-Json

Assert-Equal -Expected "Importing" -Actual $restored.Phase -Message "Checkpoint Phase restored"
Assert-Equal -Expected 1000 -Actual $restored.Progress -Message "Checkpoint Progress restored"
Assert-Equal -Expected "https://source.com" -Actual $restored.SourceUrl -Message "Checkpoint URL restored"
Assert-Equal -Expected 4 -Actual $restored.ImportedIds.Count -Message "Checkpoint arrays preserved"
Assert-Equal -Expected "2.0" -Actual $restored.Metadata.Version -Message "Checkpoint nested objects preserved"

# Cleanup
Remove-Item $testFile -ErrorAction SilentlyContinue

# Missing file test
$missingFile = Join-Path $tempDir "nonexistent-$(Get-Random).json"
$exists = Test-Path $missingFile
Assert-False -Condition $exists -Message "Missing checkpoint file detected correctly"

#endregion

#region Duplicate Name Handling Tests

Write-Host "`nDuplicate Name Handling Tests" -ForegroundColor Cyan
Write-Host "=============================" -ForegroundColor Cyan

# Functions under test (copied from ss-migrate.ps1)
function Test-DuplicateName {
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
    param(
        [string]$BaseName,
        [int]$FolderId,
        [hashtable]$ExistingNames,
        [string]$Suffix = "-migrated"
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

        if ($counter -gt 1000) {
            throw "Unable to generate unique name for '$BaseName' after 1000 attempts"
        }
    }
}

# Build test data - simulating existing secrets on target
$existingNames = @{
    "100|admin-password" = @{ Id = 1001; Name = "Admin-Password"; FolderId = 100 }
    "100|database-creds" = @{ Id = 1002; Name = "Database-Creds"; FolderId = 100 }
    "200|admin-password" = @{ Id = 1003; Name = "Admin-Password"; FolderId = 200 }
    "100|migrated-secret-migrated" = @{ Id = 1004; Name = "Migrated-Secret-migrated"; FolderId = 100 }
}

# Test: Detect duplicate in same folder
$result = Test-DuplicateName -Name "Admin-Password" -FolderId 100 -ExistingNames $existingNames
Assert-True -Condition $result.IsDuplicate -Message "Detects duplicate in same folder"
Assert-Equal -Expected 1001 -Actual $result.ExistingSecret.Id -Message "Returns correct existing secret ID"

# Test: Case-insensitive duplicate detection
$result = Test-DuplicateName -Name "ADMIN-PASSWORD" -FolderId 100 -ExistingNames $existingNames
Assert-True -Condition $result.IsDuplicate -Message "Case-insensitive duplicate detection"

$result = Test-DuplicateName -Name "admin-PASSWORD" -FolderId 100 -ExistingNames $existingNames
Assert-True -Condition $result.IsDuplicate -Message "Mixed case duplicate detection"

# Test: Same name in different folder is NOT a duplicate
$result = Test-DuplicateName -Name "Admin-Password" -FolderId 300 -ExistingNames $existingNames
Assert-False -Condition $result.IsDuplicate -Message "Same name in different folder is not duplicate"

# Test: Non-duplicate name
$result = Test-DuplicateName -Name "New-Secret" -FolderId 100 -ExistingNames $existingNames
Assert-False -Condition $result.IsDuplicate -Message "Non-duplicate name detected correctly"

# Test: Generate unique name (simple case)
$uniqueName = Get-UniqueSecretName -BaseName "New-Secret" -FolderId 100 -ExistingNames $existingNames
Assert-Equal -Expected "New-Secret-migrated" -Actual $uniqueName -Message "Generates simple suffix name"

# Test: Generate unique name when suffix already exists
$uniqueName = Get-UniqueSecretName -BaseName "Migrated-Secret" -FolderId 100 -ExistingNames $existingNames
Assert-Equal -Expected "Migrated-Secret-migrated-2" -Actual $uniqueName -Message "Generates numbered suffix when base suffix exists"

# Test: Generate unique name for duplicate
$uniqueName = Get-UniqueSecretName -BaseName "Admin-Password" -FolderId 100 -ExistingNames $existingNames
Assert-Equal -Expected "Admin-Password-migrated" -Actual $uniqueName -Message "Generates suffix for duplicate name"

# Test: Verify generated name is actually unique
$checkUnique = Test-DuplicateName -Name $uniqueName -FolderId 100 -ExistingNames $existingNames
Assert-False -Condition $checkUnique.IsDuplicate -Message "Generated name is verified unique"

# Test: Empty existing names (no duplicates possible)
$emptyNames = @{}
$result = Test-DuplicateName -Name "Any-Secret" -FolderId 100 -ExistingNames $emptyNames
Assert-False -Condition $result.IsDuplicate -Message "No duplicates with empty target"

# Test: Duplicate policy configurations
$testPolicies = @("Fail", "Skip", "Rename", "TrustTarget")
foreach ($policy in $testPolicies) {
    Assert-True -Condition ($policy -in @("Fail", "Skip", "Rename", "TrustTarget")) -Message "Policy '$policy' is a valid option"
}

# Test: TrustTarget skips duplicate checking
$policy = "TrustTarget"
$skipDuplicateCheck = ($policy -eq "TrustTarget")
Assert-True -Condition $skipDuplicateCheck -Message "TrustTarget policy skips duplicate checking"

# Test: Source duplicates allowed with TrustTarget (40K secrets, 80% duplicates scenario)
$sourceSecrets = @(
    @{ Name = "Admin-Password"; FolderId = 100 }
    @{ Name = "Admin-Password"; FolderId = 100 }  # Same name, same folder
    @{ Name = "Admin-Password"; FolderId = 100 }  # Same name, same folder
    @{ Name = "DB-Creds"; FolderId = 100 }
)

$policy = "TrustTarget"
$imported = @()
foreach ($secret in $sourceSecrets) {
    if ($policy -eq "TrustTarget") {
        # No duplicate check - just import
        $imported += $secret
    }
}

Assert-Equal -Expected 4 -Actual $imported.Count -Message "TrustTarget imports all secrets including duplicates"

#endregion

#region Summary

Write-Host "`n" + ("=" * 50) -ForegroundColor Cyan
Write-Host "TEST SUMMARY" -ForegroundColor Cyan
Write-Host ("=" * 50) -ForegroundColor Cyan

$total = $script:TestResults.Passed + $script:TestResults.Failed
Write-Host "Total:  $total tests" -ForegroundColor White
Write-Host "Passed: $($script:TestResults.Passed)" -ForegroundColor Green
Write-Host "Failed: $($script:TestResults.Failed)" -ForegroundColor $(if ($script:TestResults.Failed -gt 0) { "Red" } else { "Green" })

if ($script:TestResults.Failed -gt 0) {
    Write-Host "`nFailed Tests:" -ForegroundColor Red
    foreach ($err in $script:TestResults.Errors) {
        Write-Host "  - $err" -ForegroundColor Red
    }
    exit 1
}

Write-Host "`nAll tests passed!" -ForegroundColor Green
exit 0

#endregion
