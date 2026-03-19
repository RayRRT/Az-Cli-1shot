# ============================================================
#  Azure Enumeration Script  -  Single file version
#  Usage: .\azure_enum.ps1
#  Requires: az CLI (native) OR python -m azure.cli (already logged in)
#  Output:   <output_dir>\report.html  +  graph.html
# ============================================================

# Auto-detect: use native az if available, otherwise fall back to python module
if (Get-Command az -ErrorAction SilentlyContinue) {
    $az = "az"
    Write-Host "[*] Using native az CLI" -ForegroundColor DarkGray
} else {
    $az = "python -m azure.cli"
    Write-Host "[*] Using python -m azure.cli" -ForegroundColor DarkGray
}
$timestamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
$output_dir = (Join-Path (Get-Location).Path "azure_enum_$timestamp")
New-Item -ItemType Directory -Path $output_dir -Force | Out-Null

Add-Type -AssemblyName System.Web

# Graph structures
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

function HtmlEnc {
    param([string]$s)
    return [System.Web.HttpUtility]::HtmlEncode($s)
}

function Make-Table {
    param([object]$items, [string[]]$fields)
    $warn = '0\.0\.0\.0|Owner|Contributor|admin|password|secret'
    $hdrs = ($fields | ForEach-Object { "<th>$_</th>" }) -join ""
    if (-not $items -or ($items | Measure-Object).Count -eq 0) {
        return "<table><thead><tr>$hdrs</tr></thead><tbody><tr><td colspan='$($fields.Count)' style='color:#666;font-style:italic'>No data</td></tr></tbody></table>"
    }
    $rows = ""
    foreach ($item in $items) {
        $rows += "<tr>"
        foreach ($f in $fields) {
            $val = "$($item.$f)"
            if (-not $val -or $val -eq "") { $val = "-" }
            $cls = if ($val -match $warn -and $val -notmatch '^false$') { " class='w'" } else { "" }
            $rows += "<td$cls>$(HtmlEnc $val)</td>"
        }
        $rows += "</tr>"
    }
    return "<table><thead><tr>$hdrs</tr></thead><tbody>$rows</tbody></table>"
}

# ============================================================
# ENUMERATE
# ============================================================

Write-Host "`n================================================" -ForegroundColor Yellow
Write-Host "  AZURE ENUMERATION SCRIPT" -ForegroundColor Yellow
Write-Host "  Output -> $output_dir" -ForegroundColor Yellow
Write-Host "================================================`n" -ForegroundColor Yellow

Write-Host "[+] SUBSCRIPTIONS" -ForegroundColor Green
$subs = Run-Az-Json "account list"
$subs | Format-Table name, id, state -AutoSize
$subs | ConvertTo-Json | Out-File "$output_dir\01_subscriptions.json"
Write-Host "[+] Found $($subs.Count) subscription(s)`n" -ForegroundColor Yellow

foreach ($sub in $subs) {
    GNode -id ("sub_" + $sub.id) -label $sub.name -type "subscription" -sub $sub.name
}

# Store all collected data keyed by subscription for report
$report_data = [ordered]@{}

