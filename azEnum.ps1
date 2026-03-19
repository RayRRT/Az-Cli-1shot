# ============================================================
#  HTML Report + Graph Generator
#  Called by azure_enum.ps1 automatically
#  Usage: .\azure_enum_html.ps1 -output_dir <path>
# ============================================================
param([string]$output_dir)

Add-Type -AssemblyName System.Web

$report_file = "$output_dir\report.html"
$graph_file  = "$output_dir\graph.html"

# Load JSON files
function Load-Json { param([string]$path)
    if (Test-Path $path) { return Get-Content $path -Raw | ConvertFrom-Json }
    return @()
}

$nodes_raw = Load-Json "$output_dir\graph_nodes.json"
$links_raw = Load-Json "$output_dir\graph_links.json"

# ============================================================
# BUILD REPORT.HTML
# ============================================================

function HtmlEnc { param([string]$s) return [System.Web.HttpUtility]::HtmlEncode($s) }

function Make-Table {
    param([object]$items, [string[]]$fields)
    $warn_pattern = '0\.0\.0\.0|Owner|Contributor|admin|password|secret'
    $hdrs = ($fields | ForEach-Object { "<th>$_</th>" }) -join ""
    if (-not $items -or ($items | Measure-Object).Count -eq 0) {
        return "<table><thead><tr>$hdrs</tr></thead><tbody><tr><td colspan='$($fields.Count)' style='color:#666;font-style:italic'>No data</td></tr></tbody></table>"
    }
    $rows = ""
    foreach ($item in $items) {
        $rows += "<tr>"
        foreach ($f in $fields) {
            $val = "$($item.$f)"; if (-not $val -or $val -eq "") { $val = "-" }
            $cls = if ($val -match $warn_pattern -and $val -notmatch '^false$') { " class='w'" } else { "" }
            $rows += "<td$cls>$(HtmlEnc $val)</td>"
        }
        $rows += "</tr>"
    }
    return "<table><thead><tr>$hdrs</tr></thead><tbody>$rows</tbody></table>"
}

# Discover all JSON data files and build sections
$sections = [System.Collections.Generic.List[hashtable]]::new()

$file_map = @{
    "subscriptions"  = @{ title="Subscriptions";       fields=@("name","id","state","tenantId") }
    "roles"          = @{ title="Role Assignments";     fields=@("principalName","roleDefinitionName","scope","principalType") }
    "users"          = @{ title="AD Users";             fields=@("displayName","userPrincipalName","accountEnabled","userType") }
    "groups"         = @{ title="AD Groups";            fields=@("displayName","description","securityEnabled") }
    "sps"            = @{ title="Service Principals";   fields=@("displayName","appId","servicePrincipalType") }
    "apps"           = @{ title="App Registrations";    fields=@("displayName","appId","signInAudience") }
    "rgs"            = @{ title="Resource Groups";      fields=@("name","location","provisioningState") }
    "resources"      = @{ title="All Resources";        fields=@("name","type","resourceGroup","location") }
    "vms"            = @{ title="Virtual Machines";     fields=@("name","resourceGroup","location") }
    "vm_ips"         = @{ title="VM IPs";               fields=@("virtualMachine") }
    "vnets"          = @{ title="Virtual Networks";     fields=@("name","resourceGroup","location") }
    "pips"           = @{ title="Public IPs";           fields=@("name","resourceGroup","ipAddress","publicIPAllocationMethod") }
    "nsgs"           = @{ title="NSGs";                 fields=@("name","resourceGroup","location") }
    "storage"        = @{ title="Storage Accounts";     fields=@("name","resourceGroup","allowBlobPublicAccess","minimumTlsVersion") }
    "keyvaults"      = @{ title="Key Vaults";           fields=@("name","resourceGroup","location") }
    "webapps"        = @{ title="Web Apps";             fields=@("name","resourceGroup","defaultHostName","state","httpsOnly") }
    "funcapps"       = @{ title="Function Apps";        fields=@("name","resourceGroup","defaultHostName","state") }
    "sql"            = @{ title="SQL Servers";          fields=@("name","resourceGroup","fullyQualifiedDomainName","administratorLogin") }
    "automation"     = @{ title="Automation Accounts";  fields=@("name","resourceGroup","location") }
    "acr"            = @{ title="Container Registries"; fields=@("name","resourceGroup","loginServer","adminUserEnabled") }
    "aks"            = @{ title="AKS Clusters";         fields=@("name","resourceGroup","location","kubernetesVersion") }
}

