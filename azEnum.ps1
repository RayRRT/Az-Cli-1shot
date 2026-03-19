# ============================================================
#  Azure Enumeration Script
#  Usage: .\azure_enum.ps1
#  Requires: python -m azure.cli (already logged in)
# ============================================================

$az = "python -m azure.cli"
$output_dir = ".\azure_enum_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
New-Item -ItemType Directory -Path $output_dir | Out-Null

# Helper: run an az command silently and save output to file
function Run-Az {
    param([string]$args_str, [string]$label)
    Write-Host "[*] $label..." -ForegroundColor Cyan
    $result = (Invoke-Expression "$az $args_str") 2>&1 | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }
    if ($result) {
        $result | Out-File "$output_dir\$($label -replace ' ','_').txt"
        return $result
    } else {
        Write-Host "    [-] No results or insufficient permissions" -ForegroundColor DarkGray
        return $null
    }
}

# Helper: run az and return parsed JSON, suppressing errors
function Run-Az-Json {
    param([string]$args_str)
    try {
        $result = (Invoke-Expression "$az $args_str --output json") 2>&1 | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }
        if ($result) { return ($result | ConvertFrom-Json) }
    } catch {}
    return @()
}

Write-Host "`n=====================================================" -ForegroundColor Yellow
Write-Host "   AZURE ENUMERATION SCRIPT" -ForegroundColor Yellow
Write-Host "   Output -> $output_dir" -ForegroundColor Yellow
Write-Host "=====================================================`n" -ForegroundColor Yellow

# ------------------------------------------------------------
# 1. ACCOUNT & SUBSCRIPTIONS
# ------------------------------------------------------------
Write-Host "[+] ACCOUNT & SUBSCRIPTIONS" -ForegroundColor Green

Run-Az "account show" "01_account_current"
$subs = Run-Az-Json "account list"
$subs | Format-Table name, id, state -AutoSize
$subs | ConvertTo-Json | Out-File "$output_dir\01_subscriptions.json"

Write-Host "`n[+] Found $($subs.Count) subscription(s)`n" -ForegroundColor Yellow