foreach ($sub in $subs) {
    $sub_id   = $sub.id
    $sub_name = $sub.name -replace '\W','_'
    $sub_nid  = "sub_" + $sub_id
    $sn       = $sub.name

    Write-Host "`n[>>] Subscription: $sn" -ForegroundColor Magenta
    Invoke-Expression "$az account set --subscription $sub_id" 2>&1 | Out-Null

    if (-not $report_data.Contains($sn)) { $report_data[$sn] = [ordered]@{} }
    $rd = $report_data[$sn]

    # ROLES
    Write-Host "  [+] ROLES" -ForegroundColor Green
    $roles = Run-Az-Json "role assignment list --all"
    $roles | ConvertTo-Json | Out-File "$output_dir\${sub_name}_roles.json"
    $rd["Role Assignments"] = @{ data=$roles; fields=@("principalName","roleDefinitionName","scope","principalType") }
    foreach ($r in $roles) {
        $rid = "role_" + ($r.roleDefinitionName -replace '\W','_')
        GNode -id $rid -label $r.roleDefinitionName -type "role" -sub $sn
        if ($r.principalName) {
            $pt  = ($r.principalType + "").ToLower() -replace 'serviceprincipals','sp' -replace 'users','user' -replace 'groups','group'
            $pid = "princ_" + ($r.principalName -replace '\W','_')
            GNode -id $pid -label $r.principalName -type $pt -sub $sn
            GLink -src $pid -tgt $rid -rel "hasRole"
        }
    }

    # AZURE AD
    Write-Host "  [+] AZURE AD" -ForegroundColor Green
    $users = Run-Az-Json "ad user list"
    $users | ConvertTo-Json | Out-File "$output_dir\${sub_name}_users.json"
    $rd["AD Users"] = @{ data=$users; fields=@("displayName","userPrincipalName","accountEnabled","userType") }
    foreach ($u in $users) {
        $uid = "user_" + ($u.userPrincipalName -replace '\W','_')
        GNode -id $uid -label $u.displayName -type "user" -sub $sn
        GLink -src $sub_nid -tgt $uid -rel "contains"
    }

    $groups = Run-Az-Json "ad group list"
    $groups | ConvertTo-Json | Out-File "$output_dir\${sub_name}_groups.json"
    $rd["AD Groups"] = @{ data=$groups; fields=@("displayName","description","securityEnabled") }
    foreach ($gr in $groups) {
        $gid = "group_" + ($gr.id -replace '\W','_')
        GNode -id $gid -label $gr.displayName -type "group" -sub $sn
        GLink -src $sub_nid -tgt $gid -rel "contains"
        $members = Run-Az-Json "ad group member list --group $($gr.id)"
        foreach ($m in $members) {
            $mid = "user_" + ($m.userPrincipalName -replace '\W','_')
            GNode -id $mid -label $m.displayName -type "user" -sub $sn
            GLink -src $mid -tgt $gid -rel "memberOf"
        }
    }

    # Service Principals - use -SkipSlowAD to skip, -NoSPAll to run without --all
    if ($SkipSlowAD) {
        Write-Host "  [!] Skipping SP list (-SkipSlowAD)" -ForegroundColor DarkYellow
        $sps = @()
    } else {
        $spFlag = if ($NoSPAll) { "ad sp list --all" } else { "ad sp list" }
        Write-Host "  [+] SERVICE PRINCIPALS ($spFlag) - this may take a while..." -ForegroundColor Green
        $sps = Run-Az-Json $spFlag
        $sps | ConvertTo-Json | Out-File "$output_dir\${sub_name}_sps.json"
    }
    $rd["Service Principals"] = @{ data=$sps; fields=@("displayName","appId","servicePrincipalType") }
    foreach ($sp in $sps) {
        $spid = "sp_" + ($sp.appId -replace '\W','_')
        GNode -id $spid -label $sp.displayName -type "sp" -sub $sn
        GLink -src $sub_nid -tgt $spid -rel "contains"
    }

    # App Registrations - use -SkipSlowAD to skip, -NoSPAll to run without --all
    if ($SkipSlowAD) {
        Write-Host "  [!] Skipping App list (-SkipSlowAD)" -ForegroundColor DarkYellow
        $apps = @()
    } else {
        $appFlag = if ($NoSPAll) { "ad app list --all" } else { "ad app list" }
        Write-Host "  [+] APP REGISTRATIONS ($appFlag) - this may take a while..." -ForegroundColor Green
        $apps = Run-Az-Json $appFlag
        $apps | ConvertTo-Json | Out-File "$output_dir\${sub_name}_apps.json"
    }
    $rd["App Registrations"] = @{ data=$apps; fields=@("displayName","appId","signInAudience") }

    # RESOURCE GROUPS
    Write-Host "  [+] RESOURCE GROUPS" -ForegroundColor Green
    $rgs = Run-Az-Json "group list"
    $rgs | ConvertTo-Json | Out-File "$output_dir\${sub_name}_rgs.json"
    $rd["Resource Groups"] = @{ data=$rgs; fields=@("name","location","provisioningState") }
    foreach ($rg in $rgs) {
        $rgid = "rg_" + ($rg.name -replace '\W','_') + "_" + ($sub_id -replace '\W','_')
        GNode -id $rgid -label $rg.name -type "rg" -sub $sn
        GLink -src $sub_nid -tgt $rgid -rel "contains"
    }

    $resources = Run-Az-Json "resource list"
    $resources | ConvertTo-Json | Out-File "$output_dir\${sub_name}_resources.json"
    $rd["All Resources"] = @{ data=$resources; fields=@("name","type","resourceGroup","location") }

    # VMs
    Write-Host "  [+] VIRTUAL MACHINES" -ForegroundColor Green
    $vms = Run-Az-Json "vm list"
    $vms | ConvertTo-Json | Out-File "$output_dir\${sub_name}_vms.json"
    $rd["Virtual Machines"] = @{ data=$vms; fields=@("name","resourceGroup","location") }
    foreach ($vm in $vms) {
        $vmid = "vm_" + ($vm.name -replace '\W','_')
        $rgid = "rg_" + ($vm.resourceGroup -replace '\W','_') + "_" + ($sub_id -replace '\W','_')
        GNode -id $vmid -label $vm.name -type "vm" -sub $sn
        GLink -src $rgid -tgt $vmid -rel "contains"
    }
    $vm_ips = Run-Az-Json "vm list-ip-addresses"
    $vm_ips | ConvertTo-Json | Out-File "$output_dir\${sub_name}_vm_ips.json"
    $rd["VM IPs"] = @{ data=$vm_ips; fields=@("virtualMachine") }

    # NETWORKING
    Write-Host "  [+] NETWORKING" -ForegroundColor Green
    $vnets = Run-Az-Json "network vnet list"
    $vnets | ConvertTo-Json | Out-File "$output_dir\${sub_name}_vnets.json"
    $rd["Virtual Networks"] = @{ data=$vnets; fields=@("name","resourceGroup","location") }

    $pips = Run-Az-Json "network public-ip list"
    $pips | ConvertTo-Json | Out-File "$output_dir\${sub_name}_pips.json"
    $rd["Public IPs"] = @{ data=$pips; fields=@("name","resourceGroup","ipAddress","publicIPAllocationMethod") }

    $nsgs = Run-Az-Json "network nsg list"
    $nsgs | ConvertTo-Json | Out-File "$output_dir\${sub_name}_nsgs.json"
    $rd["NSGs"] = @{ data=$nsgs; fields=@("name","resourceGroup","location") }
    $all_nsg_rules = @()
    foreach ($nsg in $nsgs) {
        $rules = Run-Az-Json "network nsg rule list --nsg-name $($nsg.name) --resource-group $($nsg.resourceGroup)"
        $rules | ConvertTo-Json | Out-File "$output_dir\${sub_name}_nsg_$($nsg.name -replace '\W','_')_rules.json"
        foreach ($r in $rules) { $r | Add-Member -NotePropertyName "nsgName" -NotePropertyValue $nsg.name -Force }
        $all_nsg_rules += $rules
    }
    $rd["NSG Rules"] = @{ data=$all_nsg_rules; fields=@("nsgName","name","direction","access","protocol","sourceAddressPrefix","destinationPortRange","priority") }

    # STORAGE
    Write-Host "  [+] STORAGE" -ForegroundColor Green
    $storages = Run-Az-Json "storage account list"
    $storages | ConvertTo-Json | Out-File "$output_dir\${sub_name}_storage.json"
    $rd["Storage Accounts"] = @{ data=$storages; fields=@("name","resourceGroup","allowBlobPublicAccess","minimumTlsVersion") }
    $all_containers = @()
    foreach ($sa in $storages) {
        $said = "storage_" + ($sa.name -replace '\W','_')
        $rgid = "rg_" + ($sa.resourceGroup -replace '\W','_') + "_" + ($sub_id -replace '\W','_')
        GNode -id $said -label $sa.name -type "storage" -sub $sn
        GLink -src $rgid -tgt $said -rel "contains"
        $containers = Run-Az-Json "storage container list --account-name $($sa.name) --auth-mode login"
        $containers | ConvertTo-Json | Out-File "$output_dir\${sub_name}_containers_$($sa.name).json"
        foreach ($c in $containers) { $c | Add-Member -NotePropertyName "storageAccount" -NotePropertyValue $sa.name -Force }
        $all_containers += $containers
    }
    $rd["Storage Containers"] = @{ data=$all_containers; fields=@("storageAccount","name","publicAccess","leaseState") }

    # KEY VAULTS
    Write-Host "  [+] KEY VAULTS" -ForegroundColor Green
    $vaults = Run-Az-Json "keyvault list"
    $vaults | ConvertTo-Json | Out-File "$output_dir\${sub_name}_keyvaults.json"
    $rd["Key Vaults"] = @{ data=$vaults; fields=@("name","resourceGroup","location") }
    $all_secrets = @()
    foreach ($vault in $vaults) {
        $kvid = "kv_" + ($vault.name -replace '\W','_')
        $rgid = "rg_" + ($vault.resourceGroup -replace '\W','_') + "_" + ($sub_id -replace '\W','_')
        GNode -id $kvid -label $vault.name -type "keyvault" -sub $sn
        GLink -src $rgid -tgt $kvid -rel "contains"
        $secrets = Run-Az-Json "keyvault secret list --vault-name $($vault.name)"
        $secrets | ConvertTo-Json | Out-File "$output_dir\${sub_name}_secrets_$($vault.name).json"
        foreach ($s in $secrets) { $s | Add-Member -NotePropertyName "vaultName" -NotePropertyValue $vault.name -Force }
        $all_secrets += $secrets
        foreach ($r in $roles) {
            if ($r.scope -match $vault.name -and $r.principalName) {
                $pid = "princ_" + ($r.principalName -replace '\W','_')
                GLink -src $pid -tgt $kvid -rel "accessTo"
            }
        }
    }
    $rd["Key Vault Secrets"] = @{ data=$all_secrets; fields=@("vaultName","name","enabled","contentType") }

    # WEB APPS
    Write-Host "  [+] WEB APPS & FUNCTIONS" -ForegroundColor Green
    $webapps = Run-Az-Json "webapp list"
    $webapps | ConvertTo-Json | Out-File "$output_dir\${sub_name}_webapps.json"
    $rd["Web Apps"] = @{ data=$webapps; fields=@("name","resourceGroup","defaultHostName","state","httpsOnly") }
    $all_appsettings = @()
    foreach ($app in $webapps) {
        $waid = "webapp_" + ($app.name -replace '\W','_')
        $rgid = "rg_" + ($app.resourceGroup -replace '\W','_') + "_" + ($sub_id -replace '\W','_')
        GNode -id $waid -label $app.name -type "webapp" -sub $sn
        GLink -src $rgid -tgt $waid -rel "contains"
        $settings = Run-Az-Json "webapp config appsettings list --name $($app.name) --resource-group $($app.resourceGroup)"
        $settings | ConvertTo-Json | Out-File "$output_dir\${sub_name}_appsettings_$($app.name -replace '\W','_').json"
        foreach ($s in $settings) { $s | Add-Member -NotePropertyName "appName" -NotePropertyValue $app.name -Force }
        $all_appsettings += $settings
    }
    $rd["WebApp AppSettings"] = @{ data=$all_appsettings; fields=@("appName","name","value","slotSetting") }

    $funcapps = Run-Az-Json "functionapp list"
    $funcapps | ConvertTo-Json | Out-File "$output_dir\${sub_name}_funcapps.json"
    $rd["Function Apps"] = @{ data=$funcapps; fields=@("name","resourceGroup","defaultHostName","state") }
    $all_func_settings = @()
    foreach ($func in $funcapps) {
        $fsettings = Run-Az-Json "functionapp config appsettings list --name $($func.name) --resource-group $($func.resourceGroup)"
        $fsettings | ConvertTo-Json | Out-File "$output_dir\${sub_name}_funcsettings_$($func.name -replace '\W','_').json"
        foreach ($s in $fsettings) { $s | Add-Member -NotePropertyName "funcName" -NotePropertyValue $func.name -Force }
        $all_func_settings += $fsettings
    }
    $rd["Function AppSettings"] = @{ data=$all_func_settings; fields=@("funcName","name","value","slotSetting") }

    # SQL
    Write-Host "  [+] SQL" -ForegroundColor Green
    $sqlservers = Run-Az-Json "sql server list"
    $sqlservers | ConvertTo-Json | Out-File "$output_dir\${sub_name}_sql.json"
    $rd["SQL Servers"] = @{ data=$sqlservers; fields=@("name","resourceGroup","fullyQualifiedDomainName","administratorLogin") }
    $all_fw = @()
    foreach ($srv in $sqlservers) {
        $sqlid = "sql_" + ($srv.name -replace '\W','_')
        $rgid  = "rg_" + ($srv.resourceGroup -replace '\W','_') + "_" + ($sub_id -replace '\W','_')
        GNode -id $sqlid -label $srv.name -type "sql" -sub $sn
        GLink -src $rgid -tgt $sqlid -rel "contains"
        $fwrules = Run-Az-Json "sql server firewall-rule list --server $($srv.name) --resource-group $($srv.resourceGroup)"
        $fwrules | ConvertTo-Json | Out-File "$output_dir\${sub_name}_sqlfirewall_$($srv.name -replace '\W','_').json"
        foreach ($r in $fwrules) { $r | Add-Member -NotePropertyName "serverName" -NotePropertyValue $srv.name -Force }
        $all_fw += $fwrules
    }
    $rd["SQL Firewall Rules"] = @{ data=$all_fw; fields=@("serverName","name","startIpAddress","endIpAddress") }

    # AUTOMATION
    Write-Host "  [+] AUTOMATION" -ForegroundColor Green
    $automations = Run-Az-Json "automation account list"
    $automations | ConvertTo-Json | Out-File "$output_dir\${sub_name}_automation.json"
    $rd["Automation Accounts"] = @{ data=$automations; fields=@("name","resourceGroup","location") }
    $all_runbooks = @()
    foreach ($auto in $automations) {
        $autoid = "auto_" + ($auto.name -replace '\W','_')
        $rgid   = "rg_" + ($auto.resourceGroup -replace '\W','_') + "_" + ($sub_id -replace '\W','_')
        GNode -id $autoid -label $auto.name -type "automation" -sub $sn
        GLink -src $rgid -tgt $autoid -rel "contains"
        $runbooks = Run-Az-Json "automation runbook list --automation-account-name $($auto.name) --resource-group $($auto.resourceGroup)"
        $runbooks | ConvertTo-Json | Out-File "$output_dir\${sub_name}_runbooks_$($auto.name -replace '\W','_').json"
        foreach ($r in $runbooks) { $r | Add-Member -NotePropertyName "accountName" -NotePropertyValue $auto.name -Force }
        $all_runbooks += $runbooks
    }
    $rd["Runbooks"] = @{ data=$all_runbooks; fields=@("accountName","name","runbookType","state") }

    # CONTAINERS
    Write-Host "  [+] CONTAINERS" -ForegroundColor Green
    $acrs = Run-Az-Json "acr list"
    $acrs | ConvertTo-Json | Out-File "$output_dir\${sub_name}_acr.json"
    $rd["Container Registries"] = @{ data=$acrs; fields=@("name","resourceGroup","loginServer","adminUserEnabled") }
    foreach ($acr in $acrs) {
        $acrid = "acr_" + ($acr.name -replace '\W','_')
        $rgid  = "rg_" + ($acr.resourceGroup -replace '\W','_') + "_" + ($sub_id -replace '\W','_')
        GNode -id $acrid -label $acr.name -type "acr" -sub $sn
        GLink -src $rgid -tgt $acrid -rel "contains"
    }

    $aks = Run-Az-Json "aks list"
    $aks | ConvertTo-Json | Out-File "$output_dir\${sub_name}_aks.json"
    $rd["AKS Clusters"] = @{ data=$aks; fields=@("name","resourceGroup","location","kubernetesVersion") }
    foreach ($ak in $aks) {
        $aksid = "aks_" + ($ak.name -replace '\W','_')
        $rgid  = "rg_" + ($ak.resourceGroup -replace '\W','_') + "_" + ($sub_id -replace '\W','_')
        GNode -id $aksid -label $ak.name -type "aks" -sub $sn
        GLink -src $rgid -tgt $aksid -rel "contains"
    }
}


