<#
.SYNOPSIS
Resize tagged VMs to day size in the AM and night size in the PM (Arizona time), without stop/start.

.DESCRIPTION
- Auth: Managed Identity
- Targeting: VMs with tag AutoScalePolicy=BusinessHours (optional RG scope)
- Timezone: America/Phoenix
- Online resize attempt by default (no stop/deallocate/start)
- Optional fallback: deallocate if the resize fails due to needing deallocation

#>

param(
    # Optional: limit scope to a single RG (recommended for demos)
    [Parameter(Mandatory = $false)]
    [string] $ResourceGroupName,

    # Tag targeting
    [Parameter(Mandatory = $false)]
    [string] $TagName = "AutoScalePolicy",

    [Parameter(Mandatory = $false)]
    [string] $TagValue = "BusinessHours",

    # VM sizes
    [Parameter(Mandatory = $false)]
    [string] $DayVmSize = "Standard_B1ms",

    [Parameter(Mandatory = $false)]
    [string] $NightVmSize = "Standard_B1ls",

    # Business hours (Arizona time): [start, end)
    [Parameter(Mandatory = $false)]
    [int] $BusinessStartHour = 8,

    [Parameter(Mandatory = $false)]
    [int] $BusinessEndHour = 17,

    # Safety switch for demos
    [Parameter(Mandatory = $false)]
    [switch] $DryRun,

    # Optional fallback for environments that require deallocation
    [Parameter(Mandatory = $false)]
    [switch] $ForceDeallocateIfNeeded
)

$ErrorActionPreference = "Stop"

function Get-ArizonaNow {
    $ianaId    = "America/Phoenix"
    $windowsId = "US Mountain Standard Time"

    try {
        $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById($ianaId)
    }
    catch {
        $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById($windowsId)
    }

    return [System.TimeZoneInfo]::ConvertTimeFromUtc((Get-Date).ToUniversalTime(), $tz)
}

function Write-Log {
    param(
        [string] $Message,
        [ValidateSet("INFO","WARN","ERROR")]
        [string] $Level = "INFO"
    )
    $ts = (Get-Date).ToString("s")
    Write-Output "[$ts][$Level] $Message"
}

Write-Log "Connecting to Azure using Managed Identity..."
Connect-AzAccount -Identity | Out-Null
Write-Log "Connected."

# Determine desired size based on Arizona time
$now = Get-ArizonaNow
$hour = $now.Hour
$inBusinessHours = ($hour -ge $BusinessStartHour -and $hour -lt $BusinessEndHour)
$desiredSize = if ($inBusinessHours) { $DayVmSize } else { $NightVmSize }

Write-Log "Arizona local time: $($now.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Log "Business window: $BusinessStartHour`:00 - $BusinessEndHour`:00 (local). InBusinessHours=$inBusinessHours"
Write-Log "Desired VM size for this run: $desiredSize"
Write-Log "DryRun: $DryRun | ForceDeallocateIfNeeded: $ForceDeallocateIfNeeded"

# Get VM list (VM objects include Tags)
$vms = if ([string]::IsNullOrWhiteSpace($ResourceGroupName)) {
    Get-AzVM
} else {
    Get-AzVM -ResourceGroupName $ResourceGroupName
}

$targets = $vms | Where-Object {
    $_.Tags -and $_.Tags.ContainsKey($TagName) -and $_.Tags[$TagName] -eq $TagValue
}

if (-not $targets -or $targets.Count -eq 0) {
    Write-Log "No VMs found matching tag $TagName=$TagValue" "WARN"
    return
}

Write-Log "Found $($targets.Count) target VM(s)."

foreach ($vm in $targets) {
    $vmName = $vm.Name
    $rg = $vm.ResourceGroupName
    $currentSize = $vm.HardwareProfile.VmSize

    Write-Log "-----"
    Write-Log "VM: $vmName | RG: $rg | CurrentSize: $currentSize | TargetSize: $desiredSize"

    if ($currentSize -eq $desiredSize) {
        Write-Log "Already at desired size. Skipping."
        continue
    }

    if ($DryRun) {
        Write-Log "DryRun enabled. Would update VM size from $currentSize to $desiredSize."
        continue
    }

    try {
        # Online resize attempt
        $vmConfig = Get-AzVM -ResourceGroupName $rg -Name $vmName
        $vmConfig.HardwareProfile.VmSize = $desiredSize

        Write-Log "Applying Update-AzVM (online resize attempt)..."
        Update-AzVM -ResourceGroupName $rg -VM $vmConfig | Out-Null
        Write-Log "Resize request completed for $vmName."
    }
    catch {
        Write-Log "Online resize failed for $vmName. Error: $($_.Exception.Message)" "WARN"

        if (-not $ForceDeallocateIfNeeded) {
            Write-Log "ForceDeallocateIfNeeded is OFF. Skipping fallback." "WARN"
            continue
        }

        Write-Log "Attempting fallback: deallocate -> resize -> start..."

        # Determine if VM is running (for restart decision)
        $status = Get-AzVM -ResourceGroupName $rg -Name $vmName -Status
        $powerState = ($status.Statuses | Where-Object Code -like "PowerState/*" | Select-Object -ExpandProperty DisplayStatus -First 1)
        $wasRunning = ($powerState -eq "VM running")

        if ($wasRunning) {
            Write-Log "Stopping (deallocating) VM..."
            Stop-AzVM -ResourceGroupName $rg -Name $vmName -Force | Out-Null
            Write-Log "Stopped."
        }

        $vmConfig2 = Get-AzVM -ResourceGroupName $rg -Name $vmName
        $vmConfig2.HardwareProfile.VmSize = $desiredSize

        Write-Log "Applying Update-AzVM..."
        Update-AzVM -ResourceGroupName $rg -VM $vmConfig2 | Out-Null
        Write-Log "Size updated."

        if ($wasRunning) {
            Write-Log "Starting VM..."
            Start-AzVM -ResourceGroupName $rg -Name $vmName | Out-Null
            Write-Log "Started."
        }

        Write-Log "Fallback resize complete for $vmName."
    }
}

Write-Log "Run completed."