# Iterate over each subscription
foreach ($sub in $subs) {
    $sub_id = $sub.id
    $sub_name = $sub.name -replace '[^\w]', '_'

    Write-Host "`n[>>] Subscription: $($sub.name) [$sub_id]" -ForegroundColor Magenta
    Invoke-Expression "$az account set --subscription $sub_id" 2>&1 | Out-Null

    # --------------------------------------------------------
    # 2. IDENTITY & PERMISSIONS
    # --------------------------------------------------------
    Write-Host "  [+] IDENTITY & PERMISSIONS" -ForegroundColor Green

    Run-Az "role assignment list --all --output json" "${sub_name}_02_role_assignments"
    Run-Az "role definition list --custom-role-only true --output json" "${sub_name}_02_custom_roles"

    # --------------------------------------------------------
    # 3. AZURE AD
    # --------------------------------------------------------
    Write-Host "  [+] AZURE AD" -ForegroundColor Green

    Run-Az "ad user list --output json" "${sub_name}_03_ad_users"
    Run-Az "ad group list --output json" "${sub_name}_03_ad_groups"
    Run-Az "ad sp list --all --output json" "${sub_name}_03_service_principals"
    Run-Az "ad app list --all --output json" "${sub_name}_03_app_registrations"

    # --------------------------------------------------------
    # 4. RESOURCE GROUPS & RESOURCES
    # --------------------------------------------------------
    Write-Host "  [+] RESOURCE GROUPS & RESOURCES" -ForegroundColor Green

    Run-Az "group list --output json" "${sub_name}_04_resource_groups"
    Run-Az "resource list --output json" "${sub_name}_04_all_resources"

    # --------------------------------------------------------
    # 5. COMPUTE (VMs)
    # --------------------------------------------------------
    Write-Host "  [+] VIRTUAL MACHINES" -ForegroundColor Green

    $vms = Run-Az-Json "vm list"
    $vms | ConvertTo-Json | Out-File "$output_dir\${sub_name}_05_vms.json"
    Run-Az "vm list-ip-addresses --output json" "${sub_name}_05_vm_ips"

    foreach ($vm in $vms) {
        $vmname = $vm.name
        $rg = $vm.resourceGroup
        Write-Host "    [vm] $vmname ($rg)" -ForegroundColor DarkCyan
        Run-Az-Json "vm get-instance-view --name $vmname --resource-group $rg" |
            ConvertTo-Json | Out-File "$output_dir\${sub_name}_05_vm_${vmname}_detail.json"
    }

    # --------------------------------------------------------
    # 6. NETWORKING
    # --------------------------------------------------------
    Write-Host "  [+] NETWORKING" -ForegroundColor Green

    Run-Az "network vnet list --output json" "${sub_name}_06_vnets"
    Run-Az "network public-ip list --output json" "${sub_name}_06_public_ips"
    Run-Az "network nsg list --output json" "${sub_name}_06_nsgs"

    $nsgs = Run-Az-Json "network nsg list"
    foreach ($nsg in $nsgs) {
        $nsgname = $nsg.name
        $rg = $nsg.resourceGroup
        Write-Host "    [nsg] $nsgname" -ForegroundColor DarkCyan
        Run-Az "network nsg rule list --nsg-name $nsgname --resource-group $rg --output json" "${sub_name}_06_nsg_${nsgname}_rules"
    }

    # --------------------------------------------------------
    # 7. STORAGE
    # --------------------------------------------------------
    Write-Host "  [+] STORAGE ACCOUNTS" -ForegroundColor Green

    $storages = Run-Az-Json "storage account list"
    $storages | ConvertTo-Json | Out-File "$output_dir\${sub_name}_07_storage_accounts.json"

    foreach ($sa in $storages) {
        $saname = $sa.name
        Write-Host "    [storage] $saname" -ForegroundColor DarkCyan
        # Try to list containers
        Run-Az "storage container list --account-name $saname --auth-mode login --output json" "${sub_name}_07_storage_${saname}_containers"
        # Check public access setting
        Run-Az "storage account show --name $saname --query allowBlobPublicAccess --output tsv" "${sub_name}_07_storage_${saname}_publicaccess"
    }

    # --------------------------------------------------------
    # 8. KEY VAULTS
    # --------------------------------------------------------
    Write-Host "  [+] KEY VAULTS" -ForegroundColor Green

    $vaults = Run-Az-Json "keyvault list"
    $vaults | ConvertTo-Json | Out-File "$output_dir\${sub_name}_08_keyvaults.json"

    foreach ($vault in $vaults) {
        $vname = $vault.name
        Write-Host "    [vault] $vname" -ForegroundColor DarkCyan
        Run-Az "keyvault secret list --vault-name $vname --output json" "${sub_name}_08_vault_${vname}_secrets"
        Run-Az "keyvault key list --vault-name $vname --output json" "${sub_name}_08_vault_${vname}_keys"
        Run-Az "keyvault certificate list --vault-name $vname --output json" "${sub_name}_08_vault_${vname}_certs"
    }

    # --------------------------------------------------------
    # 9. WEB APPS & FUNCTION APPS (look for credentials in appsettings)
    # --------------------------------------------------------
    Write-Host "  [+] WEB APPS & FUNCTIONS" -ForegroundColor Green

    $webapps = Run-Az-Json "webapp list"
    $webapps | ConvertTo-Json | Out-File "$output_dir\${sub_name}_09_webapps.json"

    foreach ($app in $webapps) {
        $appname = $app.name
        $rg = $app.resourceGroup
        Write-Host "    [webapp] $appname" -ForegroundColor DarkCyan
        Run-Az "webapp config appsettings list --name $appname --resource-group $rg --output json" "${sub_name}_09_webapp_${appname}_appsettings"
        Run-Az "webapp config connection-string list --name $appname --resource-group $rg --output json" "${sub_name}_09_webapp_${appname}_connstrings"
    }

    $funcapps = Run-Az-Json "functionapp list"
    $funcapps | ConvertTo-Json | Out-File "$output_dir\${sub_name}_09_functionapps.json"

    foreach ($func in $funcapps) {
        $fname = $func.name
        $rg = $func.resourceGroup
        Write-Host "    [func] $fname" -ForegroundColor DarkCyan
        Run-Az "functionapp config appsettings list --name $fname --resource-group $rg --output json" "${sub_name}_09_func_${fname}_appsettings"
    }

    # --------------------------------------------------------
    # 10. SQL SERVERS & DATABASES
    # --------------------------------------------------------
    Write-Host "  [+] SQL SERVERS" -ForegroundColor Green

    $sqlservers = Run-Az-Json "sql server list"
    $sqlservers | ConvertTo-Json | Out-File "$output_dir\${sub_name}_10_sql_servers.json"

    foreach ($srv in $sqlservers) {
        $srvname = $srv.name
        $rg = $srv.resourceGroup
        Write-Host "    [sql] $srvname" -ForegroundColor DarkCyan
        Run-Az "sql db list --server $srvname --resource-group $rg --output json" "${sub_name}_10_sql_${srvname}_dbs"
        Run-Az "sql server firewall-rule list --server $srvname --resource-group $rg --output json" "${sub_name}_10_sql_${srvname}_firewall"
    }

    # --------------------------------------------------------
    # 11. AUTOMATION ACCOUNTS (runbooks may contain hardcoded creds)
    # --------------------------------------------------------
    Write-Host "  [+] AUTOMATION ACCOUNTS" -ForegroundColor Green

    $automations = Run-Az-Json "automation account list"
    $automations | ConvertTo-Json | Out-File "$output_dir\${sub_name}_11_automation_accounts.json"

    foreach ($auto in $automations) {
        $autoname = $auto.name
        $rg = $auto.resourceGroup
        Write-Host "    [automation] $autoname" -ForegroundColor DarkCyan
        Run-Az "automation runbook list --automation-account-name $autoname --resource-group $rg --output json" "${sub_name}_11_auto_${autoname}_runbooks"
        Run-Az "automation credential list --automation-account-name $autoname --resource-group $rg --output json" "${sub_name}_11_auto_${autoname}_credentials"
    }

    # --------------------------------------------------------
    # 12. CONTAINER REGISTRY & AKS
    # --------------------------------------------------------
    Write-Host "  [+] CONTAINERS (ACR & AKS)" -ForegroundColor Green

    Run-Az "acr list --output json" "${sub_name}_12_container_registries"
    Run-Az "aks list --output json" "${sub_name}_12_aks_clusters"
}

# ------------------------------------------------------------
# FINAL SUMMARY
# ------------------------------------------------------------
Write-Host "`n=====================================================" -ForegroundColor Yellow
Write-Host "   ENUMERATION COMPLETE" -ForegroundColor Green
Write-Host "   Output saved to: $output_dir" -ForegroundColor Yellow
Write-Host "=====================================================`n" -ForegroundColor Yellow

# List files with actual content (non-empty)
Write-Host "[+] Files with data:" -ForegroundColor Green
Get-ChildItem $output_dir | Where-Object { $_.Length -gt 10 } |
    Select-Object Name, @{N='Size';E={"{0:N0} bytes" -f $_.Length}} |
    Format-Table -AutoSize