# ============================================================
# FINDINGS ENGINE
# ============================================================
Write-Host "[+] Analyzing findings..." -ForegroundColor Cyan

$findings = [System.Collections.Generic.List[hashtable]]::new()

function Add-Finding {
    param([string]$severity,[string]$title,[string]$desc,[string]$resource,[string]$sub)
    $script:findings.Add(@{ severity=$severity; title=$title; desc=$desc; resource=$resource; sub=$sub })
}

foreach ($sn in $report_data.Keys) {
    $rd = $report_data[$sn]

    # --- HIGH: Owner/Contributor assigned to guest or external users
    if ($rd.ContainsKey("Role Assignments")) {
        foreach ($r in $rd["Role Assignments"].data) {
            $rname = "$($r.roleDefinitionName)"
            $pname = "$($r.principalName)"
            $ptype = "$($r.principalType)"
            if ($rname -match "Owner|Contributor" -and $ptype -match "User" -and $pname -match "#EXT#|guest") {
                Add-Finding -severity "HIGH" -title "Privileged role assigned to external/guest user" -desc "$rname assigned to $pname" -resource $r.scope -sub $sn
            }
            # Owner assigned to SP
            if ($rname -eq "Owner" -and $ptype -match "ServicePrincipal") {
                Add-Finding -severity "HIGH" -title "Owner role assigned to Service Principal" -desc "$rname assigned to SP: $pname" -resource $r.scope -sub $sn
            }
            # Contributor at subscription scope
            if ($rname -match "Owner|Contributor" -and "$($r.scope)" -match "^/subscriptions/[^/]+$") {
                Add-Finding -severity "HIGH" -title "Subscription-level privileged role" -desc "$rname at subscription scope assigned to $pname ($ptype)" -resource $r.scope -sub $sn
            }
        }
    }

    # --- HIGH: Storage account with public blob access enabled
    if ($rd.ContainsKey("Storage Accounts")) {
        foreach ($sa in $rd["Storage Accounts"].data) {
            if ("$($sa.allowBlobPublicAccess)" -eq "True" -or "$($sa.allowBlobPublicAccess)" -eq "true") {
                Add-Finding -severity "HIGH" -title "Storage account allows public blob access" -desc "allowBlobPublicAccess=true on $($sa.name)" -resource $sa.name -sub $sn
            }
            if ("$($sa.minimumTlsVersion)" -match "TLS1_0|TLS1_1" -or "$($sa.minimumTlsVersion)" -eq "") {
                Add-Finding -severity "MEDIUM" -title "Storage account uses weak TLS" -desc "minimumTlsVersion=$($sa.minimumTlsVersion) on $($sa.name)" -resource $sa.name -sub $sn
            }
            if ("$($sa.enableHttpsTrafficOnly)" -eq "False" -or "$($sa.enableHttpsTrafficOnly)" -eq "false") {
                Add-Finding -severity "MEDIUM" -title "Storage account allows HTTP traffic" -desc "enableHttpsTrafficOnly=false on $($sa.name)" -resource $sa.name -sub $sn
            }
        }
    }

    # --- HIGH: Storage containers with public access
    if ($rd.ContainsKey("Storage Containers")) {
        foreach ($c in $rd["Storage Containers"].data) {
            if ("$($c.publicAccess)" -ne "" -and "$($c.publicAccess)" -ne "None" -and "$($c.publicAccess)" -ne "-") {
                Add-Finding -severity "HIGH" -title "Storage container is publicly accessible" -desc "Container $($c.name) in $($c.storageAccount) has publicAccess=$($c.publicAccess)" -resource "$($c.storageAccount)/$($c.name)" -sub $sn
            }
        }
    }

    # --- HIGH: NSG rules open to internet
    if ($rd.ContainsKey("NSG Rules")) {
        foreach ($r in $rd["NSG Rules"].data) {
            if ("$($r.access)" -eq "Allow" -and "$($r.direction)" -eq "Inbound" -and
                ("$($r.sourceAddressPrefix)" -eq "*" -or "$($r.sourceAddressPrefix)" -eq "0.0.0.0/0" -or "$($r.sourceAddressPrefix)" -eq "Internet")) {
                $port = "$($r.destinationPortRange)"
                $sev  = if ($port -match "^(22|3389|1433|5432|3306|27017|6379|8080|8443)$") { "HIGH" } else { "MEDIUM" }
                Add-Finding -severity $sev -title "NSG rule allows inbound from any IP" -desc "Rule $($r.name) in $($r.nsgName): Allow inbound $($r.protocol) port $port from ANY" -resource $r.nsgName -sub $sn
            }
        }
    }

    # --- HIGH: SQL firewall open to internet
    if ($rd.ContainsKey("SQL Firewall Rules")) {
        foreach ($r in $rd["SQL Firewall Rules"].data) {
            if ("$($r.startIpAddress)" -eq "0.0.0.0" -and "$($r.endIpAddress)" -eq "255.255.255.255") {
                Add-Finding -severity "HIGH" -title "SQL Server firewall open to internet" -desc "Rule $($r.name) on $($r.serverName): 0.0.0.0 - 255.255.255.255" -resource $r.serverName -sub $sn
            }
            if ("$($r.startIpAddress)" -eq "0.0.0.0" -and "$($r.endIpAddress)" -eq "0.0.0.0") {
                Add-Finding -severity "MEDIUM" -title "SQL Server allows Azure services (Allow Azure IPs)" -desc "Rule $($r.name) on $($r.serverName) allows all Azure services" -resource $r.serverName -sub $sn
            }
        }
    }

    # --- HIGH: Web apps with credentials in appsettings
    if ($rd.ContainsKey("WebApp AppSettings")) {
        foreach ($s in $rd["WebApp AppSettings"].data) {
            if ("$($s.name)" -match "password|secret|key|token|pwd|conn|connectionstring|apikey" -and "$($s.value)" -ne "" -and "$($s.value)" -ne "-") {
                Add-Finding -severity "HIGH" -title "Potential credential in WebApp AppSettings" -desc "Key '$($s.name)' = '$($s.value)' in app $($s.appName)" -resource $s.appName -sub $sn
            }
        }
    }
    if ($rd.ContainsKey("Function AppSettings")) {
        foreach ($s in $rd["Function AppSettings"].data) {
            if ("$($s.name)" -match "password|secret|key|token|pwd|conn|connectionstring|apikey" -and "$($s.value)" -ne "" -and "$($s.value)" -ne "-") {
                Add-Finding -severity "HIGH" -title "Potential credential in Function AppSettings" -desc "Key '$($s.name)' = '$($s.value)' in func $($s.funcName)" -resource $s.funcName -sub $sn
            }
        }
    }

    # --- MEDIUM: Web apps without HTTPS enforced
    if ($rd.ContainsKey("Web Apps")) {
        foreach ($app in $rd["Web Apps"].data) {
            if ("$($app.httpsOnly)" -eq "False" -or "$($app.httpsOnly)" -eq "false") {
                Add-Finding -severity "MEDIUM" -title "Web App does not enforce HTTPS" -desc "$($app.name) has httpsOnly=false" -resource $app.name -sub $sn
            }
        }
    }

    # --- MEDIUM: Key Vault secrets found (informational, worth reviewing)
    if ($rd.ContainsKey("Key Vault Secrets")) {
        $secCount = ($rd["Key Vault Secrets"].data | Measure-Object).Count
        if ($secCount -gt 0) {
            Add-Finding -severity "INFO" -title "Key Vault secrets accessible" -desc "$secCount secret(s) listed — review values manually" -resource "Key Vaults" -sub $sn
        }
    }

    # --- MEDIUM: Disabled users with role assignments
    if ($rd.ContainsKey("AD Users") -and $rd.ContainsKey("Role Assignments")) {
        $disabledUsers = $rd["AD Users"].data | Where-Object { "$($_.accountEnabled)" -eq "False" }
        foreach ($u in $disabledUsers) {
            $upn = $u.userPrincipalName
            $hasRole = $rd["Role Assignments"].data | Where-Object { "$($_.principalName)" -eq "$upn" }
            if ($hasRole) {
                Add-Finding -severity "MEDIUM" -title "Disabled user has active role assignments" -desc "$upn is disabled but still has role: $($hasRole[0].roleDefinitionName)" -resource $upn -sub $sn
            }
        }
    }

    # --- MEDIUM: Automation accounts with credentials
    if ($rd.ContainsKey("Automation Accounts")) {
        foreach ($a in $rd["Automation Accounts"].data) {
            Add-Finding -severity "INFO" -title "Automation Account found" -desc "Review runbooks in $($a.name) for hardcoded credentials" -resource $a.name -sub $sn
        }
    }

    # --- INFO: ACR with admin user enabled
    if ($rd.ContainsKey("Container Registries")) {
        foreach ($acr in $rd["Container Registries"].data) {
            if ("$($acr.adminUserEnabled)" -eq "True" -or "$($acr.adminUserEnabled)" -eq "true") {
                Add-Finding -severity "MEDIUM" -title "Container Registry has admin user enabled" -desc "$($acr.name) has adminUserEnabled=true — admin credentials may be exposed" -resource $acr.name -sub $sn
            }
        }
    }
}