$all_json = Get-ChildItem "$output_dir\*.json" | Where-Object { $_.Name -notmatch "graph_" }

$grouped = @{}
foreach ($f in $all_json) {
    $base = $f.BaseName
    foreach ($key in $file_map.Keys) {
        if ($base -match "_${key}$" -or $base -eq $key) {
            $sub_label = if ($base -match "^01_") { "Global" } else { ($base -split "_")[0] }
            if (-not $grouped.ContainsKey($sub_label)) { $grouped[$sub_label] = @{} }
            if (-not $grouped[$sub_label].ContainsKey($key)) { $grouped[$sub_label][$key] = @() }
            $data = Load-Json $f.FullName
            if ($data) { $grouped[$sub_label][$key] += $data }
        }
    }
}

$sidebar  = ""
$content  = ""
$gen_time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

foreach ($sub_label in ($grouped.Keys | Sort-Object)) {
    $sid = $sub_label -replace '\W','_'
    $sidebar += "<li class='sub-head'><a href='#$sid'>$sub_label</a><ul>"
    $content  += "<div class='sub' id='$sid'><h2>$sub_label</h2>"

    foreach ($key in ($file_map.Keys | Sort-Object)) {
        if (-not $grouped[$sub_label].ContainsKey($key)) { continue }
        $meta  = $file_map[$key]
        $data  = $grouped[$sub_label][$key]
        $cnt   = ($data | Measure-Object).Count
        $secid = "${sid}_$key"
        $tbl   = Make-Table -items $data -fields $meta.fields

        $sidebar += "<li><a href='#$secid'>$($meta.title) <span class='b'>$cnt</span></a></li>"
        $content  += "<div class='sec' id='$secid'>"
        $content  += "<div class='sh' onclick='tog(this)'><span class='st'>$($meta.title)</span><span class='sc'>$cnt items</span></div>"
        $content  += "<div class='sw'>$tbl</div></div>"
    }

    $content  += "</div>"
    $sidebar  += "</ul></li>"
}

