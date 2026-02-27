<#
.SYNOPSIS
Invoke-PreChangeVmSnapshot
Webhook-friendly runbook to create pre-change snapshots of VM disks (rollback points) before deployments/patching.

.DESCRIPTION
- PowerShell 7.2 runbook
- Auth via Managed Identity: Connect-AzAccount -Identity
- Supports direct parameters OR webhook JSON body via -WebhookData
- Targets VMs by ResourceGroup and optional tag filter
- Creates snapshots for OS + (optionally) data disks
- Optional pruning of snapshots created by this runbook based on retention days

SECURITY NOTE
Treat the webhook URL as a secret (tokenized). Rotate after demos and avoid showing it on screen.
#>

param(
    # Azure Automation passes this parameter automatically when invoked by a webhook
    [Parameter(Mandatory = $false)]
    [object] $WebhookData,

    [Parameter(Mandatory = $false)]
    [string] $ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string] $VmName,  # Optional: snapshot a single VM

    [Parameter(Mandatory = $false)]
    [string] $TagName,

    [Parameter(Mandatory = $false)]
    [string] $TagValue,

    [Parameter(Mandatory = $false)]
    [string] $ChangeId = "manual",

    [Parameter(Mandatory = $false)]
    [int] $RetentionDays = 7,

    [Parameter(Mandatory = $false)]
    [bool] $IncludeDataDisks = $false,

    [Parameter(Mandatory = $false)]
    [bool] $PruneSnapshots = $false,

    [Parameter(Mandatory = $false)]
    [bool] $DryRun = $true
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

function Read-WebhookBody {
    param([object] $WebhookData)

    if ($null -eq $WebhookData) { return $null }

    try {
        $body = $WebhookData.RequestBody
        if ([string]::IsNullOrWhiteSpace($body)) { return $null }
        return ($body | ConvertFrom-Json)
    }
    catch {
        Write-Log "Failed to parse webhook JSON body: $($_.Exception.Message)" "ERROR"
        throw
    }
}

function Try-ParseUtcDate {
    param(
        [Parameter(Mandatory)]
        [string] $Text
    )

    # Returns [DateTime] (UTC) or $null if unparseable
    try {
        # Handles values like: 2026-02-23T18:48:32Z
        $dt = (Get-Date $Text).ToUniversalTime()
        return $dt
    }
    catch {
        return $null
    }
}

# If invoked by webhook, let JSON override params (only when the JSON field is present)
$payload = Read-WebhookBody -WebhookData $WebhookData
if ($null -ne $payload) {
    Write-Log "Webhook payload received. Applying payload values (where provided)."

    foreach ($p in @(
        "ResourceGroupName","VmName","TagName","TagValue","ChangeId",
        "RetentionDays","IncludeDataDisks","PruneSnapshots","DryRun"
    )) {
        if ($payload.PSObject.Properties.Name -contains $p) {
            Set-Variable -Name $p -Value $payload.$p
        }
    }
}

if ([string]::IsNullOrWhiteSpace($ResourceGroupName)) {
    throw "ResourceGroupName is required (either as a runbook parameter or in webhook JSON)."
}

# Normalize/validate
if ([string]::IsNullOrWhiteSpace($ChangeId)) { $ChangeId = "manual" }
if ($RetentionDays -lt 1) { $RetentionDays = 1 }

Write-Log "Connecting to Azure using Managed Identity..."
Connect-AzAccount -Identity | Out-Null
Write-Log "Connected."

Write-Log "Parameters (effective):"
Write-Log "  ResourceGroupName=$ResourceGroupName"
Write-Log "  VmName=$VmName"
Write-Log "  TagFilter=$TagName=$TagValue"
Write-Log "  ChangeId=$ChangeId"
Write-Log "  RetentionDays=$RetentionDays"
Write-Log "  IncludeDataDisks=$IncludeDataDisks"
Write-Log "  PruneSnapshots=$PruneSnapshots"
Write-Log "  DryRun=$DryRun"

# Get VMs
$vms = if (-not [string]::IsNullOrWhiteSpace($VmName)) {
    @(Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName)
} else {
    Get-AzVM -ResourceGroupName $ResourceGroupName
}

if (-not [string]::IsNullOrWhiteSpace($TagName)) {
    $vms = $vms | Where-Object {
        $_.Tags -and $_.Tags.ContainsKey($TagName) -and $_.Tags[$TagName] -eq $TagValue
    }
}

if (-not $vms -or $vms.Count -eq 0) {
    Write-Log "No VMs matched criteria. Exiting." "WARN"
    return
}

Write-Log "Found $($vms.Count) VM(s) to snapshot."

$timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmmssZ")
$nonce = ([Guid]::NewGuid().ToString("N")).Substring(0,8)

function New-SnapshotName {
    param([string] $vmName, [string] $diskName)

    $base = "snap-$vmName-$diskName-$ChangeId-$timestamp-$nonce"
    $base = ($base -replace '[^a-zA-Z0-9\-]', '-')

    if ($base.Length -gt 80) { $base = $base.Substring(0, 80) }
    return $base.TrimEnd('-')
}