$fc = $findings.Count
$fcol = if ($fc -gt 0) { "Yellow" } else { "Green" }
Write-Host "  [+] Found $fc finding(s)" -ForegroundColor $fcol

# Build findings HTML block
$sev_order = @{ "HIGH"=0; "MEDIUM"=1; "INFO"=2 }
$sev_color = @{ "HIGH"="#f85149"; "MEDIUM"="#f0883e"; "INFO"="#58a6ff" }
$sev_bg    = @{ "HIGH"="#3d1a1a"; "MEDIUM"="#3d2a10"; "INFO"="#0d2139" }

$findings_html = "<div id='findings'><h2>Findings <span class='b'>$($findings.Count)</span></h2>"

if ($findings.Count -eq 0) {
    $findings_html += "<div style='color:#8b949e;font-size:13px;padding:12px 0'>No findings detected.</div>"
} else {
    $sorted = $findings | Sort-Object { $sev_order[$_.severity] }
    foreach ($f in $sorted) {
        $col = $sev_color[$f.severity]
        $bg  = $sev_bg[$f.severity]
        $findings_html += "<div class='finding' style='border-left:3px solid $col;background:$bg'>"
        $findings_html += "<div class='f-head'><span class='f-sev' style='color:$col'>$($f.severity)</span><span class='f-title'>$(HtmlEnc $f.title)</span><span class='f-sub'>$($f.sub)</span></div>"
        $findings_html += "<div class='f-desc'>$(HtmlEnc $f.desc)</div>"
        $findings_html += "<div class='f-res'>Resource: $(HtmlEnc $f.resource)</div>"
        $findings_html += "</div>"
    }
}
$findings_html += "</div>"

