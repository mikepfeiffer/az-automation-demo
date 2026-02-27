# Real-World CloudOps with PowerShell Runbooks in Azure Automation

This repository contains production-ready PowerShell runbook examples demonstrated in the "Real-World CloudOps with PowerShell Runbooks in Azure Automation" webinar. These runbooks showcase practical patterns for automating common Azure operational tasks using Azure Automation.

## Table of Contents

- [Azure Automation Essentials](#azure-automation-essentials)
- [Writing Production-Ready Runbooks](#writing-production-ready-runbooks)
- [How Runbooks Are Invoked](#how-runbooks-are-invoked)
- [Use Case Demos](#use-case-demos)
  - [Demo #1: Intelligent VM Sizing](#demo-1-intelligent-vm-sizing)
  - [Demo #2: Orphaned Resource Governance](#demo-2-orphaned-resource-governance)
  - [Demo #3: Pre-Change Safety Automation](#demo-3-pre-change-safety-automation)
- [GitHub Actions Integration Example](#github-actions-integration-example)
- [Prerequisites](#prerequisites)
- [Setup Instructions](#setup-instructions)
- [Disclaimer](#disclaimer)

---

## Azure Automation Essentials

Azure Automation provides a cloud-based automation and configuration service that helps you manage your Azure and on-premises infrastructure. Key components include:

- **Automation Account**: The container that hosts runbooks, modules, and managed identities
- **PowerShell 7 Runtime**: Modern PowerShell execution environment with Az module support
- **Managed Identity**: Secure, password-free authentication to Azure services
- **RBAC (Role-Based Access Control)**: Defines what the runbook is allowed to change in your environment
- **Jobs**: Execution instances that provide logs, output, and observability for each runbook run

---

## Writing Production-Ready Runbooks

All runbooks in this repository follow production-ready patterns and best practices:

### Key Principles

1. **Parameter-Driven Design**: No hardcoded values; everything is configurable via parameters
2. **Tag-Based Resource Targeting**: Uses Azure tags to identify which resources to act upon
3. **Idempotent Logic**: Safe to run multiple times without unintended side effects
4. **DryRun / Safety Controls**: Built-in switches to preview changes before execution
5. **Clear Logging**: Structured output with timestamps and severity levels for observability

These patterns ensure runbooks are:
- Reusable across different environments
- Safe to test and deploy
- Easy to troubleshoot
- Compliant with change management processes

---

## How Runbooks Are Invoked

Azure Automation runbooks support multiple invocation methods:

1. **Manual Execution**: Run interactively from the Azure portal for testing and one-off tasks
2. **Schedules**: Time-based automation (e.g., daily, hourly) for recurring operational tasks
3. **Webhooks**: Event-driven triggers that integrate with CI/CD pipelines, Azure Monitor alerts, or external systems
4. **CI/CD Integration**: Called programmatically from DevOps pipelines for deployment automation
5. **Parameter Overrides**: All invocation methods support parameter customization at runtime

---

## Use Case Demos

### Demo #1: Intelligent VM Sizing

**Script**: `Apply-VmSizingPolicy.ps1`

#### Purpose

Automatically align compute capacity with real business demand by resizing virtual machines based on operational schedules and policy. This eliminates manual intervention while reducing unnecessary cloud spend.

#### How It Works

This runbook implements a time-based VM sizing policy that:
1. Queries the current time in Arizona timezone (configurable)
2. Determines if it's currently "business hours" (default: 8 AM - 5 PM)
3. Finds all VMs tagged with `AutoScalePolicy=BusinessHours`
4. Resizes VMs to the appropriate size:
   - **Day size** (`Standard_B1ms`) during business hours for full capacity
   - **Night size** (`Standard_B1ls`) outside business hours to reduce costs
5. Attempts online resize first (no downtime)
6. Falls back to stop/resize/start if online resize is not supported

#### Key Features

- **Timezone-Aware**: Uses Arizona time (no DST) for consistent scheduling
- **Tag-Based Targeting**: Only affects VMs with the specified tag
- **Online Resize**: Attempts resize without VM downtime when possible
- **Optional Fallback**: Can deallocate/resize/restart if needed via `-ForceDeallocateIfNeeded`
- **Safe Testing**: DryRun mode shows what would happen without making changes
- **Scoped Execution**: Optional `-ResourceGroupName` parameter limits scope

#### Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `ResourceGroupName` | string | (all) | Limit scope to a single resource group |
| `TagName` | string | `AutoScalePolicy` | Tag key to identify target VMs |
| `TagValue` | string | `BusinessHours` | Tag value to match |
| `DayVmSize` | string | `Standard_B1ms` | VM size during business hours |
| `NightVmSize` | string | `Standard_B1ls` | VM size outside business hours |
| `BusinessStartHour` | int | `8` | Business hours start (local time) |
| `BusinessEndHour` | int | `17` | Business hours end (local time) |
| `DryRun` | switch | `false` | Preview mode - logs actions without executing |
| `ForceDeallocateIfNeeded` | switch | `false` | Enable stop/resize/start fallback |

#### Usage Examples

**Test with DryRun:**
```powershell
# See what would happen without making changes
Start-AzAutomationRunbook -Name "Apply-VmSizingPolicy" `
    -Parameters @{ DryRun = $true } `
    -AutomationAccountName "MyAutomationAccount" `
    -ResourceGroupName "MyRG"
```

**Target specific resource group:**
```powershell
# Only resize VMs in production RG
Start-AzAutomationRunbook -Name "Apply-VmSizingPolicy" `
    -Parameters @{
        ResourceGroupName = "prod-rg"
    } `
    -AutomationAccountName "MyAutomationAccount" `
    -ResourceGroupName "MyRG"
```

**Custom schedule and sizes:**
```powershell
# 6 AM - 10 PM schedule with different VM sizes
Start-AzAutomationRunbook -Name "Apply-VmSizingPolicy" `
    -Parameters @{
        BusinessStartHour = 6
        BusinessEndHour = 22
        DayVmSize = "Standard_D2s_v3"
        NightVmSize = "Standard_B2s"
    } `
    -AutomationAccountName "MyAutomationAccount" `
    -ResourceGroupName "MyRG"
```

#### Setup Requirements

1. **Tag your VMs**: Add `AutoScalePolicy=BusinessHours` tag to VMs that should auto-resize
2. **Create Schedule**: Set up two schedules in Azure Automation:
   - Morning schedule (e.g., 8:00 AM) to resize up
   - Evening schedule (e.g., 5:00 PM) to resize down
3. **RBAC Permissions**: Grant the Automation Account's managed identity `Virtual Machine Contributor` role
4. **Test First**: Always run with `-DryRun $true` first to verify targeting

#### Why Use This

- **Cost Optimization**: Can reduce VM costs by 50-70% for workloads that don't need full capacity 24/7
- **Automatic Scaling**: No manual intervention needed to match capacity to demand
- **Non-Disruptive**: Online resize keeps VMs running when possible
- **Flexible**: Easily customizable schedule and size policies per environment

---

### Demo #2: Orphaned Resource Governance

**Script**: `Invoke-OrphanedResourceAudit.ps1`

#### Purpose

Continuously identify and remediate unused infrastructure resources that create hidden cost leakage. This enforces subscription hygiene through safe, policy-driven automation.

#### How It Works

This runbook performs automated discovery and cleanup of orphaned Azure resources:

1. **Discovery Phase**: Scans subscription or resource group for:
   - **Unattached Managed Disks**: Disks where `ManagedBy` is null (not attached to any VM)
   - **Unassociated Public IPs**: Public IPs where `IpConfiguration` is null (not bound to NIC/LB)
   - **Unattached NICs**: Network interfaces where `VirtualMachine` is null (not attached to VM)

2. **Eligibility Check**: Applies filtering logic:
   - Excludes resources with `Keep=true` tag (configurable)
   - Excludes resources newer than `MinAgeHours` (default: 12 hours)
   - Generates detailed report with reasons for each decision

3. **Remediation Phase** (optional):
   - Only runs if `-Remove` is specified
   - Requires `-DryRun:$false` for actual deletion
   - Deletes in safe order: PublicIP → NIC → Disk

#### Key Features

- **Safe by Default**: Audit-only mode unless explicitly set to remove
- **Double Safety**: Even with `-Remove`, requires `-DryRun:$false` to actually delete
- **Tag-Based Protection**: Resources with exclusion tag are never deleted
- **Age Filter**: Avoids deleting resources created moments ago
- **Comprehensive Reporting**: Detailed table output showing all orphaned resources and decisions
- **Scope Control**: Can target entire subscription or single resource group

#### Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `ResourceGroupName` | string | (all) | Limit scope to a single resource group |
| `Remove` | switch | `false` | Enable deletion mode (still requires DryRun:$false) |
| `DryRun` | bool | `true` | When true, only logs what would be deleted |
| `ExcludeTagName` | string | `Keep` | Tag key that protects resources from deletion |
| `ExcludeTagValue` | string | `true` | Tag value that protects resources |
| `MinAgeHours` | int | `12` | Only consider resources older than this (set to 0 to disable) |
| `WhatIfOutputOnly` | switch | `false` | Show compact "would delete" report |

#### Usage Examples

**Audit orphaned resources (read-only):**
```powershell
# Safe discovery - no deletions
Start-AzAutomationRunbook -Name "Invoke-OrphanedResourceAudit" `
    -AutomationAccountName "MyAutomationAccount" `
    -ResourceGroupName "MyRG"
```

**Preview what would be deleted:**
```powershell
# See deletion candidates
Start-AzAutomationRunbook -Name "Invoke-OrphanedResourceAudit" `
    -Parameters @{
        Remove = $true
        DryRun = $true
    } `
    -AutomationAccountName "MyAutomationAccount" `
    -ResourceGroupName "MyRG"
```

**Actually delete orphaned resources:**
```powershell
# DESTRUCTIVE: Actually removes orphans
Start-AzAutomationRunbook -Name "Invoke-OrphanedResourceAudit" `
    -Parameters @{
        Remove = $true
        DryRun = $false
        MinAgeHours = 24  # Only delete resources older than 24 hours
    } `
    -AutomationAccountName "MyAutomationAccount" `
    -ResourceGroupName "MyRG"
```

**Custom exclusion tag:**
```powershell
# Protect resources with DoNotDelete=yes
Start-AzAutomationRunbook -Name "Invoke-OrphanedResourceAudit" `
    -Parameters @{
        ExcludeTagName = "DoNotDelete"
        ExcludeTagValue = "yes"
        Remove = $true
        DryRun = $false
    } `
    -AutomationAccountName "MyAutomationAccount" `
    -ResourceGroupName "MyRG"
```

#### Setup Requirements

1. **RBAC Permissions**: Grant managed identity appropriate permissions:
   - Reader role (for audit-only)
   - Contributor role (for deletion)
2. **Tag Strategy**: Apply `Keep=true` tag to any orphaned resources you want to preserve
3. **Testing**: Always run in audit mode first, then DryRun mode before actual deletion
4. **Schedule**: Set up weekly/monthly schedule for regular hygiene enforcement

#### Why Use This

- **Cost Savings**: Orphaned disks and public IPs incur charges even when unused
- **Subscription Hygiene**: Keeps environments clean and easier to manage
- **Automated Governance**: Enforces cleanup policies without manual intervention
- **Safe Automation**: Multiple safety layers prevent accidental deletion
- **Compliance**: Helps meet policies requiring removal of unused resources

---

### Demo #3: Pre-Change Safety Automation

**Script**: `Invoke-PreChangeVmSnapshot.ps1`

#### Purpose

Integrate automated rollback protection into deployment workflows by creating pre-change VM snapshots on demand. This reduces operational risk without slowing delivery velocity.

#### How It Works

This webhook-friendly runbook creates point-in-time snapshots of VM disks:

1. **Target Selection**: Identifies VMs to snapshot based on:
   - Specific VM name
   - Resource group scope
   - Optional tag filter

2. **Snapshot Creation**: For each target VM:
   - Creates snapshot of OS disk (always)
   - Optionally creates snapshots of all data disks
   - Names snapshots with: `snap-{vmname}-{diskname}-{changeid}-{timestamp}-{nonce}`
   - Tags snapshots with metadata for tracking and retention

3. **Retention Management** (optional):
   - Automatically prunes old snapshots created by this runbook
   - Based on `RetentionDays` parameter
   - Only removes snapshots tagged as created by this automation

4. **Webhook Integration**: Can accept parameters via JSON body when invoked by webhook

#### Key Features

- **Webhook-Friendly**: Supports invocation from CI/CD pipelines via webhook
- **Change Tracking**: Associates snapshots with change IDs for traceability
- **Comprehensive Metadata**: Tags include source VM, disk, creation time, retention policy
- **Selective Snapshotting**: Choose OS-only or include data disks
- **Automatic Pruning**: Optional cleanup of old snapshots based on retention policy
- **Safe Testing**: DryRun mode for testing without creating actual snapshots

#### Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `WebhookData` | object | - | Auto-populated by Azure Automation when called via webhook |
| `ResourceGroupName` | string | (required) | Resource group containing target VMs |
| `VmName` | string | - | Specific VM to snapshot (optional, otherwise all in RG) |
| `TagName` | string | - | Filter VMs by tag key |
| `TagValue` | string | - | Filter VMs by tag value |
| `ChangeId` | string | `manual` | Change/deployment identifier for tracking |
| `RetentionDays` | int | `7` | How many days to retain snapshots |
| `IncludeDataDisks` | bool | `false` | Whether to snapshot data disks in addition to OS disk |
| `PruneSnapshots` | bool | `false` | Whether to delete expired snapshots |
| `DryRun` | bool | `true` | Preview mode - no actual snapshots created |

#### Usage Examples

**Manual execution with DryRun:**
```powershell
# Preview snapshot creation
Start-AzAutomationRunbook -Name "Invoke-PreChangeVmSnapshot" `
    -Parameters @{
        ResourceGroupName = "prod-rg"
        DryRun = $true
    } `
    -AutomationAccountName "MyAutomationAccount" `
    -ResourceGroupName "MyRG"
```

**Snapshot specific VM before deployment:**
```powershell
# Create snapshots for one VM
Start-AzAutomationRunbook -Name "Invoke-PreChangeVmSnapshot" `
    -Parameters @{
        ResourceGroupName = "prod-rg"
        VmName = "webserver-01"
        ChangeId = "deploy-20260227-001"
        IncludeDataDisks = $true
        DryRun = $false
    } `
    -AutomationAccountName "MyAutomationAccount" `
    -ResourceGroupName "MyRG"
```

**Tag-based targeting:**
```powershell
# Snapshot all VMs with specific tag
Start-AzAutomationRunbook -Name "Invoke-PreChangeVmSnapshot" `
    -Parameters @{
        ResourceGroupName = "prod-rg"
        TagName = "Tier"
        TagValue = "Frontend"
        ChangeId = "patch-cycle-march"
        DryRun = $false
    } `
    -AutomationAccountName "MyAutomationAccount" `
    -ResourceGroupName "MyRG"
```

**Webhook invocation from CI/CD pipeline:**
```bash
# Example: Call from Azure DevOps or GitHub Actions
curl -X POST "https://webhook-url.azure-automation.net/..." \
  -H "Content-Type: application/json" \
  -d '{
    "ResourceGroupName": "prod-rg",
    "VmName": "app-server-01",
    "ChangeId": "release-2.5.0",
    "IncludeDataDisks": true,
    "RetentionDays": 14,
    "DryRun": false
  }'
```

**Cleanup old snapshots:**
```powershell
# Prune snapshots older than retention period
Start-AzAutomationRunbook -Name "Invoke-PreChangeVmSnapshot" `
    -Parameters @{
        ResourceGroupName = "prod-rg"
        PruneSnapshots = $true
        RetentionDays = 7
        DryRun = $false
    } `
    -AutomationAccountName "MyAutomationAccount" `
    -ResourceGroupName "MyRG"
```

#### Snapshot Naming Convention

Snapshots are named: `snap-{vmname}-{diskname}-{changeid}-{timestamp}-{nonce}`

Example: `snap-webserver01-osdisk-deploy20260227-20260227-143052Z-a3f7b2c1`

#### Snapshot Tags

Each snapshot includes comprehensive metadata tags:

| Tag | Example | Purpose |
|-----|---------|---------|
| `CreatedBy` | `AzureAutomation` | Identifies snapshots created by this runbook |
| `Purpose` | `PreChange` | Indicates this is a rollback point |
| `ChangeId` | `deploy-20260227-001` | Links snapshot to specific change |
| `RetentionDays` | `7` | Retention policy |
| `SourceVm` | `webserver-01` | VM that was snapshotted |
| `SourceDiskName` | `osdisk` | Which disk was snapshotted |
| `SourceDiskRole` | `OS` or `Data` | Disk type |
| `SourceDiskId` | `/subscriptions/...` | Full resource ID |
| `CreatedUtc` | `2026-02-27T14:30:52Z` | ISO 8601 timestamp |

#### Setup Requirements

1. **RBAC Permissions**: Grant managed identity:
   - Reader on subscription/RG (to list VMs and disks)
   - Snapshot Contributor or Contributor role (to create/delete snapshots)

2. **Webhook Setup** (for CI/CD integration):
   ```powershell
   # Create webhook
   $webhook = New-AzAutomationWebhook `
       -Name "PreChangeSnapshot-Webhook" `
       -RunbookName "Invoke-PreChangeVmSnapshot" `
       -IsEnabled $true `
       -ExpiryTime (Get-Date).AddYears(1) `
       -AutomationAccountName "MyAutomationAccount" `
       -ResourceGroupName "MyRG"

   # IMPORTANT: Save webhook URL securely - it contains the secret token
   $webhook.WebhookURI | Out-File -FilePath "webhook-url.txt"
   ```

3. **Security Note**: Treat webhook URLs as secrets. The URL contains an embedded token that grants execution access. Store in Azure Key Vault or your secrets management system.

4. **Schedule for Cleanup**: Optionally create a schedule to regularly prune old snapshots

#### Why Use This

- **Rollback Safety**: Easy recovery if deployment goes wrong
- **Pipeline Integration**: Fits seamlessly into CI/CD workflows
- **Minimal Impact**: Snapshots are taken without VM downtime
- **Automated Retention**: No manual cleanup needed - old snapshots auto-purge
- **Change Tracking**: Links snapshots to deployments for auditability
- **Cost Management**: Snapshots are incremental and cheaper than keeping full disk copies

#### Rollback Procedure

If you need to restore from a snapshot:

```powershell
# 1. Get the snapshot
$snapshot = Get-AzSnapshot -ResourceGroupName "prod-rg" -SnapshotName "snap-webserver01-osdisk-..."

# 2. Create new disk from snapshot
$diskConfig = New-AzDiskConfig -Location $snapshot.Location -SourceResourceId $snapshot.Id -CreateOption Copy
$disk = New-AzDisk -ResourceGroupName "prod-rg" -DiskName "recovered-osdisk" -Disk $diskConfig

# 3. Stop the VM
Stop-AzVM -ResourceGroupName "prod-rg" -Name "webserver-01" -Force

# 4. Swap the OS disk (see Azure documentation for complete procedure)
Set-AzVMOSDisk -VM $vm -ManagedDiskId $disk.Id -Name $disk.Name

# 5. Start the VM
Start-AzVM -ResourceGroupName "prod-rg" -Name "webserver-01"
```

---

## GitHub Actions Integration Example

This repository includes a complete **GitHub Actions workflow** (`.github/workflows/deploy-iis-webapp.yml`) that demonstrates how to integrate the Pre-Change Snapshot runbook into a real-world CI/CD pipeline.

### What's Included

The workflow showcases a production-ready deployment pattern for an IIS web application:

1. **Pre-Deployment Snapshot Job**
   - Invokes the snapshot runbook via webhook before deployment
   - Passes deployment metadata (Change ID, VM name, resource group)
   - Waits for snapshot completion with timeout and status checking
   - Fails the deployment if snapshot creation fails

2. **Build Job**
   - Runs in parallel with snapshot creation to save time
   - Builds a fictitious .NET web application
   - Creates deployment package

3. **Deploy Job**
   - Only runs if snapshot and build both succeed
   - Simulates WebDeploy to IIS server
   - Includes health check verification

4. **Post-Deployment Validation**
   - Runs smoke tests
   - Sends notifications

### Key Features

- **Webhook Integration**: Shows how to call Azure Automation from CI/CD
- **Status Polling**: Demonstrates waiting for job completion (60-120 seconds)
- **Error Handling**: Proper failure modes and rollback protection
- **Windows Runner**: Uses `windows-latest` for IIS deployment scenarios
- **Production Patterns**: Includes manual triggers, DryRun options, and environment protection

### Quick Start

See **[WORKFLOW-SETUP.md](WORKFLOW-SETUP.md)** for complete instructions on:
- Creating and configuring the webhook
- Setting up GitHub secrets
- Customizing for your application
- Troubleshooting common issues
- Implementing rollback procedures

This example can be adapted for other deployment scenarios (Azure App Service, VMs, containers) and demonstrates how to build safe, auditable deployment pipelines with automated rollback protection.

---

## Prerequisites

To use these runbooks, you'll need:

### Azure Resources
- **Azure Subscription** with appropriate permissions
- **Azure Automation Account** with PowerShell 7.2 runtime
- **Managed Identity** enabled on the Automation Account
- **Az PowerShell Modules** (pre-installed in Azure Automation)

### Permissions (RBAC Roles)

Assign these roles to your Automation Account's managed identity:

| Runbook | Required Role | Scope |
|---------|--------------|-------|
| Apply-VmSizingPolicy | Virtual Machine Contributor | Subscription or specific RG |
| Invoke-OrphanedResourceAudit | Reader (audit) / Contributor (delete) | Subscription or specific RG |
| Invoke-PreChangeVmSnapshot | Snapshot Contributor + Reader | Subscription or specific RG |

---

## Setup Instructions

### 1. Create Automation Account

```bash
# Using Azure CLI
az automation account create \
    --name "MyAutomationAccount" \
    --resource-group "automation-rg" \
    --location "eastus" \
    --sku "Basic"

# Enable system-assigned managed identity
az automation account update \
    --name "MyAutomationAccount" \
    --resource-group "automation-rg" \
    --assign-identity
```

### 2. Assign RBAC Permissions

```bash
# Get the managed identity principal ID
PRINCIPAL_ID=$(az automation account show \
    --name "MyAutomationAccount" \
    --resource-group "automation-rg" \
    --query identity.principalId -o tsv)

# Assign Virtual Machine Contributor for VM sizing runbook
az role assignment create \
    --assignee $PRINCIPAL_ID \
    --role "Virtual Machine Contributor" \
    --scope "/subscriptions/{subscription-id}"

# Assign Contributor for other runbooks
az role assignment create \
    --assignee $PRINCIPAL_ID \
    --role "Contributor" \
    --scope "/subscriptions/{subscription-id}"
```

### 3. Import Runbooks

```powershell
# Using PowerShell
Import-AzAutomationRunbook `
    -Path ".\Apply-VmSizingPolicy.ps1" `
    -Name "Apply-VmSizingPolicy" `
    -Type PowerShell `
    -AutomationAccountName "MyAutomationAccount" `
    -ResourceGroupName "automation-rg" `
    -Published
```

Or use the Azure Portal:
1. Navigate to Automation Account → Runbooks
2. Click "Import a runbook"
3. Upload the `.ps1` file
4. Set Runbook type to "PowerShell"
5. Set Runtime version to "7.2"
6. Click "Create" then "Publish"

### 4. Create Schedules (Example: VM Sizing)

```powershell
# Morning schedule - scale up
New-AzAutomationSchedule `
    -Name "ScaleUp-BusinessHours" `
    -StartTime "08:00:00" `
    -DayInterval 1 `
    -AutomationAccountName "MyAutomationAccount" `
    -ResourceGroupName "automation-rg" `
    -TimeZone "US Mountain Standard Time"

# Link schedule to runbook
Register-AzAutomationScheduledRunbook `
    -RunbookName "Apply-VmSizingPolicy" `
    -ScheduleName "ScaleUp-BusinessHours" `
    -AutomationAccountName "MyAutomationAccount" `
    -ResourceGroupName "automation-rg"
```

### 5. Create Webhook (Example: Pre-Change Snapshots)

```powershell
$webhook = New-AzAutomationWebhook `
    -Name "PreChangeSnapshot-Webhook" `
    -RunbookName "Invoke-PreChangeVmSnapshot" `
    -IsEnabled $true `
    -ExpiryTime (Get-Date).AddYears(1) `
    -AutomationAccountName "MyAutomationAccount" `
    -ResourceGroupName "automation-rg"

# IMPORTANT: Save the webhook URL securely
$webhook.WebhookURI | Set-Content "webhook-url-secret.txt"
```

### 6. Tag Your Resources

```bash
# Tag VMs for auto-sizing
az vm update \
    --resource-group "prod-rg" \
    --name "webserver-01" \
    --set tags.AutoScalePolicy=BusinessHours

# Protect resources from orphan cleanup
az disk update \
    --resource-group "prod-rg" \
    --name "important-disk" \
    --set tags.Keep=true
```

---

## Best Practices

### Testing
1. Always test runbooks with `-DryRun $true` first
2. Test in a non-production resource group initially
3. Review job logs in Azure Portal after each run

### Monitoring
1. Enable diagnostic logging on Automation Account
2. Set up Azure Monitor alerts for failed jobs
3. Regularly review job output for errors or warnings

### Security
1. Use managed identity instead of stored credentials
2. Apply principle of least privilege to RBAC assignments
3. Rotate webhook URLs periodically
4. Never commit webhook URLs to source control

### Cost Management
1. Monitor snapshot storage costs (prune regularly)
2. Verify VM sizing schedules match actual business hours
3. Use resource group scoping in non-production to limit blast radius

---

## Disclaimer

**IMPORTANT: USE AT YOUR OWN RISK**

The PowerShell runbooks, scripts, and examples provided in this repository are intended for **educational, demonstration, and reference purposes only**.

### No Warranty

These scripts are provided "AS IS" without warranty of any kind, either express or implied, including but not limited to warranties of merchantability, fitness for a particular purpose, and non-infringement. The entire risk as to the quality and performance of these scripts is with you.

### No Liability

In no event shall the authors, contributors, or copyright holders be liable for any claim, damages, or other liability, whether in an action of contract, tort, or otherwise, arising from, out of, or in connection with the use of these scripts or the performance or other dealings in these scripts.

### Your Responsibility

By using these runbooks, you acknowledge and agree that:

- You are solely responsible for testing in your own environment
- You understand the operations these scripts perform (resize VMs, delete resources, create snapshots)
- You will implement appropriate safety controls and approval processes
- You will verify RBAC permissions are appropriately scoped
- You have proper backup and disaster recovery procedures in place
- You will not hold the authors responsible for any data loss, service interruption, unexpected costs, or other damages

### Recommendation

Before using any of these runbooks in production:
1. Thoroughly test in a non-production environment
2. Review and understand all code
3. Customize parameters and safety controls for your needs
4. Implement proper change management and approval workflows
5. Ensure you have backups and rollback procedures
6. Verify compliance with your organization's policies

**These examples are starting points - adapt them to your specific requirements and risk tolerance.**

---

## Additional Resources

- [Azure Automation Documentation](https://docs.microsoft.com/azure/automation/)
- [Azure PowerShell Documentation](https://docs.microsoft.com/powershell/azure/)
- [Runbook Best Practices](https://docs.microsoft.com/azure/automation/automation-runbook-execution)
- [Managed Identity Overview](https://docs.microsoft.com/azure/active-directory/managed-identities-azure-resources/overview)

---

## License

This repository is provided for educational purposes. Please ensure any use complies with your organization's policies and Microsoft's Azure terms of service.
