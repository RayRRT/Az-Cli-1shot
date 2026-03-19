# ============================================================
#  Azure Enumeration Script
#  Usage: .\azure_enum.ps1
#  Requires: python -m azure.cli (already logged in)
# ============================================================

$az         = "python -m azure.cli"
$timestamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
$output_dir = ".\azure_enum_$timestamp"
New-Item -ItemType Directory -Path $output_dir | Out-Null

# Global graph structures
$global:gNodes   = [System.Collections.Generic.List[hashtable]]::new()
$global:gLinks   = [System.Collections.Generic.List[hashtable]]::new()
$global:gNodeIds = @{}

# ============================================================
# HELPERS
# ============================================================

function Run-Az-Json {
    param([string]$cmd)
    try {
        $r = (Invoke-Expression "$script:az $cmd --output json") 2>&1 |
             Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }
        if ($r) { return ($r | ConvertFrom-Json) }
    } catch {}
    return @()
}

function GNode {
    param([string]$id,[string]$label,[string]$type,[string]$sub="")
    if (-not $global:gNodeIds.ContainsKey($id)) {
        $global:gNodeIds[$id] = $true
        $global:gNodes.Add(@{ id=$id; label=$label; type=$type; sub=$sub })
    }
}

function GLink {
    param([string]$src,[string]$tgt,[string]$rel)
    $global:gLinks.Add(@{ source=$src; target=$tgt; rel=$rel })
}

# ============================================================
# COLLECT DATA
# ============================================================
Write-Host "`n================================================" -ForegroundColor Yellow
Write-Host "  AZURE ENUMERATION SCRIPT" -ForegroundColor Yellow
Write-Host "  Output -> $output_dir" -ForegroundColor Yellow
Write-Host "================================================`n" -ForegroundColor Yellow

Add-Type -AssemblyName System.Web

# Subscriptions
Write-Host "[+] SUBSCRIPTIONS" -ForegroundColor Green
$subs = Run-Az-Json "account list"
$subs | Format-Table name, id, state -AutoSize
$subs | ConvertTo-Json | Out-File "$output_dir\01_subscriptions.json"
Write-Host "[+] Found $($subs.Count) subscription(s)`n" -ForegroundColor Yellow

foreach ($sub in $subs) {
    GNode -id ("sub_" + $sub.id) -label $sub.name -type "subscription" -sub $sub.name
}