# Stats bar
$high_count   = ($findings | Where-Object { $_.severity -eq "HIGH"   } | Measure-Object).Count
$medium_count = ($findings | Where-Object { $_.severity -eq "MEDIUM" } | Measure-Object).Count
$info_count   = ($findings | Where-Object { $_.severity -eq "INFO"   } | Measure-Object).Count

# ============================================================
# BUILD REPORT.HTML
# ============================================================
Write-Host "`n[+] Generating report.html..." -ForegroundColor Cyan

$gen_time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$sidebar  = ""
$content  = ""

foreach ($sn in $report_data.Keys) {
    $sid      = $sn -replace '\W','_'
    $sidebar += "<li class='sh'><a href='#$sid'>$sn</a><ul>"
    $content += "<div class='sub' id='$sid'><h2>$sn</h2>"

    foreach ($section_title in $report_data[$sn].Keys) {
        $meta  = $report_data[$sn][$section_title]
        $data  = $meta.data
        $fields = $meta.fields
        $cnt   = if ($data) { ($data | Measure-Object).Count } else { 0 }
        $secid = $sid + "_" + ($section_title -replace '\W','_')
        $tbl   = Make-Table -items $data -fields $fields

        $sidebar += "<li><a href='#$secid'>$section_title <span class='b'>$cnt</span></a></li>"
        $content += "<div class='sec' id='$secid'>"
        $content += "<div class='sech' onclick='tog(this)'><span class='st'>$section_title</span><span class='sc'>$cnt items</span></div>"
        $content += "<div class='sw'>$tbl</div></div>"
    }

    $content += "</div>"
    $sidebar += "</ul></li>"
}