$report_html = "<!DOCTYPE html><html lang='en'><head><meta charset='UTF-8'><title>Azure Report</title><style>"
$report_html += "*{box-sizing:border-box;margin:0;padding:0}"
$report_html += "body{font-family:'Segoe UI',sans-serif;background:#0d1117;color:#c9d1d9;display:flex;min-height:100vh}"
$report_html += "a{color:#58a6ff;text-decoration:none}a:hover{text-decoration:underline}"
$report_html += "#sb{width:250px;background:#161b22;border-right:1px solid #30363d;padding:16px 0;overflow-y:auto;position:fixed;top:0;bottom:0;left:0}"
$report_html += "#sb .logo{padding:0 16px 14px;border-bottom:1px solid #30363d;margin-bottom:10px}"
$report_html += "#sb .logo h1{font-size:14px;font-weight:600;color:#e6edf3}"
$report_html += "#sb .logo p{font-size:11px;color:#8b949e;margin-top:3px}"
$report_html += "#sb .gb{display:block;margin:0 14px 12px;padding:7px;background:#1f6feb;border-radius:6px;color:#fff;font-size:12px;font-weight:600;text-align:center}"
$report_html += "#sb .gb:hover{background:#388bfd;text-decoration:none}"
$report_html += "#sb ul{list-style:none;padding:0 8px}"
$report_html += "#sb li{margin:1px 0}"
$report_html += "#sb li a{display:flex;align-items:center;justify-content:space-between;padding:4px 8px;border-radius:5px;font-size:12px;color:#8b949e}"
$report_html += "#sb li a:hover{background:#21262d;color:#e6edf3;text-decoration:none}"
$report_html += "#sb li.sub-head>a{font-weight:600;color:#c9d1d9;font-size:13px}"
$report_html += "#sb ul ul{padding-left:10px;border-left:1px solid #30363d;margin-left:8px}"
$report_html += ".b{background:#21262d;border:1px solid #30363d;border-radius:10px;padding:1px 6px;font-size:10px;color:#8b949e}"
$report_html += "#main{margin-left:250px;padding:28px;flex:1}"
$report_html += ".ph{margin-bottom:24px;padding-bottom:16px;border-bottom:1px solid #30363d;display:flex;align-items:center;justify-content:space-between}"
$report_html += ".ph h1{font-size:20px;font-weight:600;color:#e6edf3}"
$report_html += ".ph p{font-size:12px;color:#8b949e;margin-top:4px}"
$report_html += ".gb2{display:inline-block;background:#1f6feb;color:#fff;padding:7px 16px;border-radius:6px;font-size:13px;font-weight:600}"
$report_html += ".gb2:hover{background:#388bfd;text-decoration:none}"
$report_html += ".sub{margin-bottom:36px}"
$report_html += ".sub h2{font-size:15px;font-weight:600;color:#e6edf3;margin-bottom:14px;padding-bottom:8px;border-bottom:1px solid #30363d}"
$report_html += ".sec{background:#161b22;border:1px solid #30363d;border-radius:8px;margin-bottom:12px;overflow:hidden}"
$report_html += ".sh{display:flex;align-items:center;padding:11px 14px;background:#1c2128;border-bottom:1px solid #30363d;cursor:pointer}"
$report_html += ".sh:hover{background:#21262d}"
$report_html += ".st{font-size:13px;font-weight:500;color:#e6edf3;flex:1}"
$report_html += ".sc{background:#0d1117;border:1px solid #30363d;border-radius:12px;padding:2px 9px;font-size:11px;color:#8b949e}"
$report_html += ".sw{overflow-x:auto;max-height:380px;overflow-y:auto}"
$report_html += "table{width:100%;border-collapse:collapse;font-size:12px}"
$report_html += "thead tr{background:#1c2128;position:sticky;top:0}"
$report_html += "th{padding:7px 11px;text-align:left;color:#8b949e;font-weight:500;border-bottom:1px solid #30363d;white-space:nowrap}"
$report_html += "td{padding:6px 11px;border-bottom:1px solid #21262d;color:#c9d1d9;word-break:break-all;vertical-align:top}"
$report_html += "tr:last-child td{border-bottom:none}"
$report_html += "tr:hover td{background:#1c2128}"
$report_html += "td.w{color:#f0883e;font-weight:500}"
$report_html += "#sf{width:100%;padding:7px 12px;background:#21262d;border:1px solid #30363d;border-radius:6px;color:#c9d1d9;font-size:13px;margin-bottom:18px}"
$report_html += "#sf:focus{outline:none;border-color:#58a6ff}"
$report_html += ".hidden{display:none}"
$report_html += "</style></head><body>"
$report_html += "<nav id='sb'><div class='logo'><h1>Azure Enum Report</h1><p>$gen_time</p></div>"
$report_html += "<a class='gb' href='graph.html' target='_blank'>Graph View</a>"
$report_html += "<ul>$sidebar</ul></nav>"
$report_html += "<main id='main'><div class='ph'><div><h1>Azure Enumeration Report</h1><p>$gen_time</p></div>"
$report_html += "<a class='gb2' href='graph.html' target='_blank'>Graph View</a></div>"
$report_html += "<input id='sf' type='text' placeholder='Filter tables...' oninput='ft(this.value)'>"
$report_html += $content
$report_html += "</main><script>"
$report_html += "function tog(h){var w=h.nextElementSibling;if(w)w.classList.toggle('hidden');}"
$report_html += "function ft(q){q=q.toLowerCase();document.querySelectorAll('tbody tr').forEach(function(r){r.style.display=r.textContent.toLowerCase().indexOf(q)>=0?'':' none';});}"
$report_html += "</script></body></html>"

$report_html | Out-File -FilePath $report_file -Encoding utf8
Write-Host "  [+] report.html written ($((Get-Item $report_file).Length) bytes)" -ForegroundColor Green

# ============================================================
# BUILD GRAPH.HTML
# ============================================================

$nodes_js = ($nodes_raw | ForEach-Object {
    $id    = ("$($_.id)"    -replace '"','\"' -replace "'","\'")
    $label = ("$($_.label)" -replace '"','\"' -replace "'","\'")
    $type  = ("$($_.type)"  -replace '"','\"')
    $sub   = ("$($_.sub)"   -replace '"','\"' -replace "'","\'")
    "{`"id`":`"$id`",`"label`":`"$label`",`"type`":`"$type`",`"sub`":`"$sub`"}"
}) -join ","

$links_js = ($links_raw | ForEach-Object {
    $s = ("$($_.source)" -replace '"','\"' -replace "'","\'")
    $t = ("$($_.target)" -replace '"','\"' -replace "'","\'")
    $r = ("$($_.rel)"    -replace '"','\"')
    "{`"source`":`"$s`",`"target`":`"$t`",`"rel`":`"$r`"}"
}) -join ","

