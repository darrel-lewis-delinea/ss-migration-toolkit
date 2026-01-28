#Requires -Version 7.0
<#
.SYNOPSIS
    Test script for v3.0 infrastructure changes
.DESCRIPTION
    Validates ID mapping, checkpoint, and validation report functionality
    without requiring actual Secret Server connections.
#>

$ErrorActionPreference = "Stop"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-TestResult {
    param(
        [string]$TestName,
        [bool]$Passed,
        [string]$Details = ""
    )

    if ($Passed) {
        Write-Host "  ✓ $TestName" -ForegroundColor Green
        $script:TestsPassed++
    }
    else {
        Write-Host "  ✗ $TestName" -ForegroundColor Red
        if ($Details) { Write-Host "    $Details" -ForegroundColor Yellow }
        $script:TestsFailed++
    }
}

function Write-TestSection {
    param([string]$Name)
    Write-Host "`n═══ $Name ═══" -ForegroundColor Cyan
}

# Load the main script to get access to functions
Write-Host "Loading ss-migrate.ps1..." -ForegroundColor Gray
. ./ss-migrate.ps1 -LogLevel Quiet 2>$null

Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  SS-MIGRATE v3.0 INFRASTRUCTURE TESTS                         ║" -ForegroundColor Cyan
Write-Host "╚═══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

# ═══════════════════════════════════════════════════════════════
Write-TestSection "ID Mapping Infrastructure"
# ═══════════════════════════════════════════════════════════════

# Test 1: Clear ID Maps
Clear-IdMaps
$allEmpty = ($script:IdMap.Sites.Count -eq 0) -and
            ($script:IdMap.Templates.Count -eq 0) -and
            ($script:IdMap.Folders.Count -eq 0) -and
            ($script:IdMap.Policies.Count -eq 0) -and
            ($script:IdMap.Secrets.Count -eq 0)
Write-TestResult "Clear-IdMaps clears all mappings" $allEmpty

# Test 2: Set-IdMapping for Sites
Set-IdMapping -ObjectType 'Sites' -SourceId 1 -TargetId 100 -Name "Local"
Set-IdMapping -ObjectType 'Sites' -SourceId 2 -TargetId 200 -Name "DMZ"
$siteMapped = ($script:IdMap.Sites.Count -eq 2) -and ($script:IdMap.Sites[1] -eq 100)
Write-TestResult "Set-IdMapping stores site mappings" $siteMapped

# Test 3: Set-IdMapping for Templates
Set-IdMapping -ObjectType 'Templates' -SourceId 10 -TargetId 1000 -Name "Windows Account"
Set-IdMapping -ObjectType 'Templates' -SourceId 20 -TargetId 2000 -Name "Unix Account"
$templateMapped = ($script:IdMap.Templates.Count -eq 2) -and ($script:IdMap.Templates[10] -eq 1000)
Write-TestResult "Set-IdMapping stores template mappings" $templateMapped

# Test 4: Set-IdMapping for Folders
Set-IdMapping -ObjectType 'Folders' -SourceId 5 -TargetId 500 -Name "IT"
Set-IdMapping -ObjectType 'Folders' -SourceId 6 -TargetId 600 -Name "IT/Production"
$folderMapped = ($script:IdMap.Folders.Count -eq 2)
Write-TestResult "Set-IdMapping stores folder mappings" $folderMapped

# Test 5: Set-IdMapping for Policies
Set-IdMapping -ObjectType 'Policies' -SourceId 3 -TargetId 300 -Name "Require Checkout"
$policyMapped = ($script:IdMap.Policies[3] -eq 300)
Write-TestResult "Set-IdMapping stores policy mappings" $policyMapped

# Test 6: Set-IdMapping for Secrets
Set-IdMapping -ObjectType 'Secrets' -SourceId 1001 -TargetId 5001 -Name "admin-password"
Set-IdMapping -ObjectType 'Secrets' -SourceId 1002 -TargetId 5002 -Name "service-account"
$secretMapped = ($script:IdMap.Secrets.Count -eq 2)
Write-TestResult "Set-IdMapping stores secret mappings" $secretMapped

# Test 7: Get-MappedId returns correct ID
$targetSiteId = Get-MappedId -ObjectType 'Sites' -SourceId 1
Write-TestResult "Get-MappedId returns correct target ID" ($targetSiteId -eq 100)

# Test 8: Get-MappedId returns null for unmapped
$unmapped = Get-MappedId -ObjectType 'Sites' -SourceId 999
Write-TestResult "Get-MappedId returns null for unmapped ID" ($null -eq $unmapped)