foreach ($sub in $subs) {
    $sub_id   = $sub.id
    $sub_name = $sub.name -replace '\W','_'
    $sub_nid  = "sub_" + $sub_id

    Write-Host "`n[>>] Subscription: $($sub.name)" -ForegroundColor Magenta
    Invoke-Expression "$az account set --subscription $sub_id" 2>&1 | Out-Null

    # --- ROLES ---
    Write-Host "  [+] ROLES" -ForegroundColor Green
    $roles = Run-Az-Json "role assignment list --all"
    $roles | ConvertTo-Json | Out-File "$output_dir\${sub_name}_roles.json"
    foreach ($r in $roles) {
        $rid = "role_" + ($r.roleDefinitionName -replace '\W','_')
        GNode -id $rid -label $r.roleDefinitionName -type "role" -sub $sub.name
        if ($r.principalName) {
            $pt  = ($r.principalType + "").ToLower() -replace 'serviceprincipals','sp' -replace 'users','user' -replace 'groups','group'
            $pid = "princ_" + ($r.principalName -replace '\W','_')
            GNode -id $pid -label $r.principalName -type $pt -sub $sub.name
            GLink -src $pid -tgt $rid -rel "hasRole"
        }
    }

    # --- AZURE AD ---
    Write-Host "  [+] AZURE AD" -ForegroundColor Green
    $users = Run-Az-Json "ad user list"
    $users | ConvertTo-Json | Out-File "$output_dir\${sub_name}_users.json"
    foreach ($u in $users) {
        $uid = "user_" + ($u.userPrincipalName -replace '\W','_')
        GNode -id $uid -label $u.displayName -type "user" -sub $sub.name
        GLink -src $sub_nid -tgt $uid -rel "contains"
    }

    $groups = Run-Az-Json "ad group list"
    $groups | ConvertTo-Json | Out-File "$output_dir\${sub_name}_groups.json"
    foreach ($gr in $groups) {
        $gid = "group_" + ($gr.id -replace '\W','_')
        GNode -id $gid -label $gr.displayName -type "group" -sub $sub.name
        GLink -src $sub_nid -tgt $gid -rel "contains"
        $members = Run-Az-Json "ad group member list --group $($gr.id)"
        foreach ($m in $members) {
            $mid = "user_" + ($m.userPrincipalName -replace '\W','_')
            GNode -id $mid -label $m.displayName -type "user" -sub $sub.name
            GLink -src $mid -tgt $gid -rel "memberOf"
        }
    }

    $sps = Run-Az-Json "ad sp list --all"
    $sps | ConvertTo-Json | Out-File "$output_dir\${sub_name}_sps.json"
    foreach ($sp in $sps) {
        $spid = "sp_" + ($sp.appId -replace '\W','_')
        GNode -id $spid -label $sp.displayName -type "sp" -sub $sub.name
        GLink -src $sub_nid -tgt $spid -rel "contains"
    }

    $apps = Run-Az-Json "ad app list --all"
    $apps | ConvertTo-Json | Out-File "$output_dir\${sub_name}_apps.json"

    # --- RESOURCE GROUPS ---
    Write-Host "  [+] RESOURCE GROUPS" -ForegroundColor Green
    $rgs = Run-Az-Json "group list"
    $rgs | ConvertTo-Json | Out-File "$output_dir\${sub_name}_rgs.json"
    foreach ($rg in $rgs) {
        $rgid = "rg_" + ($rg.name -replace '\W','_') + "_" + ($sub_id -replace '\W','_')
        GNode -id $rgid -label $rg.name -type "rg" -sub $sub.name
        GLink -src $sub_nid -tgt $rgid -rel "contains"
    }

    $resources = Run-Az-Json "resource list"
    $resources | ConvertTo-Json | Out-File "$output_dir\${sub_name}_resources.json"

    # --- VMs ---
    Write-Host "  [+] VIRTUAL MACHINES" -ForegroundColor Green
    $vms = Run-Az-Json "vm list"
    $vms | ConvertTo-Json | Out-File "$output_dir\${sub_name}_vms.json"
    foreach ($vm in $vms) {
        $vmid = "vm_" + ($vm.name -replace '\W','_')
        $rgid = "rg_" + ($vm.resourceGroup -replace '\W','_') + "_" + ($sub_id -replace '\W','_')
        GNode -id $vmid -label $vm.name -type "vm" -sub $sub.name
        GLink -src $rgid -tgt $vmid -rel "contains"
    }
    $vm_ips = Run-Az-Json "vm list-ip-addresses"
    $vm_ips | ConvertTo-Json | Out-File "$output_dir\${sub_name}_vm_ips.json"

    # --- NETWORKING ---
    Write-Host "  [+] NETWORKING" -ForegroundColor Green
    $vnets = Run-Az-Json "network vnet list"
    $vnets | ConvertTo-Json | Out-File "$output_dir\${sub_name}_vnets.json"
    $pips  = Run-Az-Json "network public-ip list"
    $pips  | ConvertTo-Json | Out-File "$output_dir\${sub_name}_pips.json"
    $nsgs  = Run-Az-Json "network nsg list"
    $nsgs  | ConvertTo-Json | Out-File "$output_dir\${sub_name}_nsgs.json"
    foreach ($nsg in $nsgs) {
        $rules = Run-Az-Json "network nsg rule list --nsg-name $($nsg.name) --resource-group $($nsg.resourceGroup)"
        $rules | ConvertTo-Json | Out-File "$output_dir\${sub_name}_nsg_$($nsg.name -replace '\W','_')_rules.json"
    }

    # --- STORAGE ---
    Write-Host "  [+] STORAGE" -ForegroundColor Green
    $storages = Run-Az-Json "storage account list"
    $storages | ConvertTo-Json | Out-File "$output_dir\${sub_name}_storage.json"
    foreach ($sa in $storages) {
        $said = "storage_" + ($sa.name -replace '\W','_')
        $rgid = "rg_" + ($sa.resourceGroup -replace '\W','_') + "_" + ($sub_id -replace '\W','_')
        GNode -id $said -label $sa.name -type "storage" -sub $sub.name
        GLink -src $rgid -tgt $said -rel "contains"
        $containers = Run-Az-Json "storage container list --account-name $($sa.name) --auth-mode login"
        $containers | ConvertTo-Json | Out-File "$output_dir\${sub_name}_containers_$($sa.name).json"
    }

    # --- KEY VAULTS ---
    Write-Host "  [+] KEY VAULTS" -ForegroundColor Green
    $vaults = Run-Az-Json "keyvault list"
    $vaults | ConvertTo-Json | Out-File "$output_dir\${sub_name}_keyvaults.json"
    foreach ($vault in $vaults) {
        $kvid = "kv_" + ($vault.name -replace '\W','_')
        $rgid = "rg_" + ($vault.resourceGroup -replace '\W','_') + "_" + ($sub_id -replace '\W','_')
        GNode -id $kvid -label $vault.name -type "keyvault" -sub $sub.name
        GLink -src $rgid -tgt $kvid -rel "contains"
        $secrets = Run-Az-Json "keyvault secret list --vault-name $($vault.name)"
        $secrets | ConvertTo-Json | Out-File "$output_dir\${sub_name}_secrets_$($vault.name).json"
        foreach ($r in $roles) {
            if ($r.scope -match $vault.name -and $r.principalName) {
                $pid = "princ_" + ($r.principalName -replace '\W','_')
                GLink -src $pid -tgt $kvid -rel "accessTo"
            }
        }
    }

    # --- WEB APPS ---
    Write-Host "  [+] WEB APPS & FUNCTIONS" -ForegroundColor Green
    $webapps = Run-Az-Json "webapp list"
    $webapps | ConvertTo-Json | Out-File "$output_dir\${sub_name}_webapps.json"
    foreach ($app in $webapps) {
        $waid = "webapp_" + ($app.name -replace '\W','_')
        $rgid = "rg_" + ($app.resourceGroup -replace '\W','_') + "_" + ($sub_id -replace '\W','_')
        GNode -id $waid -label $app.name -type "webapp" -sub $sub.name
        GLink -src $rgid -tgt $waid -rel "contains"
        $settings = Run-Az-Json "webapp config appsettings list --name $($app.name) --resource-group $($app.resourceGroup)"
        $settings | ConvertTo-Json | Out-File "$output_dir\${sub_name}_appsettings_$($app.name -replace '\W','_').json"
    }
    $funcapps = Run-Az-Json "functionapp list"
    $funcapps | ConvertTo-Json | Out-File "$output_dir\${sub_name}_funcapps.json"
    foreach ($func in $funcapps) {
        $fsettings = Run-Az-Json "functionapp config appsettings list --name $($func.name) --resource-group $($func.resourceGroup)"
        $fsettings | ConvertTo-Json | Out-File "$output_dir\${sub_name}_funcsettings_$($func.name -replace '\W','_').json"
    }

    # --- SQL ---
    Write-Host "  [+] SQL" -ForegroundColor Green
    $sqlservers = Run-Az-Json "sql server list"
    $sqlservers | ConvertTo-Json | Out-File "$output_dir\${sub_name}_sql.json"
    foreach ($srv in $sqlservers) {
        $sqlid = "sql_" + ($srv.name -replace '\W','_')
        $rgid  = "rg_" + ($srv.resourceGroup -replace '\W','_') + "_" + ($sub_id -replace '\W','_')
        GNode -id $sqlid -label $srv.name -type "sql" -sub $sub.name
        GLink -src $rgid -tgt $sqlid -rel "contains"
        $fwrules = Run-Az-Json "sql server firewall-rule list --server $($srv.name) --resource-group $($srv.resourceGroup)"
        $fwrules | ConvertTo-Json | Out-File "$output_dir\${sub_name}_sqlfirewall_$($srv.name -replace '\W','_').json"
    }

    # --- AUTOMATION ---
    Write-Host "  [+] AUTOMATION" -ForegroundColor Green
    $automations = Run-Az-Json "automation account list"
    $automations | ConvertTo-Json | Out-File "$output_dir\${sub_name}_automation.json"
    foreach ($auto in $automations) {
        $autoid = "auto_" + ($auto.name -replace '\W','_')
        $rgid   = "rg_" + ($auto.resourceGroup -replace '\W','_') + "_" + ($sub_id -replace '\W','_')
        GNode -id $autoid -label $auto.name -type "automation" -sub $sub.name
        GLink -src $rgid -tgt $autoid -rel "contains"
        $runbooks = Run-Az-Json "automation runbook list --automation-account-name $($auto.name) --resource-group $($auto.resourceGroup)"
        $runbooks | ConvertTo-Json | Out-File "$output_dir\${sub_name}_runbooks_$($auto.name -replace '\W','_').json"
    }

    # --- CONTAINERS ---
    Write-Host "  [+] CONTAINERS" -ForegroundColor Green
    $acrs = Run-Az-Json "acr list"
    $acrs | ConvertTo-Json | Out-File "$output_dir\${sub_name}_acr.json"
    foreach ($acr in $acrs) {
        $acrid = "acr_" + ($acr.name -replace '\W','_')
        $rgid  = "rg_" + ($acr.resourceGroup -replace '\W','_') + "_" + ($sub_id -replace '\W','_')
        GNode -id $acrid -label $acr.name -type "acr" -sub $sub.name
        GLink -src $rgid -tgt $acrid -rel "contains"
    }
    $aks = Run-Az-Json "aks list"
    $aks | ConvertTo-Json | Out-File "$output_dir\${sub_name}_aks.json"
    foreach ($ak in $aks) {
        $aksid = "aks_" + ($ak.name -replace '\W','_')
        $rgid  = "rg_" + ($ak.resourceGroup -replace '\W','_') + "_" + ($sub_id -replace '\W','_')
        GNode -id $aksid -label $ak.name -type "aks" -sub $sub.name
        GLink -src $rgid -tgt $aksid -rel "contains"
    }
}

# ============================================================
# SERIALIZE GRAPH DATA TO JSON FILES
# ============================================================
$global:gNodes | ConvertTo-Json | Out-File "$output_dir\graph_nodes.json" -Encoding utf8
$global:gLinks | ConvertTo-Json | Out-File "$output_dir\graph_links.json" -Encoding utf8

# ============================================================
# CALL HTML GENERATOR
# ============================================================
Write-Host "`n[+] Generating HTML reports..." -ForegroundColor Cyan
& "$PSScriptRoot\azure_enum_html.ps1" -output_dir $output_dir

Write-Host "`n================================================" -ForegroundColor Yellow
Write-Host "  ENUMERATION COMPLETE" -ForegroundColor Green
Write-Host "  Folder : $output_dir" -ForegroundColor Yellow
Write-Host "  Nodes  : $($global:gNodes.Count)  Links: $($global:gLinks.Count)" -ForegroundColor White
Write-Host "================================================`n" -ForegroundColor Yellow

Start-Process "$output_dir\report.html"

Get-ChildItem $output_dir | Where-Object { $_.Length -gt 10 } |
    Select-Object Name, @{N='Size';E={"{0:N0} bytes" -f $_.Length}} |
    Format-Table -AutoSize