$graph_html  = "<!DOCTYPE html><html lang='en'><head><meta charset='UTF-8'><title>Azure Graph</title><style>"
$graph_html += "*{box-sizing:border-box;margin:0;padding:0}"
$graph_html += "body{background:#0d1117;color:#c9d1d9;font-family:'Segoe UI',sans-serif;overflow:hidden}"
$graph_html += "#tb{position:fixed;top:0;left:0;right:0;height:46px;background:#161b22;border-bottom:1px solid #30363d;display:flex;align-items:center;gap:8px;padding:0 14px;z-index:100}"
$graph_html += "#tb h1{font-size:13px;font-weight:600;color:#e6edf3;margin-right:6px}"
$graph_html += ".btn{background:#21262d;border:1px solid #30363d;color:#c9d1d9;padding:4px 10px;border-radius:5px;font-size:11px;cursor:pointer}"
$graph_html += ".btn:hover{background:#30363d}"
$graph_html += ".btn.on{background:#1f6feb;border-color:#1f6feb;color:#fff}"
$graph_html += "#sq{background:#21262d;border:1px solid #30363d;color:#c9d1d9;padding:4px 9px;border-radius:5px;font-size:11px;width:150px}"
$graph_html += "#sq:focus{outline:none;border-color:#58a6ff}"
$graph_html += "#lg{display:flex;gap:8px;margin-left:auto;align-items:center;flex-wrap:wrap}"
$graph_html += ".ld{display:flex;align-items:center;gap:4px;font-size:10px;color:#8b949e}"
$graph_html += ".lc{width:9px;height:9px;border-radius:50%}"
$graph_html += "#info{position:fixed;bottom:0;left:0;right:0;background:#161b22;border-top:1px solid #30363d;padding:8px 14px;font-size:12px;color:#8b949e;z-index:100}"
$graph_html += "svg{cursor:grab;margin-top:46px}"
$graph_html += "svg:active{cursor:grabbing}"
$graph_html += ".lnk{stroke-opacity:.35;stroke-width:1px}"
$graph_html += ".lbl{font-size:9px;fill:#8b949e;pointer-events:none;text-anchor:middle}"
$graph_html += ".ic{font-size:8px;fill:#fff;pointer-events:none;text-anchor:middle;dominant-baseline:central;font-weight:600}"
$graph_html += ".hl circle{stroke:#fff;stroke-width:3px}"
$graph_html += ".dm circle,.dm text{opacity:.12}"
$graph_html += ".dm.lnk{stroke-opacity:.04}"
$graph_html += "</style></head><body>"
$graph_html += "<div id='tb'><h1>Azure Graph</h1>"
$graph_html += "<button class='btn on' onclick='ftype(`"`")'>All</button>"
$graph_html += "<button class='btn' onclick='ftype(`"user`")'>Users</button>"
$graph_html += "<button class='btn' onclick='ftype(`"group`")'>Groups</button>"
$graph_html += "<button class='btn' onclick='ftype(`"sp`")'>SPs</button>"
$graph_html += "<button class='btn' onclick='ftype(`"role`")'>Roles</button>"
$graph_html += "<button class='btn' onclick='ftype(`"vm`")'>VMs</button>"
$graph_html += "<button class='btn' onclick='ftype(`"keyvault`")'>KVs</button>"
$graph_html += "<button class='btn' onclick='ftype(`"storage`")'>Storage</button>"
$graph_html += "<button class='btn' onclick='ftype(`"rg`")'>RGs</button>"
$graph_html += "<input id='sq' type='text' placeholder='Search...' oninput='fsearch(this.value)'>"
$graph_html += "<div id='lg'>"
$graph_html += "<div class='ld'><div class='lc' style='background:#58a6ff'></div>User</div>"
$graph_html += "<div class='ld'><div class='lc' style='background:#3fb950'></div>Group</div>"
$graph_html += "<div class='ld'><div class='lc' style='background:#d2a8ff'></div>SP</div>"
$graph_html += "<div class='ld'><div class='lc' style='background:#f0883e'></div>Role</div>"
$graph_html += "<div class='ld'><div class='lc' style='background:#56d364'></div>VM</div>"
$graph_html += "<div class='ld'><div class='lc' style='background:#ff7b72'></div>KV</div>"
$graph_html += "<div class='ld'><div class='lc' style='background:#79c0ff'></div>Storage</div>"
$graph_html += "<div class='ld'><div class='lc' style='background:#e3b341'></div>WebApp</div>"
$graph_html += "<div class='ld'><div class='lc' style='background:#8b949e'></div>RG/Sub</div>"
$graph_html += "</div></div>"
$graph_html += "<svg id='g'></svg>"
$graph_html += "<div id='info'>Click a node for details &mdash; Drag to move &mdash; Scroll to zoom</div>"
$graph_html += "<script src='https://cdnjs.cloudflare.com/ajax/libs/d3/7.8.5/d3.min.js'></script><script>"
$graph_html += "var AN=[$nodes_js];var AL=[$links_js];"
$graph_html += "var C={user:'#58a6ff',group:'#3fb950',sp:'#d2a8ff',role:'#f0883e',resource:'#ffa657',"
$graph_html += "keyvault:'#ff7b72',storage:'#79c0ff',vm:'#56d364',webapp:'#e3b341',"
$graph_html += "subscription:'#8b949e',rg:'#6e7681',sql:'#f78166',aks:'#39d353',"
$graph_html += "acr:'#bc8cff',automation:'#ffb347'};"
$graph_html += "var R={subscription:22,rg:16,user:12,group:13,sp:12,role:11,vm:13,"
$graph_html += "keyvault:13,storage:12,webapp:11,sql:12,aks:13,acr:11,automation:11};"
$graph_html += "var IC={user:'U',group:'G',sp:'SP',role:'R',vm:'VM',keyvault:'KV',"
$graph_html += "storage:'S',webapp:'W',subscription:'SUB',rg:'RG',sql:'SQL',aks:'AKS',acr:'ACR',automation:'AU'};"
$graph_html += "var sim,gEl,lnkS,ndS,lblS,curFilt='';"
$graph_html += "function nc(d){return C[d.type]||'#8b949e';}"
$graph_html += "function nr(d){return R[d.type]||10;}"
$graph_html += "function init(nodes,links){"
$graph_html += "d3.select('#g').selectAll('*').remove();"
$graph_html += "var W=window.innerWidth,H=window.innerHeight-82;"
$graph_html += "var svg=d3.select('#g').attr('width',W).attr('height',H);"
$graph_html += "var zm=d3.zoom().scaleExtent([0.03,4]).on('zoom',function(e){gEl.attr('transform',e.transform);});"
$graph_html += "svg.call(zm);"
$graph_html += "var defs=svg.append('defs');"
$graph_html += "Object.keys(C).forEach(function(t){"
$graph_html += "defs.append('marker').attr('id','a'+t).attr('viewBox','0 0 10 10')"
$graph_html += ".attr('refX',22).attr('refY',5).attr('markerWidth',5).attr('markerHeight',5)"
$graph_html += ".attr('orient','auto-start-reverse').append('path').attr('d','M0,0L10,5L0,10z')"
$graph_html += ".attr('fill',C[t]).attr('opacity',.5);});"
$graph_html += "gEl=svg.append('g');"
$graph_html += "sim=d3.forceSimulation(nodes)"
$graph_html += ".force('link',d3.forceLink(links).id(function(d){return d.id;}).distance(90).strength(.4))"
$graph_html += ".force('charge',d3.forceManyBody().strength(-200))"
$graph_html += ".force('center',d3.forceCenter(W/2,H/2))"
$graph_html += ".force('col',d3.forceCollide().radius(function(d){return nr(d)+5;}));"
$graph_html += "lnkS=gEl.append('g').selectAll('line').data(links).join('line')"
$graph_html += ".attr('class','lnk')"
$graph_html += ".attr('stroke',function(d){return C[d.target.type]||'#8b949e';})"
$graph_html += ".attr('marker-end',function(d){return 'url(#a'+(d.target.type||'rg')+')'});;"
$graph_html += "var ng=gEl.append('g').selectAll('g').data(nodes).join('g')"
$graph_html += ".call(d3.drag()"
$graph_html += ".on('start',function(e,d){if(!e.active)sim.alphaTarget(.3).restart();d.fx=d.x;d.fy=d.y;})"
$graph_html += ".on('drag',function(e,d){d.fx=e.x;d.fy=e.y;})"
$graph_html += ".on('end',function(e,d){if(!e.active)sim.alphaTarget(0);d.fx=null;d.fy=null;}))"
$graph_html += ".on('click',function(e,d){showInfo(d);})"
$graph_html += ".on('mouseover',function(e,d){hl(d,true);})"
$graph_html += ".on('mouseout',function(e,d){hl(d,false);});"
$graph_html += "ng.append('circle').attr('r',function(d){return nr(d);})"
$graph_html += ".attr('fill',function(d){return nc(d);})"
$graph_html += ".attr('stroke',function(d){return d3.color(nc(d)).darker(1);}).attr('stroke-width',1.5);"
$graph_html += "ng.append('text').attr('class','ic').text(function(d){return IC[d.type]||'?';});"
$graph_html += "lblS=gEl.append('g').selectAll('text').data(nodes).join('text')"
$graph_html += ".attr('class','lbl').attr('dy',function(d){return nr(d)+11;})"
$graph_html += ".text(function(d){return d.label.length>18?d.label.slice(0,16)+'..':d.label;});"
$graph_html += "ndS=ng;"
$graph_html += "sim.on('tick',function(){"
$graph_html += "lnkS.attr('x1',function(d){return d.source.x;}).attr('y1',function(d){return d.source.y;})"
$graph_html += ".attr('x2',function(d){return d.target.x;}).attr('y2',function(d){return d.target.y;});"
$graph_html += "ndS.attr('transform',function(d){return 'translate('+d.x+','+d.y+')';});"
$graph_html += "lblS.attr('x',function(d){return d.x;}).attr('y',function(d){return d.y;});});}"
$graph_html += "function showInfo(d){"
$graph_html += "var conn=AL.filter(function(l){"
$graph_html += "return (l.source===d.id||l.target===d.id||l.source.id===d.id||l.target.id===d.id);"
$graph_html += "}).map(function(l){"
$graph_html += "var o=(l.source.id||l.source)===d.id?(l.target.label||l.target):(l.source.label||l.source);"
$graph_html += "return l.rel+' -> '+o;"
$graph_html += "}).join('  |  ');"
$graph_html += "document.getElementById('info').innerHTML="
$graph_html += "'<span style=color:#e6edf3>['+d.type.toUpperCase()+']</span> '"
$graph_html += "+'<span style=color:#58a6ff>'+d.label+'</span>'"
$graph_html += "+(d.sub?' <span style=color:#8b949e>sub:'+d.sub+'</span>':'')"
$graph_html += "+(conn?' &mdash; '+conn:'');}"
$graph_html += "function hl(d,on){"
$graph_html += "if(!on){ndS.classed('hl',false).classed('dm',false);lnkS.classed('dm',false);return;}"
$graph_html += "var nb=new Set([d.id]);"
$graph_html += "AL.forEach(function(l){"
$graph_html += "var s=l.source.id||l.source,t=l.target.id||l.target;"
$graph_html += "if(s===d.id)nb.add(t);if(t===d.id)nb.add(s);});"
$graph_html += "ndS.classed('hl',function(n){return n.id===d.id;});"
$graph_html += "ndS.classed('dm',function(n){return !nb.has(n.id);});"
$graph_html += "lnkS.classed('dm',function(l){"
$graph_html += "var s=l.source.id||l.source,t=l.target.id||l.target;"
$graph_html += "return s!==d.id&&t!==d.id;});}"
$graph_html += "function ftype(t){"
$graph_html += "curFilt=t;"
$graph_html += "document.querySelectorAll('.btn').forEach(function(b){b.classList.remove('on');});"
$graph_html += "event.target.classList.add('on');"
$graph_html += "var ns=t===''?AN:AN.filter(function(n){return n.type===t;});"
$graph_html += "var ids=new Set(ns.map(function(n){return n.id;}));"
$graph_html += "var ls=AL.filter(function(l){return ids.has(l.source.id||l.source)&&ids.has(l.target.id||l.target);});"
$graph_html += "init(JSON.parse(JSON.stringify(ns)),JSON.parse(JSON.stringify(ls)));}"
$graph_html += "function fsearch(q){"
$graph_html += "if(!ndS)return;"
$graph_html += "q=q.toLowerCase();"
$graph_html += "ndS.classed('hl',function(d){return d.label.toLowerCase().indexOf(q)>=0&&q.length>0;});"
$graph_html += "ndS.classed('dm',function(d){return q.length>0&&d.label.toLowerCase().indexOf(q)<0;});"
$graph_html += "lblS.classed('dm',function(d){return q.length>0&&d.label.toLowerCase().indexOf(q)<0;});}"
$graph_html += "window.addEventListener('resize',function(){ftype(curFilt);});"
$graph_html += "init(JSON.parse(JSON.stringify(AN)),JSON.parse(JSON.stringify(AL)));"
$graph_html += "</script></body></html>"

$graph_html | Out-File -FilePath $graph_file -Encoding utf8
Write-Host "  [+] graph.html written ($((Get-Item $graph_file).Length) bytes)" -ForegroundColor Green