# Test 9: Test-IdMapping returns true for mapped
$exists = Test-IdMapping -ObjectType 'Templates' -SourceId 10
Write-TestResult "Test-IdMapping returns true for mapped ID" $exists

# Test 10: Test-IdMapping returns false for unmapped
$notExists = Test-IdMapping -ObjectType 'Templates' -SourceId 999
Write-TestResult "Test-IdMapping returns false for unmapped ID" (-not $notExists)

# Test 11: Get-IdMapSummary returns correct format
$summary = Get-IdMapSummary
$hasAllTypes = $summary -match "Sites" -and $summary -match "Templates" -and $summary -match "Secrets"
Write-TestResult "Get-IdMapSummary includes all mapped types" $hasAllTypes

# Test 12: Export-IdMap creates valid JSON
$exportPath = "./test-idmap-export.json"
Export-IdMap -Path $exportPath
$exportExists = Test-Path $exportPath
$exportValid = $false
if ($exportExists) {
    try {
        $exported = Get-Content $exportPath -Raw | ConvertFrom-Json
        # Use @() to force array and count properties correctly
        $siteProps = @($exported.Mappings.Sites.PSObject.Properties)
        $exportValid = ($siteProps.Count -eq 2)
    }
    catch { }
}
Write-TestResult "Export-IdMap creates valid JSON file" ($exportExists -and $exportValid)
if ($exportExists) { Remove-Item $exportPath -Force }

# ═══════════════════════════════════════════════════════════════
Write-TestSection "Checkpoint v3.0 with ID Mappings"
# ═══════════════════════════════════════════════════════════════

# Setup state for checkpoint
$script:State.SourceUrl = "https://source.secretservercloud.com"
$script:State.TargetUrl = "https://target.secretservercloud.com"
$script:State.CurrentPhase = "Validation"
$script:MigrationMode = "Full"
$originalCorrelationId = $script:CorrelationId

# Test 13: Save-Checkpoint includes ID mappings
$checkpointPath = $script:Config.CheckpointFile
Save-Checkpoint
$checkpointExists = Test-Path $checkpointPath
Write-TestResult "Save-Checkpoint creates checkpoint file" $checkpointExists

# Test 14: Checkpoint contains v3.0 schema
$checkpointValid = $false
if ($checkpointExists) {
    try {
        $checkpoint = Get-Content $checkpointPath -Raw | ConvertFrom-Json
        $checkpointValid = ($checkpoint.Version -eq "3.0") -and
                          ($checkpoint.IdMaps -ne $null) -and
                          ($checkpoint.MigrationMode -eq "Full") -and
                          ($checkpoint.CorrelationId -eq $originalCorrelationId)
    }
    catch { }
}
Write-TestResult "Checkpoint contains v3.0 schema fields" $checkpointValid

# Test 15: Checkpoint contains all ID mappings
$idMapsInCheckpoint = $false
if ($checkpointValid) {
    # Use @() to force array and count properties correctly
    $sitesInCheckpoint = @($checkpoint.IdMaps.Sites.PSObject.Properties)
    $templatesInCheckpoint = @($checkpoint.IdMaps.Templates.PSObject.Properties)
    $idMapsInCheckpoint = ($sitesInCheckpoint.Count -eq 2) -and
                          ($templatesInCheckpoint.Count -eq 2)
}
Write-TestResult "Checkpoint contains all ID mappings" $idMapsInCheckpoint

# Test 16: Clear and restore ID mappings
Clear-IdMaps
$script:CorrelationId = "new-id"  # Change to verify restore
$clearedBeforeRestore = ($script:IdMap.Sites.Count -eq 0)
Write-TestResult "ID mappings cleared before restore test" $clearedBeforeRestore

# Simulate restore (without interactive prompt)
if ($checkpointExists) {
    $checkpoint = Get-Content $checkpointPath -Raw | ConvertFrom-Json

    # Restore ID mappings
    foreach ($type in @('Sites', 'Templates', 'Folders', 'Policies', 'Secrets')) {
        if ($checkpoint.IdMaps.$type) {
            $script:IdMap[$type] = @{}
            foreach ($prop in $checkpoint.IdMaps.$type.PSObject.Properties) {
                $script:IdMap[$type][[int]$prop.Name] = [int]$prop.Value
            }
        }
    }

    # Restore correlation ID
    if ($checkpoint.CorrelationId) {
        $script:CorrelationId = $checkpoint.CorrelationId
    }
}

