<#
.SYNOPSIS
Invoke-OrphanedResourceAudit
Audits (and optionally removes) common orphaned Azure resources: unattached managed disks, unassociated public IPs, and unattached NICs.

.DESCRIPTION
- PowerShell 7.2 compatible
- Auth via Managed Identity (Connect-AzAccount -Identity)
- Safe by default: audit-only unless -Remove is specified
- Even safer: DryRun defaults to $true; to actually delete you must set -Remove -DryRun:$false
- Optional scoping to a single resource group
- Optional exclusion tag (default: Keep=true)

.PARAMETER ResourceGroupName
If provided, only audits resources in this resource group.

.PARAMETER Remove
If set, the runbook will attempt deletion (still requires -DryRun:$false).

.PARAMETER DryRun
Default $true. When $true, logs what it WOULD delete but performs no deletions.

.PARAMETER ExcludeTagName / ExcludeTagValue
Resources with this tag/value are excluded from deletion (and flagged in output).

.PARAMETER MinAgeHours
Skip resources newer than this age (helps avoid deleting things created moments ago).
Set to 0 to disable. Default: 12 hours.

.PARAMETER WhatIfOutputOnly
If set, outputs a compact "would delete" report even when not removing.

.NOTES
- Requires permissions on the scope being scanned (RG or subscription).
- Deleting resources can be destructive. Use DryRun first and review output.
#>

param(
    [Parameter(Mandatory = $false)]
    [string] $ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [switch] $Remove,

    [Parameter(Mandatory = $false)]
    [bool] $DryRun = $true,

    [Parameter(Mandatory = $false)]
    [string] $ExcludeTagName = "Keep",

    [Parameter(Mandatory = $false)]
    [string] $ExcludeTagValue = "true",

    [Parameter(Mandatory = $false)]
    [int] $MinAgeHours = 12,

    [Parameter(Mandatory = $false)]
    [switch] $WhatIfOutputOnly
)

$ErrorActionPreference = "Stop"

function Write-Log {
    param(
        [string] $Message,
        [ValidateSet("INFO","WARN","ERROR")]
        [string] $Level = "INFO"
    )
    $ts = (Get-Date).ToString("s")
    Write-Output "[$ts][$Level] $Message"
}

function Has-ExcludeTag {
    param($resource)
    try {
        return ($null -ne $resource.Tags) -and
               ($resource.Tags.ContainsKey($ExcludeTagName)) -and
               ($resource.Tags[$ExcludeTagName] -eq $ExcludeTagValue)
    }
    catch { return $false }
}

function Is-OlderThanMinAge {
    param($resource)
    if ($MinAgeHours -le 0) { return $true }

    # Many ARM resources expose TimeCreated; some don't.
    # If missing, be conservative: treat as eligible (or flip to false if you prefer).
    $created = $null
    if ($resource.PSObject.Properties.Name -contains "TimeCreated") {
        $created = $resource.TimeCreated
    }

    if ($null -eq $created) { return $true }

    $age = (New-TimeSpan -Start $created -End (Get-Date)).TotalHours
    return ($age -ge $MinAgeHours)
}

function Should-ActOnResource {
    param($resource)

    if (Has-ExcludeTag $resource) {
        return @{ Eligible = $false; Reason = "ExcludedByTag($ExcludeTagName=$ExcludeTagValue)" }
    }

    if (-not (Is-OlderThanMinAge $resource)) {
        return @{ Eligible = $false; Reason = "YoungerThanMinAge(${MinAgeHours}h)" }
    }

    return @{ Eligible = $true; Reason = "Eligible" }
}

# Connect using Managed Identity
Write-Log "Connecting to Azure using Managed Identity..."
Connect-AzAccount -Identity | Out-Null
Write-Log "Connected."

Write-Log "Scope: $([string]::IsNullOrWhiteSpace($ResourceGroupName) ? 'Subscription' : "ResourceGroup=$ResourceGroupName")"
Write-Log "Mode: $($Remove ? 'REMOVE requested' : 'AUDIT only') | DryRun: $DryRun | MinAgeHours: $MinAgeHours | ExcludeTag: $ExcludeTagName=$ExcludeTagValue"

if ($Remove -and $DryRun) {
    Write-Log "Remove was requested but DryRun is TRUE. No deletions will occur." "WARN"
    Write-Log "To actually delete, run with: -Remove -DryRun:`$false" "WARN"
}

# Collect resources
Write-Log "Discovering orphaned resources..."