function Get-SnapshotTags {
    param([string] $vmName, [string] $diskId, [string] $diskName, [string] $diskRole)

    return @{
        "CreatedBy"      = "AzureAutomation"
        "Purpose"        = "PreChange"
        "ChangeId"       = $ChangeId
        "RetentionDays"  = "$RetentionDays"
        "SourceVm"       = $vmName
        "SourceDiskName" = $diskName
        "SourceDiskRole" = $diskRole   # OS | Data
        "SourceDiskId"   = $diskId
        "CreatedUtc"     = (Get-Date).ToUniversalTime().ToString("s") + "Z"
    }
}

foreach ($vm in $vms) {
    Write-Log "-----"
    Write-Log "VM: $($vm.Name)"

    # OS disk snapshot
    $osDiskName = $vm.StorageProfile.OsDisk.Name
    if ([string]::IsNullOrWhiteSpace($osDiskName)) {
        Write-Log "VM $($vm.Name) has no OS disk name found. Skipping." "WARN"
        continue
    }

    $osDisk = Get-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $osDiskName
    $osSnapName = New-SnapshotName -vmName $vm.Name -diskName $osDiskName
    $osTags = Get-SnapshotTags -vmName $vm.Name -diskId $osDisk.Id -diskName $osDiskName -diskRole "OS"

    Write-Log "OS Disk: $osDiskName -> Snapshot: $osSnapName"
    if ($DryRun) {
        Write-Log "DryRun: would create OS snapshot."
    } else {
        $snapConfig = New-AzSnapshotConfig -SourceUri $osDisk.Id -Location $osDisk.Location -CreateOption Copy -Tag $osTags
        New-AzSnapshot -SnapshotName $osSnapName -ResourceGroupName $ResourceGroupName -Snapshot $snapConfig | Out-Null
        Write-Log "Created OS snapshot: $osSnapName"
    }

    # Data disks snapshot (optional)
    if ($IncludeDataDisks -and $vm.StorageProfile.DataDisks -and $vm.StorageProfile.DataDisks.Count -gt 0) {
        foreach ($dd in $vm.StorageProfile.DataDisks) {
            $diskName = $dd.Name
            if ([string]::IsNullOrWhiteSpace($diskName)) { continue }

            $disk = Get-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $diskName
            $snapName = New-SnapshotName -vmName $vm.Name -diskName $diskName
            $tags = Get-SnapshotTags -vmName $vm.Name -diskId $disk.Id -diskName $diskName -diskRole "Data"

            Write-Log "Data Disk: $diskName -> Snapshot: $snapName"
            if ($DryRun) {
                Write-Log "DryRun: would create data snapshot."
            } else {
                $snapConfig = New-AzSnapshotConfig -SourceUri $disk.Id -Location $disk.Location -CreateOption Copy -Tag $tags
                New-AzSnapshot -SnapshotName $snapName -ResourceGroupName $ResourceGroupName -Snapshot $snapConfig | Out-Null
                Write-Log "Created data snapshot: $snapName"
            }
        }
    } else {
        Write-Log "IncludeDataDisks is false (or no data disks). Skipping data disks."
    }
}

# Optional pruning (only snapshots created by this runbook, in this RG)
if ($PruneSnapshots) {
    Write-Log "-----"
    Write-Log "Pruning snapshots (CreatedBy=AzureAutomation, Purpose=PreChange) older than RetentionDays=$RetentionDays..."

    $cutoff = (Get-Date).ToUniversalTime().AddDays(-1 * $RetentionDays)

    $snaps = Get-AzSnapshot -ResourceGroupName $ResourceGroupName | Where-Object {
        $_.Tags -and $_.Tags.ContainsKey("CreatedBy") -and $_.Tags["CreatedBy"] -eq "AzureAutomation" -and
        $_.Tags.ContainsKey("Purpose") -and $_.Tags["Purpose"] -eq "PreChange"
    }

    $toDelete = New-Object System.Collections.Generic.List[object]

    foreach ($s in $snaps) {
        $createdUtc = $null

        if ($s.Tags.ContainsKey("CreatedUtc") -and -not [string]::IsNullOrWhiteSpace($s.Tags["CreatedUtc"])) {
            $createdUtc = Try-ParseUtcDate -Text $s.Tags["CreatedUtc"]
        }

        if ($null -eq $createdUtc -and ($s.PSObject.Properties.Name -contains "TimeCreated") -and $null -ne $s.TimeCreated) {
            $createdUtc = $s.TimeCreated.ToUniversalTime()
        }

        if ($null -eq $createdUtc) {
            Write-Log "Skipping prune check for snapshot '$($s.Name)' (unable to determine creation time)." "WARN"
            continue
        }

        if ($createdUtc -lt $cutoff) {
            $toDelete.Add($s) | Out-Null
        }
    }

    Write-Log "Snapshots eligible for deletion: $($toDelete.Count)"

    foreach ($s in $toDelete) {
        $createdTag = $null
        if ($s.Tags -and $s.Tags.ContainsKey("CreatedUtc")) { $createdTag = $s.Tags["CreatedUtc"] }

        Write-Log "Delete snapshot: $($s.Name) (created=$createdTag)" "WARN"
        if ($DryRun) {
            Write-Log "DryRun: would delete snapshot."
        } else {
            Remove-AzSnapshot -ResourceGroupName $ResourceGroupName -SnapshotName $s.Name -Force | Out-Null
            Write-Log "Deleted snapshot: $($s.Name)"
        }
    }
}

Write-Log "Run complete."