$rh  = "<!DOCTYPE html><html lang='en'><head><meta charset='UTF-8'><title>Azure Report</title><style>"
$rh += "*{box-sizing:border-box;margin:0;padding:0}"
$rh += "body{font-family:'Segoe UI',sans-serif;background:#0d1117;color:#c9d1d9;display:flex;min-height:100vh}"
$rh += "a{color:#58a6ff;text-decoration:none}a:hover{text-decoration:underline}"
$rh += "#sb{width:250px;background:#161b22;border-right:1px solid #30363d;padding:16px 0;overflow-y:auto;position:fixed;top:0;bottom:0;left:0}"
$rh += "#sb .logo{padding:0 16px 14px;border-bottom:1px solid #30363d;margin-bottom:10px}"
$rh += "#sb .logo h1{font-size:14px;font-weight:600;color:#e6edf3}"
$rh += "#sb .logo p{font-size:11px;color:#8b949e;margin-top:3px}"
$rh += "#sb .gb{display:block;margin:0 14px 12px;padding:7px;background:#1f6feb;border-radius:6px;color:#fff;font-size:12px;font-weight:600;text-align:center}"
$rh += "#sb .gb:hover{background:#388bfd;text-decoration:none}"
$rh += "#sb ul{list-style:none;padding:0 8px}"
$rh += "#sb li{margin:1px 0}"
$rh += "#sb li a{display:flex;align-items:center;justify-content:space-between;padding:4px 8px;border-radius:5px;font-size:12px;color:#8b949e}"
$rh += "#sb li a:hover{background:#21262d;color:#e6edf3;text-decoration:none}"
$rh += "#sb li.sh>a{font-weight:600;color:#c9d1d9;font-size:13px}"
$rh += "#sb ul ul{padding-left:10px;border-left:1px solid #30363d;margin-left:8px}"
$rh += ".b{background:#21262d;border:1px solid #30363d;border-radius:10px;padding:1px 6px;font-size:10px;color:#8b949e}"
$rh += "#main{margin-left:250px;padding:28px;flex:1}"
$rh += ".ph{margin-bottom:24px;padding-bottom:16px;border-bottom:1px solid #30363d;display:flex;align-items:center;justify-content:space-between}"
$rh += ".ph h1{font-size:20px;font-weight:600;color:#e6edf3}"
$rh += ".ph p{font-size:12px;color:#8b949e;margin-top:4px}"
$rh += ".gb2{display:inline-block;background:#1f6feb;color:#fff;padding:7px 16px;border-radius:6px;font-size:13px;font-weight:600}"
$rh += ".gb2:hover{background:#388bfd;text-decoration:none}"
$rh += ".sub{margin-bottom:36px}"
$rh += ".sub h2{font-size:15px;font-weight:600;color:#e6edf3;margin-bottom:14px;padding-bottom:8px;border-bottom:1px solid #30363d}"
$rh += ".sec{background:#161b22;border:1px solid #30363d;border-radius:8px;margin-bottom:12px;overflow:hidden}"
$rh += ".sech{display:flex;align-items:center;padding:11px 14px;background:#1c2128;border-bottom:1px solid #30363d;cursor:pointer}"
$rh += ".sech:hover{background:#21262d}"
$rh += ".st{font-size:13px;font-weight:500;color:#e6edf3;flex:1}"
$rh += ".sc{background:#0d1117;border:1px solid #30363d;border-radius:12px;padding:2px 9px;font-size:11px;color:#8b949e}"
$rh += ".sw{overflow-x:auto;max-height:380px;overflow-y:auto}"
$rh += "table{width:100%;border-collapse:collapse;font-size:12px}"
$rh += "thead tr{background:#1c2128;position:sticky;top:0}"
$rh += "th{padding:7px 11px;text-align:left;color:#8b949e;font-weight:500;border-bottom:1px solid #30363d;white-space:nowrap}"
$rh += "td{padding:6px 11px;border-bottom:1px solid #21262d;color:#c9d1d9;word-break:break-all;vertical-align:top}"
$rh += "tr:last-child td{border-bottom:none}tr:hover td{background:#1c2128}"
$rh += "td.w{color:#f0883e;font-weight:500}"
$rh += "#sf{width:100%;padding:7px 12px;background:#21262d;border:1px solid #30363d;border-radius:6px;color:#c9d1d9;font-size:13px;margin-bottom:18px}"
$rh += "#sf:focus{outline:none;border-color:#58a6ff}"
$rh += ".hidden{display:none}"
$rh += "#findings{margin-bottom:32px}"
$rh += "#findings h2{font-size:15px;font-weight:600;color:#e6edf3;margin-bottom:12px;padding-bottom:8px;border-bottom:1px solid #30363d}"
$rh += ".finding{border-radius:6px;padding:12px 14px;margin-bottom:8px}"
$rh += ".f-head{display:flex;align-items:center;gap:10px;margin-bottom:4px}"
$rh += ".f-sev{font-size:11px;font-weight:700;letter-spacing:.06em;min-width:50px}"
$rh += ".f-title{font-size:13px;font-weight:500;color:#e6edf3;flex:1}"
$rh += ".f-sub{font-size:11px;color:#8b949e}"
$rh += ".f-desc{font-size:12px;color:#c9d1d9;margin-bottom:3px}"
$rh += ".f-res{font-size:11px;color:#8b949e}"
$rh += ".stats{display:flex;gap:10px;margin-bottom:20px}"
$rh += ".stat{padding:10px 18px;border-radius:8px;min-width:100px}"
$rh += ".stat .n{font-size:22px;font-weight:700}"
$rh += ".stat .l{font-size:11px;margin-top:2px}"
$rh += "</style></head><body>"
$rh += "<nav id='sb'><div class='logo'><h1>Azure Enum Report</h1><p>$gen_time</p></div>"
$rh += "<a class='gb' href='graph.html' target='_blank'>Graph View</a>"
$rh += "<a class='gb' href='#findings' style='background:#a12121;margin-bottom:4px'>Findings ($($findings.Count))</a>"
$rh += "<ul>$sidebar</ul></nav>"
$rh += "<main id='main'><div class='ph'><div><h1>Azure Enumeration Report</h1><p>$gen_time</p></div>"
$rh += "<a class='gb2' href='graph.html' target='_blank'>Graph View</a></div>"
$rh += "<div class='stats'>"
$rh += "<div class='stat' style='background:#3d1a1a'><div class='n' style='color:#f85149'>$high_count</div><div class='l' style='color:#f85149'>HIGH</div></div>"
$rh += "<div class='stat' style='background:#3d2a10'><div class='n' style='color:#f0883e'>$medium_count</div><div class='l' style='color:#f0883e'>MEDIUM</div></div>"
$rh += "<div class='stat' style='background:#0d2139'><div class='n' style='color:#58a6ff'>$info_count</div><div class='l' style='color:#58a6ff'>INFO</div></div>"
$rh += "</div>"
$rh += $findings_html
$rh += "<input id='sf' type='text' placeholder='Filter tables...' oninput='ft(this.value)'>"
$rh += $content
$rh += "</main><script>"
$rh += "function tog(h){var w=h.nextElementSibling;if(w)w.classList.toggle('hidden');}"
$rh += "function ft(q){q=q.toLowerCase();document.querySelectorAll('tbody tr').forEach(function(r){r.style.display=r.textContent.toLowerCase().indexOf(q)>=0?'':'none';});}"
$rh += "</script></body></html>"