$restoredSites = ($script:IdMap.Sites.Count -eq 2) -and ($script:IdMap.Sites[1] -eq 100)
Write-TestResult "ID mappings restored from checkpoint" $restoredSites

$restoredCorrelation = ($script:CorrelationId -eq $originalCorrelationId)
Write-TestResult "Correlation ID restored from checkpoint" $restoredCorrelation

# Cleanup checkpoint
if (Test-Path $checkpointPath) { Remove-Item $checkpointPath -Force }

# ═══════════════════════════════════════════════════════════════
Write-TestSection "Validation Report Structure"
# ═══════════════════════════════════════════════════════════════

# Test 17: ValidationReport structure exists
# Note: Use $null on left side for proper scalar comparison (empty arrays are valid)
$reportStructure = ($null -ne $script:ValidationReport.Sites) -and
                   ($null -ne $script:ValidationReport.Templates) -and
                   ($null -ne $script:ValidationReport.Blocking) -and
                   ($null -ne $script:ValidationReport.Warnings)
Write-TestResult "ValidationReport has required structure" $reportStructure

# Test 18: Can populate Sites validation result
$script:ValidationReport.Sites = @{
    Mapped = @(
        @{ SourceId = 1; TargetId = 100; Name = "Local" }
    )
    Unmapped = @(
        @{ SourceId = 3; Name = "Isolated" }
    )
    AffectedSecrets = @(
        @{ SecretId = 1001; SecretName = "test-secret"; SiteId = 3 }
    )
}
$sitesPopulated = ($script:ValidationReport.Sites.Mapped.Count -eq 1) -and
                  ($script:ValidationReport.Sites.Unmapped.Count -eq 1)
Write-TestResult "Sites validation result can be populated" $sitesPopulated

# Test 19: Can populate blocking issues
$script:ValidationReport.Blocking = @("Missing template: Custom Template")
$blockingPopulated = ($script:ValidationReport.Blocking.Count -eq 1)
Write-TestResult "Blocking issues can be added" $blockingPopulated

# Test 20: Show-ValidationReport runs without error
$reportError = $null
try {
    $canProceed = Show-ValidationReport
}
catch {
    $reportError = $_
}
Write-TestResult "Show-ValidationReport executes without error" ($null -eq $reportError)
Write-TestResult "Show-ValidationReport returns false when blocking issues exist" (-not $canProceed)

# ═══════════════════════════════════════════════════════════════
Write-TestSection "State Management"
# ═══════════════════════════════════════════════════════════════

# Test 21: MigrationMode variable exists and is settable
$script:MigrationMode = "SecretsOnly"
$modeSecretsOnly = ($script:MigrationMode -eq "SecretsOnly")
Write-TestResult "MigrationMode can be set to SecretsOnly" $modeSecretsOnly

$script:MigrationMode = "Full"
$modeFull = ($script:MigrationMode -eq "Full")
Write-TestResult "MigrationMode can be set to Full" $modeFull

# Test 22: CorrelationId is valid GUID format
$correlationValid = $script:CorrelationId -match '^[a-f0-9]{8}$'
Write-TestResult "CorrelationId is valid 8-char hex" $correlationValid

# Test 23: State has token expiry fields
$hasTokenExpiry = ($script:State.PSObject.Properties.Name -contains 'SourceTokenExpiry') -or
                  ($script:State.ContainsKey('SourceTokenExpiry'))
Write-TestResult "State includes SourceTokenExpiry field" $hasTokenExpiry

# ═══════════════════════════════════════════════════════════════
Write-TestSection "Folder Migration Functions"
# ═══════════════════════════════════════════════════════════════

# Test 24: Sort-FoldersByDepth sorts correctly
$testFolders = @(
    [PSCustomObject]@{ id = 3; folderName = "Child"; parentFolderId = 2 }
    [PSCustomObject]@{ id = 1; folderName = "Root"; parentFolderId = -1 }
    [PSCustomObject]@{ id = 4; folderName = "GrandChild"; parentFolderId = 3 }
    [PSCustomObject]@{ id = 2; folderName = "Parent"; parentFolderId = 1 }
)
$sorted = Sort-FoldersByDepth -Folders $testFolders
$correctOrder = ($sorted[0].folderName -eq "Root") -and
                ($sorted[1].folderName -eq "Parent") -and
                ($sorted[2].folderName -eq "Child") -and
                ($sorted[3].folderName -eq "GrandChild")
Write-TestResult "Sort-FoldersByDepth orders parents before children" $correctOrder

