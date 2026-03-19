# ============================================================
#  Azure Enumeration Script
#  Usage: .\azure_enum.ps1
#  Requires: python -m azure.cli (already logged in)
# ============================================================

$az = "python -m azure.cli"
$output_dir = ".\azure_enum_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
New-Item -ItemType Directory -Path $output_dir | Out-Null

function Run-Az {
    param([string]$args_str, [string]$label)
    Write-Host "[*] $label..." -ForegroundColor Cyan
    $result = Invoke-Expression "$az $args_str 2>$null"
    if ($result) {
        $result | Out-File "$output_dir\$($label -replace ' ','_').txt"
        return $result
    } else {
        Write-Host "    [-] No results or insufficient permissions" -ForegroundColor DarkGray
        return $null
    }
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
$subs = Invoke-Expression "$az account list 2>$null" | ConvertFrom-Json
$subs | Format-Table name, id, state -AutoSize
$subs | ConvertTo-Json | Out-File "$output_dir\01_subscriptions.json"

Write-Host "`n[+] Found $($subs.Count) subscription(s)`n" -ForegroundColor Yellow

# Iterate over each subscription
foreach ($sub in $subs) {
    $sub_id = $sub.id
    $sub_name = $sub.name -replace '[^\w]', '_'

    Write-Host "`n[>>] Subscription: $($sub.name) [$sub_id]" -ForegroundColor Magenta
    Invoke-Expression "$az account set --subscription $sub_id 2>$null"

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

    $vms = Invoke-Expression "$az vm list --output json 2>$null" | ConvertFrom-Json
    $vms | ConvertTo-Json | Out-File "$output_dir\${sub_name}_05_vms.json"
    Run-Az "vm list-ip-addresses --output json" "${sub_name}_05_vm_ips"

    foreach ($vm in $vms) {
        $vmname = $vm.name
        $rg = $vm.resourceGroup
        Write-Host "    [vm] $vmname ($rg)" -ForegroundColor DarkCyan
        Invoke-Expression "$az vm get-instance-view --name $vmname --resource-group $rg --output json 2>$null" |
            Out-File "$output_dir\${sub_name}_05_vm_${vmname}_detail.json"
    }

    # --------------------------------------------------------
    # 6. NETWORKING
    # --------------------------------------------------------
    Write-Host "  [+] NETWORKING" -ForegroundColor Green

    Run-Az "network vnet list --output json" "${sub_name}_06_vnets"
    Run-Az "network public-ip list --output json" "${sub_name}_06_public_ips"
    Run-Az "network nsg list --output json" "${sub_name}_06_nsgs"

    $nsgs = Invoke-Expression "$az network nsg list --output json 2>$null" | ConvertFrom-Json
    foreach ($nsg in $nsgs) {
        $nsgname = $nsg.name
        $rg = $nsg.resourceGroup
        Write-Host "    [nsg] $nsgname" -ForegroundColor DarkCyan
        Invoke-Expression "$az network nsg rule list --nsg-name $nsgname --resource-group $rg --output json 2>$null" |
            Out-File "$output_dir\${sub_name}_06_nsg_${nsgname}_rules.json"
    }

    # --------------------------------------------------------
    # 7. STORAGE
    # --------------------------------------------------------
    Write-Host "  [+] STORAGE ACCOUNTS" -ForegroundColor Green

    $storages = Invoke-Expression "$az storage account list --output json 2>$null" | ConvertFrom-Json
    $storages | ConvertTo-Json | Out-File "$output_dir\${sub_name}_07_storage_accounts.json"

    foreach ($sa in $storages) {
        $saname = $sa.name
        Write-Host "    [storage] $saname" -ForegroundColor DarkCyan
        # Try to list containers
        Invoke-Expression "$az storage container list --account-name $saname --auth-mode login --output json 2>$null" |
            Out-File "$output_dir\${sub_name}_07_storage_${saname}_containers.json"
        # Check public access setting
        Invoke-Expression "$az storage account show --name $saname --query 'allowBlobPublicAccess' --output tsv 2>$null" |
            Out-File "$output_dir\${sub_name}_07_storage_${saname}_publicaccess.txt"
    }

    # --------------------------------------------------------
    # 8. KEY VAULTS
    # --------------------------------------------------------
    Write-Host "  [+] KEY VAULTS" -ForegroundColor Green

    $vaults = Invoke-Expression "$az keyvault list --output json 2>$null" | ConvertFrom-Json
    $vaults | ConvertTo-Json | Out-File "$output_dir\${sub_name}_08_keyvaults.json"

    foreach ($vault in $vaults) {
        $vname = $vault.name
        Write-Host "    [vault] $vname" -ForegroundColor DarkCyan
        Invoke-Expression "$az keyvault secret list --vault-name $vname --output json 2>$null" |
            Out-File "$output_dir\${sub_name}_08_vault_${vname}_secrets.json"
        Invoke-Expression "$az keyvault key list --vault-name $vname --output json 2>$null" |
            Out-File "$output_dir\${sub_name}_08_vault_${vname}_keys.json"
        Invoke-Expression "$az keyvault certificate list --vault-name $vname --output json 2>$null" |
            Out-File "$output_dir\${sub_name}_08_vault_${vname}_certs.json"
    }

    # --------------------------------------------------------
    # 9. WEB APPS & FUNCTION APPS (look for credentials in appsettings)
    # --------------------------------------------------------
    Write-Host "  [+] WEB APPS & FUNCTIONS" -ForegroundColor Green

    $webapps = Invoke-Expression "$az webapp list --output json 2>$null" | ConvertFrom-Json
    $webapps | ConvertTo-Json | Out-File "$output_dir\${sub_name}_09_webapps.json"

    foreach ($app in $webapps) {
        $appname = $app.name
        $rg = $app.resourceGroup
        Write-Host "    [webapp] $appname" -ForegroundColor DarkCyan
        Invoke-Expression "$az webapp config appsettings list --name $appname --resource-group $rg --output json 2>$null" |
            Out-File "$output_dir\${sub_name}_09_webapp_${appname}_appsettings.json"
        Invoke-Expression "$az webapp config connection-string list --name $appname --resource-group $rg --output json 2>$null" |
            Out-File "$output_dir\${sub_name}_09_webapp_${appname}_connstrings.json"
    }

    $funcapps = Invoke-Expression "$az functionapp list --output json 2>$null" | ConvertFrom-Json
    $funcapps | ConvertTo-Json | Out-File "$output_dir\${sub_name}_09_functionapps.json"

    foreach ($func in $funcapps) {
        $fname = $func.name
        $rg = $func.resourceGroup
        Write-Host "    [func] $fname" -ForegroundColor DarkCyan
        Invoke-Expression "$az functionapp config appsettings list --name $fname --resource-group $rg --output json 2>$null" |
            Out-File "$output_dir\${sub_name}_09_func_${fname}_appsettings.json"
    }

    # --------------------------------------------------------
    # 10. SQL SERVERS & DATABASES
    # --------------------------------------------------------
    Write-Host "  [+] SQL SERVERS" -ForegroundColor Green

    $sqlservers = Invoke-Expression "$az sql server list --output json 2>$null" | ConvertFrom-Json
    $sqlservers | ConvertTo-Json | Out-File "$output_dir\${sub_name}_10_sql_servers.json"

    foreach ($srv in $sqlservers) {
        $srvname = $srv.name
        $rg = $srv.resourceGroup
        Write-Host "    [sql] $srvname" -ForegroundColor DarkCyan
        Invoke-Expression "$az sql db list --server $srvname --resource-group $rg --output json 2>$null" |
            Out-File "$output_dir\${sub_name}_10_sql_${srvname}_dbs.json"
        Invoke-Expression "$az sql server firewall-rule list --server $srvname --resource-group $rg --output json 2>$null" |
            Out-File "$output_dir\${sub_name}_10_sql_${srvname}_firewall.json"
    }

    # --------------------------------------------------------
    # 11. AUTOMATION ACCOUNTS (runbooks may contain hardcoded creds)
    # --------------------------------------------------------
    Write-Host "  [+] AUTOMATION ACCOUNTS" -ForegroundColor Green

    $automations = Invoke-Expression "$az automation account list --output json 2>$null" | ConvertFrom-Json
    $automations | ConvertTo-Json | Out-File "$output_dir\${sub_name}_11_automation_accounts.json"

    foreach ($auto in $automations) {
        $autoname = $auto.name
        $rg = $auto.resourceGroup
        Write-Host "    [automation] $autoname" -ForegroundColor DarkCyan
        Invoke-Expression "$az automation runbook list --automation-account-name $autoname --resource-group $rg --output json 2>$null" |
            Out-File "$output_dir\${sub_name}_11_auto_${autoname}_runbooks.json"
        Invoke-Expression "$az automation credential list --automation-account-name $autoname --resource-group $rg --output json 2>$null" |
            Out-File "$output_dir\${sub_name}_11_auto_${autoname}_credentials.json"
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