$disks = if ([string]::IsNullOrWhiteSpace($ResourceGroupName)) {
    Get-AzDisk
} else {
    Get-AzDisk -ResourceGroupName $ResourceGroupName
}

$publicIps = if ([string]::IsNullOrWhiteSpace($ResourceGroupName)) {
    Get-AzPublicIpAddress
} else {
    Get-AzPublicIpAddress -ResourceGroupName $ResourceGroupName
}

$nics = if ([string]::IsNullOrWhiteSpace($ResourceGroupName)) {
    Get-AzNetworkInterface
} else {
    Get-AzNetworkInterface -ResourceGroupName $ResourceGroupName
}

# Identify orphans
$orphanDisks = $disks | Where-Object { -not $_.ManagedBy }
$orphanPips  = $publicIps | Where-Object { -not $_.IpConfiguration }
$orphanNics  = $nics | Where-Object { -not $_.VirtualMachine }

Write-Log "Found orphan candidates: Disks=$($orphanDisks.Count) | PublicIPs=$($orphanPips.Count) | NICs=$($orphanNics.Count)"

# Build a unified report
$report = New-Object System.Collections.Generic.List[object]

function Add-ToReport {
    param(
        [string] $Type,
        $Resource,
        [string] $OrphanReason
    )

    $decision = Should-ActOnResource $Resource
    $report.Add([pscustomobject]@{
        Type         = $Type
        Name         = $Resource.Name
        ResourceGroup= $Resource.ResourceGroupName
        Location     = $Resource.Location
        Id           = $Resource.Id
        OrphanReason = $OrphanReason
        Decision     = $decision.Reason
        Eligible     = [bool]$decision.Eligible
        TimeCreated  = ($Resource.PSObject.Properties.Name -contains "TimeCreated") ? $Resource.TimeCreated : $null
    }) | Out-Null
}

foreach ($d in $orphanDisks) { Add-ToReport -Type "Disk"     -Resource $d -OrphanReason "ManagedBy is null (unattached disk)" }
foreach ($p in $orphanPips)  { Add-ToReport -Type "PublicIP" -Resource $p -OrphanReason "IpConfiguration is null (unassociated public IP)" }
foreach ($n in $orphanNics)  { Add-ToReport -Type "NIC"      -Resource $n -OrphanReason "VirtualMachine is null (unattached NIC)" }

# Output report summary
$eligible = $report | Where-Object { $_.Eligible }
$excluded = $report | Where-Object { -not $_.Eligible }

Write-Log "Eligible for action: $($eligible.Count) | Not eligible: $($excluded.Count)"

# Always show a concise table
$report |
    Sort-Object Type, ResourceGroup, Name |
    Select-Object Type, ResourceGroup, Name, OrphanReason, Decision, Eligible |
    Format-Table -AutoSize | Out-String | Write-Output

if ($WhatIfOutputOnly -or -not $Remove) {
    Write-Log "Audit complete. No deletions requested."
    return
}

# If remove requested, delete eligible resources (only if DryRun is false)
if ($DryRun) {
    Write-Log "DryRun is TRUE. Would delete the following eligible resources:" "WARN"
    $eligible | Select-Object Type, ResourceGroup, Name, Id | Format-Table -AutoSize | Out-String | Write-Output
    return
}

Write-Log "Beginning deletions of eligible orphaned resources..." "WARN"

# Delete in a safe order:
# 1) Public IPs and NICs are usually safe; disks can be more sensitive (but still eligible list is filtered).
# You can change order if desired.
$deleteOrder = @("PublicIP", "NIC", "Disk")

foreach ($t in $deleteOrder) {
    $items = $eligible | Where-Object { $_.Type -eq $t }
    foreach ($item in $items) {
        Write-Log "Deleting $($item.Type): $($item.Name) (RG: $($item.ResourceGroup))" "WARN"
        try {
            switch ($item.Type) {
                "Disk" {
                    Remove-AzDisk -ResourceGroupName $item.ResourceGroup -DiskName $item.Name -Force | Out-Null
                }
                "PublicIP" {
                    Remove-AzPublicIpAddress -ResourceGroupName $item.ResourceGroup -Name $item.Name -Force | Out-Null
                }
                "NIC" {
                    Remove-AzNetworkInterface -ResourceGroupName $item.ResourceGroup -Name $item.Name -Force | Out-Null
                }
            }
            Write-Log "Deleted: $($item.Type) $($item.Name)"
        }
        catch {
            Write-Log "Failed to delete $($item.Type) $($item.Name): $($_.Exception.Message)" "ERROR"
        }
    }
}

Write-Log "Deletion run completed."