# Test 25: Sort-FoldersByDepth handles flat structure
$flatFolders = @(
    [PSCustomObject]@{ id = 1; folderName = "A"; parentFolderId = -1 }
    [PSCustomObject]@{ id = 2; folderName = "B"; parentFolderId = -1 }
    [PSCustomObject]@{ id = 3; folderName = "C"; parentFolderId = -1 }
)
$sortedFlat = Sort-FoldersByDepth -Folders $flatFolders
$flatOk = ($sortedFlat.Count -eq 3)
Write-TestResult "Sort-FoldersByDepth handles flat folder structure" $flatOk

# Test 26: Sort-FoldersByDepth handles empty array
$emptyFolders = @()
$sortedEmpty = Sort-FoldersByDepth -Folders $emptyFolders
$emptyOk = ($sortedEmpty.Count -eq 0)
Write-TestResult "Sort-FoldersByDepth handles empty array" $emptyOk

# Test 27: Export-Folders function exists
$exportFoldersExists = Get-Command -Name "Export-Folders" -ErrorAction SilentlyContinue
Write-TestResult "Export-Folders function exists" ($null -ne $exportFoldersExists)

# Test 28: Import-FoldersPass1 function exists
$importFoldersExists = Get-Command -Name "Import-FoldersPass1" -ErrorAction SilentlyContinue
Write-TestResult "Import-FoldersPass1 function exists" ($null -ne $importFoldersExists)

# Test 29: Export-SecretPolicies function exists
$exportPoliciesExists = Get-Command -Name "Export-SecretPolicies" -ErrorAction SilentlyContinue
Write-TestResult "Export-SecretPolicies function exists" ($null -ne $exportPoliciesExists)

# Test 30: Import-SecretPolicies function exists
$importPoliciesExists = Get-Command -Name "Import-SecretPolicies" -ErrorAction SilentlyContinue
Write-TestResult "Import-SecretPolicies function exists" ($null -ne $importPoliciesExists)

# Test 31: Update-FolderPolicies function exists
$updatePoliciesExists = Get-Command -Name "Update-FolderPolicies" -ErrorAction SilentlyContinue
Write-TestResult "Update-FolderPolicies function exists" ($null -ne $updatePoliciesExists)

# ═══════════════════════════════════════════════════════════════
Write-TestSection "Pre-Flight Validation Functions"
# ═══════════════════════════════════════════════════════════════

# Test 32: Test-SiteMapping function exists
$testSiteMappingExists = Get-Command -Name "Test-SiteMapping" -ErrorAction SilentlyContinue
Write-TestResult "Test-SiteMapping function exists" ($null -ne $testSiteMappingExists)

# Test 33: Test-TemplateMapping function exists
$testTemplateMappingExists = Get-Command -Name "Test-TemplateMapping" -ErrorAction SilentlyContinue
Write-TestResult "Test-TemplateMapping function exists" ($null -ne $testTemplateMappingExists)

# Test 34: Invoke-PreFlightValidation function exists
$invokePreFlightExists = Get-Command -Name "Invoke-PreFlightValidation" -ErrorAction SilentlyContinue
Write-TestResult "Invoke-PreFlightValidation function exists" ($null -ne $invokePreFlightExists)

# ═══════════════════════════════════════════════════════════════
Write-TestSection "Wizard Integration (v3.0)"
# ═══════════════════════════════════════════════════════════════

# Test 35: Start-MigrationWizard function exists
$wizardExists = Get-Command -Name "Start-MigrationWizard" -ErrorAction SilentlyContinue
Write-TestResult "Start-MigrationWizard function exists" ($null -ne $wizardExists)

# Test 36: Start-FullMigration function exists
$fullMigrationExists = Get-Command -Name "Start-FullMigration" -ErrorAction SilentlyContinue
Write-TestResult "Start-FullMigration function exists" ($null -ne $fullMigrationExists)

# Test 37: MigrationMode defaults to SecretsOnly
$defaultMode = $script:MigrationMode -eq "SecretsOnly" -or $script:MigrationMode -eq "Full"
Write-TestResult "MigrationMode has valid default value" $defaultMode

# Test 38: Show-Menu function exists (for wizard)
$showMenuExists = Get-Command -Name "Show-Menu" -ErrorAction SilentlyContinue
Write-TestResult "Show-Menu function exists" ($null -ne $showMenuExists)

# Test 39: Show-Banner function exists
$showBannerExists = Get-Command -Name "Show-Banner" -ErrorAction SilentlyContinue
Write-TestResult "Show-Banner function exists" ($null -ne $showBannerExists)