$rh | Out-File -FilePath "$output_dir\report.html" -Encoding utf8
Write-Host "  [+] report.html written" -ForegroundColor Green

# ============================================================
# BUILD GRAPH.HTML
# ============================================================
Write-Host "[+] Generating graph.html..." -ForegroundColor Cyan

$nodes_js = ($global:gNodes | ForEach-Object {
    $i = $_.id    -replace '"','\"' -replace "'","\'"
    $l = $_.label -replace '"','\"' -replace "'","\'"
    $t = $_.type  -replace '"','\"'
    $s = $_.sub   -replace '"','\"' -replace "'","\'"
    "{`"id`":`"$i`",`"label`":`"$l`",`"type`":`"$t`",`"sub`":`"$s`"}"
}) -join ","

$links_js = ($global:gLinks | ForEach-Object {
    $s = $_.source -replace '"','\"' -replace "'","\'"
    $t = $_.target -replace '"','\"' -replace "'","\'"
    $r = $_.rel    -replace '"','\"'
    "{`"source`":`"$s`",`"target`":`"$t`",`"rel`":`"$r`"}"
}) -join ","

$gh  = "<!DOCTYPE html><html lang='en'><head><meta charset='UTF-8'><title>Azure Graph</title><style>"
$gh += "*{box-sizing:border-box;margin:0;padding:0}"
$gh += "body{background:#0d1117;color:#c9d1d9;font-family:'Segoe UI',sans-serif;overflow:hidden}"
$gh += "#tb{position:fixed;top:0;left:0;right:0;height:46px;background:#161b22;border-bottom:1px solid #30363d;display:flex;align-items:center;gap:8px;padding:0 14px;z-index:100}"
$gh += "#tb h1{font-size:13px;font-weight:600;color:#e6edf3;margin-right:6px}"
$gh += ".btn{background:#21262d;border:1px solid #30363d;color:#c9d1d9;padding:4px 10px;border-radius:5px;font-size:11px;cursor:pointer}"
$gh += ".btn:hover{background:#30363d}.btn.on{background:#1f6feb;border-color:#1f6feb;color:#fff}"
$gh += "#sq{background:#21262d;border:1px solid #30363d;color:#c9d1d9;padding:4px 9px;border-radius:5px;font-size:11px;width:150px}"
$gh += "#sq:focus{outline:none;border-color:#58a6ff}"
$gh += "#lg{display:flex;gap:8px;margin-left:auto;align-items:center;flex-wrap:wrap}"
$gh += ".ld{display:flex;align-items:center;gap:4px;font-size:10px;color:#8b949e}"
$gh += ".lc{width:9px;height:9px;border-radius:50%}"
$gh += "#info{position:fixed;bottom:0;left:0;right:0;background:#161b22;border-top:1px solid #30363d;padding:8px 14px;font-size:12px;color:#8b949e;z-index:100}"
$gh += "svg{cursor:grab;margin-top:46px}svg:active{cursor:grabbing}"
$gh += ".lnk{stroke-opacity:.35;stroke-width:1px}"
$gh += ".lbl{font-size:9px;fill:#8b949e;pointer-events:none;text-anchor:middle}"
$gh += ".ic{font-size:8px;fill:#fff;pointer-events:none;text-anchor:middle;dominant-baseline:central;font-weight:600}"
$gh += ".hl circle{stroke:#fff;stroke-width:3px}"
$gh += ".dm circle,.dm text{opacity:.12}.dm.lnk{stroke-opacity:.04}"
$gh += "</style></head><body>"
$gh += "<div id='tb'><h1>Azure Graph</h1>"
$gh += "<button class='btn on' onclick='ftype(`"`")'>All</button>"
$gh += "<button class='btn' onclick='ftype(`"user`")'>Users</button>"
$gh += "<button class='btn' onclick='ftype(`"group`")'>Groups</button>"
$gh += "<button class='btn' onclick='ftype(`"sp`")'>SPs</button>"
$gh += "<button class='btn' onclick='ftype(`"role`")'>Roles</button>"
$gh += "<button class='btn' onclick='ftype(`"vm`")'>VMs</button>"
$gh += "<button class='btn' onclick='ftype(`"keyvault`")'>KVs</button>"
$gh += "<button class='btn' onclick='ftype(`"storage`")'>Storage</button>"
$gh += "<button class='btn' onclick='ftype(`"rg`")'>RGs</button>"
$gh += "<input id='sq' type='text' placeholder='Search...' oninput='fsearch(this.value)'>"
$gh += "<div id='lg'>"
$gh += "<div class='ld'><div class='lc' style='background:#58a6ff'></div>User</div>"
$gh += "<div class='ld'><div class='lc' style='background:#3fb950'></div>Group</div>"
$gh += "<div class='ld'><div class='lc' style='background:#d2a8ff'></div>SP</div>"
$gh += "<div class='ld'><div class='lc' style='background:#f0883e'></div>Role</div>"
$gh += "<div class='ld'><div class='lc' style='background:#56d364'></div>VM</div>"
$gh += "<div class='ld'><div class='lc' style='background:#ff7b72'></div>KV</div>"
$gh += "<div class='ld'><div class='lc' style='background:#79c0ff'></div>Storage</div>"
$gh += "<div class='ld'><div class='lc' style='background:#e3b341'></div>WebApp</div>"
$gh += "<div class='ld'><div class='lc' style='background:#8b949e'></div>RG/Sub</div>"
$gh += "</div></div>"
$gh += "<svg id='g'></svg>"
$gh += "<div id='info'>Click a node for details - Drag to move - Scroll to zoom</div>"
$gh += "<script src='https://cdnjs.cloudflare.com/ajax/libs/d3/7.8.5/d3.min.js'></script><script>"
$gh += "var AN=[$nodes_js];var AL=[$links_js];"
$gh += "var C={user:'#58a6ff',group:'#3fb950',sp:'#d2a8ff',role:'#f0883e',resource:'#ffa657',"
$gh += "keyvault:'#ff7b72',storage:'#79c0ff',vm:'#56d364',webapp:'#e3b341',"
$gh += "subscription:'#8b949e',rg:'#6e7681',sql:'#f78166',aks:'#39d353',acr:'#bc8cff',automation:'#ffb347'};"
$gh += "var R={subscription:22,rg:16,user:12,group:13,sp:12,role:11,vm:13,keyvault:13,storage:12,webapp:11,sql:12,aks:13,acr:11,automation:11};"
$gh += "var IC={user:'U',group:'G',sp:'SP',role:'R',vm:'VM',keyvault:'KV',storage:'S',webapp:'W',subscription:'SUB',rg:'RG',sql:'SQL',aks:'AKS',acr:'ACR',automation:'AU'};"
$gh += "var sim,gEl,lnkS,ndS,lblS,curFilt='';"
$gh += "function nc(d){return C[d.type]||'#8b949e';}function nr(d){return R[d.type]||10;}"
$gh += "function init(nodes,links){"
$gh += "d3.select('#g').selectAll('*').remove();"
$gh += "var W=window.innerWidth,H=window.innerHeight-82;"
$gh += "var svg=d3.select('#g').attr('width',W).attr('height',H);"
$gh += "var zm=d3.zoom().scaleExtent([0.03,4]).on('zoom',function(e){gEl.attr('transform',e.transform);});"
$gh += "svg.call(zm);"
$gh += "var defs=svg.append('defs');"
$gh += "Object.keys(C).forEach(function(t){defs.append('marker').attr('id','a'+t).attr('viewBox','0 0 10 10').attr('refX',22).attr('refY',5).attr('markerWidth',5).attr('markerHeight',5).attr('orient','auto-start-reverse').append('path').attr('d','M0,0L10,5L0,10z').attr('fill',C[t]).attr('opacity',.5);});"
$gh += "gEl=svg.append('g');"
$gh += "sim=d3.forceSimulation(nodes).force('link',d3.forceLink(links).id(function(d){return d.id;}).distance(90).strength(.4)).force('charge',d3.forceManyBody().strength(-200)).force('center',d3.forceCenter(W/2,H/2)).force('col',d3.forceCollide().radius(function(d){return nr(d)+5;}));"
$gh += "lnkS=gEl.append('g').selectAll('line').data(links).join('line').attr('class','lnk').attr('stroke',function(d){return C[d.target.type]||'#8b949e';}).attr('marker-end',function(d){return 'url(#a'+(d.target.type||'rg')+')';});"
$gh += "var ng=gEl.append('g').selectAll('g').data(nodes).join('g').call(d3.drag().on('start',function(e,d){if(!e.active)sim.alphaTarget(.3).restart();d.fx=d.x;d.fy=d.y;}).on('drag',function(e,d){d.fx=e.x;d.fy=e.y;}).on('end',function(e,d){if(!e.active)sim.alphaTarget(0);d.fx=null;d.fy=null;})).on('click',function(e,d){showInfo(d);}).on('mouseover',function(e,d){hl(d,true);}).on('mouseout',function(e,d){hl(d,false);});"
$gh += "ng.append('circle').attr('r',function(d){return nr(d);}).attr('fill',function(d){return nc(d);}).attr('stroke',function(d){return d3.color(nc(d)).darker(1);}).attr('stroke-width',1.5);"
$gh += "ng.append('text').attr('class','ic').text(function(d){return IC[d.type]||'?';});"
$gh += "lblS=gEl.append('g').selectAll('text').data(nodes).join('text').attr('class','lbl').attr('dy',function(d){return nr(d)+11;}).text(function(d){return d.label.length>18?d.label.slice(0,16)+'..':d.label;});"
$gh += "ndS=ng;"
$gh += "sim.on('tick',function(){lnkS.attr('x1',function(d){return d.source.x;}).attr('y1',function(d){return d.source.y;}).attr('x2',function(d){return d.target.x;}).attr('y2',function(d){return d.target.y;});ndS.attr('transform',function(d){return 'translate('+d.x+','+d.y+')';});lblS.attr('x',function(d){return d.x;}).attr('y',function(d){return d.y;});});}"
$gh += "function showInfo(d){var conn=AL.filter(function(l){return(l.source===d.id||l.target===d.id||l.source.id===d.id||l.target.id===d.id);}).map(function(l){var o=(l.source.id||l.source)===d.id?(l.target.label||l.target):(l.source.label||l.source);return l.rel+' -> '+o;}).join(' | ');document.getElementById('info').innerHTML='<span style=color:#e6edf3>['+d.type.toUpperCase()+']</span> <span style=color:#58a6ff>'+d.label+'</span>'+(d.sub?' <span style=color:#8b949e>sub:'+d.sub+'</span>':'')+(conn?' - '+conn:'');}"
$gh += "function hl(d,on){if(!on){ndS.classed('hl',false).classed('dm',false);lnkS.classed('dm',false);return;}var nb=new Set([d.id]);AL.forEach(function(l){var s=l.source.id||l.source,t=l.target.id||l.target;if(s===d.id)nb.add(t);if(t===d.id)nb.add(s);});ndS.classed('hl',function(n){return n.id===d.id;});ndS.classed('dm',function(n){return !nb.has(n.id);});lnkS.classed('dm',function(l){var s=l.source.id||l.source,t=l.target.id||l.target;return s!==d.id&&t!==d.id;});}"
$gh += "function ftype(t){curFilt=t;document.querySelectorAll('.btn').forEach(function(b){b.classList.remove('on');});event.target.classList.add('on');var ns=t===''?AN:AN.filter(function(n){return n.type===t;});var ids=new Set(ns.map(function(n){return n.id;}));var ls=AL.filter(function(l){return ids.has(l.source.id||l.source)&&ids.has(l.target.id||l.target);});init(JSON.parse(JSON.stringify(ns)),JSON.parse(JSON.stringify(ls)));}"
$gh += "function fsearch(q){if(!ndS)return;q=q.toLowerCase();ndS.classed('hl',function(d){return d.label.toLowerCase().indexOf(q)>=0&&q.length>0;});ndS.classed('dm',function(d){return q.length>0&&d.label.toLowerCase().indexOf(q)<0;});lblS.classed('dm',function(d){return q.length>0&&d.label.toLowerCase().indexOf(q)<0;});}"
$gh += "window.addEventListener('resize',function(){ftype(curFilt);});"
$gh += "init(JSON.parse(JSON.stringify(AN)),JSON.parse(JSON.stringify(AL)));"
$gh += "</script></body></html>"

$gh | Out-File -FilePath "$output_dir\graph.html" -Encoding utf8
Write-Host "  [+] graph.html written" -ForegroundColor Green

# ============================================================
# DONE
# ============================================================
Write-Host "`n================================================" -ForegroundColor Yellow
Write-Host "  COMPLETE" -ForegroundColor Green
Write-Host "  Folder : $output_dir" -ForegroundColor Yellow
Write-Host "  Nodes  : $($global:gNodes.Count)  Links: $($global:gLinks.Count)" -ForegroundColor White
Write-Host "================================================`n" -ForegroundColor Yellow

$report_abs = Join-Path $output_dir "report.html"
Start-Process $report_abs

Get-ChildItem $output_dir | Where-Object { $_.Length -gt 10 } |
    Select-Object Name, @{N='Size';E={"{0:N0} bytes" -f $_.Length}} |
    Format-Table -AutoSize