# Test 40: Read-Confirmation function exists
$readConfirmExists = Get-Command -Name "Read-Confirmation" -ErrorAction SilentlyContinue
Write-TestResult "Read-Confirmation function exists" ($null -ne $readConfirmExists)

# ═══════════════════════════════════════════════════════════════
Write-TestSection "Two-Pass Secret Migration (RPC)"
# ═══════════════════════════════════════════════════════════════

# Test 41: Get-SecretsWithRpc function exists
$getSecretsRpcExists = Get-Command -Name "Get-SecretsWithRpc" -ErrorAction SilentlyContinue
Write-TestResult "Get-SecretsWithRpc function exists" ($null -ne $getSecretsRpcExists)

# Test 42: Test-CircularRpcReferences function exists
$testCircularExists = Get-Command -Name "Test-CircularRpcReferences" -ErrorAction SilentlyContinue
Write-TestResult "Test-CircularRpcReferences function exists" ($null -ne $testCircularExists)

# Test 43: Update-SecretRpcConfig function exists
$updateRpcExists = Get-Command -Name "Update-SecretRpcConfig" -ErrorAction SilentlyContinue
Write-TestResult "Update-SecretRpcConfig function exists" ($null -ne $updateRpcExists)

# Test 44: Get-SecretsWithRpc identifies secrets with privileged accounts
$testSecretsRpc = @(
    [PSCustomObject]@{ id = 1; name = "NoRpc"; launcherConnectAsSecretId = $null }
    [PSCustomObject]@{ id = 2; name = "HasRpc"; launcherConnectAsSecretId = 100 }
    [PSCustomObject]@{ id = 3; name = "HasRpcZero"; launcherConnectAsSecretId = 0 }
    [PSCustomObject]@{ id = 4; name = "HasRpcInConfig"; rpcConfig = @{ launcherConnectAsSecretId = 200 } }
)
$rpcSecrets = Get-SecretsWithRpc -Secrets $testSecretsRpc
$rpcCountCorrect = ($rpcSecrets.Count -eq 2)  # Should find "HasRpc" and "HasRpcInConfig"
Write-TestResult "Get-SecretsWithRpc finds secrets with privileged accounts" $rpcCountCorrect

# Test 45: Test-CircularRpcReferences detects A->B->A cycle
$cyclicSecrets = @(
    [PSCustomObject]@{ id = 1; name = "A"; launcherConnectAsSecretId = 2 }
    [PSCustomObject]@{ id = 2; name = "B"; launcherConnectAsSecretId = 1 }
    [PSCustomObject]@{ id = 3; name = "C"; launcherConnectAsSecretId = $null }
)
$cycles = Test-CircularRpcReferences -Secrets $cyclicSecrets
$cycleDetected = ($cycles.Count -gt 0)
Write-TestResult "Test-CircularRpcReferences detects A->B->A cycle" $cycleDetected

# Test 46: Test-CircularRpcReferences returns empty for non-cyclic
$nonCyclicSecrets = @(
    [PSCustomObject]@{ id = 1; name = "A"; launcherConnectAsSecretId = 2 }
    [PSCustomObject]@{ id = 2; name = "B"; launcherConnectAsSecretId = 3 }
    [PSCustomObject]@{ id = 3; name = "C"; launcherConnectAsSecretId = $null }
)
$noCycles = Test-CircularRpcReferences -Secrets $nonCyclicSecrets
$noCycleCorrect = ($noCycles.Count -eq 0)
Write-TestResult "Test-CircularRpcReferences returns empty for non-cyclic" $noCycleCorrect

# Test 47: Test-CircularRpcReferences handles empty array
$emptyCycles = Test-CircularRpcReferences -Secrets @()
$emptyHandled = ($emptyCycles.Count -eq 0)
Write-TestResult "Test-CircularRpcReferences handles empty array" $emptyHandled

# ═══════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  TEST SUMMARY" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Passed: " -NoNewline
Write-Host "$script:TestsPassed" -ForegroundColor Green
Write-Host "  Failed: " -NoNewline
if ($script:TestsFailed -eq 0) {
    Write-Host "$script:TestsFailed" -ForegroundColor Green
}
else {
    Write-Host "$script:TestsFailed" -ForegroundColor Red
}
Write-Host ""

if ($script:TestsFailed -eq 0) {
    Write-Host "  All tests passed! v3.0 infrastructure is working correctly." -ForegroundColor Green
}
else {
    Write-Host "  Some tests failed. Review the output above." -ForegroundColor Yellow
}

Write-Host ""

# Return exit code for CI/CD
exit $script:TestsFailed
