# ============================================================
#  Azure Enumeration Script
#  Usage: .\azure_enum.ps1
#  Requires: python -m azure.cli (already logged in)
#  Output:  report.html  +  graph.html  (linked from report)
# ============================================================

$az         = "python -m azure.cli"
$timestamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
$output_dir = ".\azure_enum_$timestamp"
$html_file  = "$output_dir\report.html"
$graph_file = "$output_dir\graph.html"
New-Item -ItemType Directory -Path $output_dir | Out-Null

# Global structures
$report   = [ordered]@{}   # for the table report
$gNodes   = [System.Collections.Generic.List[hashtable]]::new()
$gLinks   = [System.Collections.Generic.List[hashtable]]::new()
$gNodeIds = @{}            # dedup: id -> $true

# ============================================================
# HELPERS
# ============================================================

function Run-Az-Json {
    param([string]$args_str)
    try {
        $result = (Invoke-Expression "$az $args_str --output json") 2>&1 |
                  Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }
        if ($result) { return ($result | ConvertFrom-Json) }
    } catch {}
    return @()
}

function Add-Section {
    param([string]$sub,[string]$title,[string]$icon,[object]$data,[string[]]$fields)
    if (-not $report.Contains($sub)) { $report[$sub] = @() }
    $report[$sub] += [ordered]@{ title=$title; icon=$icon; data=$data; fields=$fields }
}

# Add a node to the graph (dedup by id)
function GNode {
    param([string]$id,[string]$label,[string]$type,[string]$sub="")
    if (-not $gNodeIds.ContainsKey($id)) {
        $gNodeIds[$id] = $true
        $gNodes.Add(@{ id=$id; label=$label; type=$type; sub=$sub })
    }
}

# Add a directed edge to the graph
function GLink {
    param([string]$src,[string]$tgt,[string]$rel)
    $gLinks.Add(@{ source=$src; target=$tgt; rel=$rel })
}

function Render-TableRows {
    param([object]$items,[string[]]$fields)
    if (-not $items -or $items.Count -eq 0) {
        return "<tr><td colspan='$($fields.Count)' style='color:#888;font-style:italic'>No data</td></tr>"
    }
    $rows = ""
    foreach ($item in $items) {
        $rows += "<tr>"
        foreach ($f in $fields) {
            $val = $item.$f; if ($null -eq $val) { $val = "-" }
            $cls = ""
            if ("$val" -match "0\.0\.0\.0|Owner|Contributor|admin|password|secret" -and "$val" -notmatch "^false$") { $cls = " class='warn'" }
            $rows += "<td$cls>$([System.Web.HttpUtility]::HtmlEncode("$val"))</td>"
        }
        $rows += "</tr>"
    }
    return $rows
}

# ============================================================
# GRAPH HTML BUILDER
# ============================================================
function Build-Graph-HTML {
    param([string]$generated_at)

    # Serialize nodes + links to JSON for D3
    $nodes_json = ($gNodes | ForEach-Object {
        $id    = $_.id    -replace "'","\\'"
        $label = $_.label -replace "'","\\'" -replace '"','\"'
        $type  = $_.type
        $sub   = $_.sub   -replace "'","\\'"
        "{ `"id`":`"$id`", `"label`":`"$label`", `"type`":`"$type`", `"sub`":`"$sub`" }"
    }) -join ","

    $links_json = ($gLinks | ForEach-Object {
        $s = $_.source -replace "'","\\'"
        $t = $_.target -replace "'","\\'"
        $r = $_.rel
        "{ `"source`":`"$s`", `"target`":`"$t`", `"rel`":`"$r`" }"
    }) -join ","

    return @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Azure Graph</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{background:#0d1117;color:#c9d1d9;font-family:'Segoe UI',Arial,sans-serif;overflow:hidden}
#toolbar{position:fixed;top:0;left:0;right:0;height:48px;background:#161b22;border-bottom:1px solid #30363d;display:flex;align-items:center;gap:12px;padding:0 16px;z-index:100}
#toolbar h1{font-size:14px;font-weight:600;color:#e6edf3;margin-right:8px}
.btn{background:#21262d;border:1px solid #30363d;color:#c9d1d9;padding:5px 12px;border-radius:6px;font-size:12px;cursor:pointer}
.btn:hover{background:#30363d;color:#e6edf3}
.btn.active{background:#1f6feb;border-color:#1f6feb;color:#fff}
#search{background:#21262d;border:1px solid #30363d;color:#c9d1d9;padding:5px 10px;border-radius:6px;font-size:12px;width:180px}
#search:focus{outline:none;border-color:#58a6ff}
#legend{display:flex;gap:10px;margin-left:auto;align-items:center}
.leg{display:flex;align-items:center;gap:5px;font-size:11px;color:#8b949e}
.leg-dot{width:10px;height:10px;border-radius:50%}
#info{position:fixed;bottom:0;left:0;right:0;background:#161b22;border-top:1px solid #30363d;padding:10px 16px;font-size:12px;color:#8b949e;z-index:100;min-height:36px}
#info span{color:#e6edf3}
#back{position:fixed;top:10px;right:16px;z-index:200}
svg{cursor:grab}
svg:active{cursor:grabbing}
.node circle{stroke-width:1.5px;cursor:pointer;transition:r .15s}
.node circle:hover{r:14}
.node text{font-size:10px;fill:#c9d1d9;pointer-events:none;text-anchor:middle;dominant-baseline:central}
.link{stroke-opacity:0.4;stroke-width:1px}
.link-label{font-size:9px;fill:#8b949e;pointer-events:none}
.node.highlighted circle{stroke-width:3px;stroke:#fff}
.node.dimmed circle{opacity:0.15}
.node.dimmed text{opacity:0.15}
.link.dimmed{stroke-opacity:0.05}
</style>
</head>
<body>
<div id="toolbar">
  <h1>Azure Relationship Graph</h1>
  <button class="btn active" id="btnAll" onclick="filterType('')">All</button>
  <button class="btn" id="btnUsers"  onclick="filterType('user')">Users</button>
  <button class="btn" id="btnGroups" onclick="filterType('group')">Groups</button>
  <button class="btn" id="btnSPs"    onclick="filterType('sp')">SPs</button>
  <button class="btn" id="btnRoles"  onclick="filterType('role')">Roles</button>
  <button class="btn" id="btnRes"    onclick="filterType('resource')">Resources</button>
  <button class="btn" id="btnSub"    onclick="filterType('subscription')">Subs</button>
  <input id="search" type="text" placeholder="Search node..." oninput="searchNode(this.value)">
  <div id="legend">
    <div class="leg"><div class="leg-dot" style="background:#58a6ff"></div>User</div>
    <div class="leg"><div class="leg-dot" style="background:#3fb950"></div>Group</div>
    <div class="leg"><div class="leg-dot" style="background:#d2a8ff"></div>SP</div>
    <div class="leg"><div class="leg-dot" style="background:#f0883e"></div>Role</div>
    <div class="leg"><div class="leg-dot" style="background:#ffa657"></div>Resource</div>
    <div class="leg"><div class="leg-dot" style="background:#ff7b72"></div>KeyVault</div>
    <div class="leg"><div class="leg-dot" style="background:#79c0ff"></div>Storage</div>
    <div class="leg"><div class="leg-dot" style="background:#56d364"></div>VM</div>
    <div class="leg"><div class="leg-dot" style="background:#e3b341"></div>WebApp</div>
    <div class="leg"><div class="leg-dot" style="background:#8b949e"></div>RG / Sub</div>
  </div>
</div>

<svg id="graph"></svg>

<div id="info">Click a node to see details &mdash; Generated: $generated_at</div>

<script src="https://cdnjs.cloudflare.com/ajax/libs/d3/7.8.5/d3.min.js"></script>
<script>
const ALL_NODES = [$nodes_json];
const ALL_LINKS = [$links_json];

const COLOR = {
  user:'#58a6ff', group:'#3fb950', sp:'#d2a8ff', role:'#f0883e',
  resource:'#ffa657', keyvault:'#ff7b72', storage:'#79c0ff',
  vm:'#56d364', webapp:'#e3b341', subscription:'#8b949e',
  rg:'#8b949e', sql:'#f78166', aks:'#39d353', acr:'#bc8cff',
  automation:'#ffb347', default:'#8b949e'
};

const RADIUS = {
  subscription:20, rg:16, user:12, group:13, sp:12,
  role:11, vm:13, keyvault:13, storage:12, webapp:11,
  sql:12, aks:13, acr:11, automation:11, resource:10, default:10
};

let simulation, svgEl, g, linkSel, nodeSel, labelSel;
let currentFilter = '';
let width = window.innerWidth;
let height = window.innerHeight - 48 - 36;

function nodeColor(d) { return COLOR[d.type] || COLOR.default; }
function nodeRadius(d) { return RADIUS[d.type] || RADIUS.default; }

function init(nodes, links) {
  d3.select('#graph').selectAll('*').remove();

  width  = window.innerWidth;
  height = window.innerHeight - 48 - 36;

  svgEl = d3.select('#graph')
    .attr('width', width).attr('height', height)
    .style('margin-top','48px');

  const zoom = d3.zoom().scaleExtent([0.05, 4])
    .on('zoom', e => g.attr('transform', e.transform));
  svgEl.call(zoom);

  // Arrow markers per type
  const defs = svgEl.append('defs');
  Object.entries(COLOR).forEach(([t, c]) => {
    defs.append('marker')
      .attr('id','arr-'+t).attr('viewBox','0 0 10 10')
      .attr('refX',20).attr('refY',5)
      .attr('markerWidth',6).attr('markerHeight',6)
      .attr('orient','auto-start-reverse')
      .append('path').attr('d','M0,0L10,5L0,10z')
      .attr('fill',c).attr('opacity',0.6);
  });

  g = svgEl.append('g');

  simulation = d3.forceSimulation(nodes)
    .force('link', d3.forceLink(links).id(d => d.id).distance(d => {
      if (d.rel === 'contains') return 80;
      if (d.rel === 'memberOf') return 70;
      return 100;
    }).strength(0.4))
    .force('charge', d3.forceManyBody().strength(-220))
    .force('center', d3.forceCenter(width/2, height/2))
    .force('collision', d3.forceCollide().radius(d => nodeRadius(d) + 6));

  linkSel = g.append('g').selectAll('line')
    .data(links).join('line')
    .attr('class','link')
    .attr('stroke', d => COLOR[d.target.type] || COLOR.default)
    .attr('marker-end', d => 'url(#arr-'+(d.target.type||'default')+')');

  const nodeG = g.append('g').selectAll('g')
    .data(nodes).join('g')
    .attr('class','node')
    .call(d3.drag()
      .on('start', (e,d) => { if(!e.active) simulation.alphaTarget(0.3).restart(); d.fx=d.x; d.fy=d.y; })
      .on('drag',  (e,d) => { d.fx=e.x; d.fy=e.y; })
      .on('end',   (e,d) => { if(!e.active) simulation.alphaTarget(0); d.fx=null; d.fy=null; }))
    .on('click', (e,d) => showInfo(d))
    .on('mouseover', (e,d) => highlight(d, true))
    .on('mouseout',  (e,d) => highlight(d, false));

  nodeG.append('circle')
    .attr('r', d => nodeRadius(d))
    .attr('fill', d => nodeColor(d))
    .attr('stroke', d => d3.color(nodeColor(d)).darker(1));

  // Icon text inside node
  nodeG.append('text')
    .attr('dy','0.35em').attr('font-size','9px')
    .text(d => {
      const icons = {user:'U',group:'G',sp:'SP',role:'R',vm:'VM',
                     keyvault:'KV',storage:'ST',webapp:'WA',
                     subscription:'S',rg:'RG',sql:'SQL',
                     aks:'AKS',acr:'ACR',automation:'AU'};
      return icons[d.type] || '?';
    });

  // Labels below nodes
  labelSel = g.append('g').selectAll('text')
    .data(nodes).join('text')
    .attr('class','link-label')
    .attr('text-anchor','middle')
    .attr('dy', d => nodeRadius(d) + 12)
    .text(d => d.label.length > 20 ? d.label.slice(0,18)+'..' : d.label);

  nodeSel = nodeG;

  simulation.on('tick', () => {
    linkSel
      .attr('x1', d => d.source.x).attr('y1', d => d.source.y)
      .attr('x2', d => d.target.x).attr('y2', d => d.target.y);
    nodeSel.attr('transform', d => 'translate('+d.x+','+d.y+')');
    labelSel.attr('x', d => d.x).attr('y', d => d.y);
  });
}

function showInfo(d) {
  const connected = ALL_LINKS
    .filter(l => l.source === d.id || l.target === d.id || l.source.id === d.id || l.target.id === d.id)
    .map(l => {
      const other = (l.source.id||l.source) === d.id ? (l.target.label||l.target) : (l.source.label||l.source);
      return l.rel + ' → ' + other;
    }).join(' &nbsp;|&nbsp; ');
  document.getElementById('info').innerHTML =
    '<span>['+d.type.toUpperCase()+']</span> <span style="color:#58a6ff">'+d.label+'</span>' +
    (d.sub ? ' &nbsp;<span style="color:#8b949e">sub: '+d.sub+'</span>' : '') +
    (connected ? ' &nbsp;&mdash;&nbsp; ' + connected : '');
}

function highlight(d, on) {
  if (!on) {
    nodeSel.classed('highlighted dimmed', false);
    linkSel.classed('dimmed', false);
    return;
  }
  const neighbors = new Set();
  neighbors.add(d.id);
  ALL_LINKS.forEach(l => {
    const s = l.source.id||l.source, t = l.target.id||l.target;
    if (s === d.id) neighbors.add(t);
    if (t === d.id) neighbors.add(s);
  });
  nodeSel.classed('highlighted', n => n.id === d.id);
  nodeSel.classed('dimmed', n => !neighbors.has(n.id));
  linkSel.classed('dimmed', l => {
    const s = l.source.id||l.source, t = l.target.id||l.target;
    return s !== d.id && t !== d.id;
  });
}

function filterType(type) {
  currentFilter = type;
  document.querySelectorAll('#toolbar .btn').forEach(b => b.classList.remove('active'));
  document.getElementById('btn' + (
    type === ''           ? 'All'   :
    type === 'user'       ? 'Users' :
    type === 'group'      ? 'Groups':
    type === 'sp'         ? 'SPs'   :
    type === 'role'       ? 'Roles' :
    type === 'resource'   ? 'Res'   :
    type === 'subscription'? 'Sub'  : 'All'
  )).classList.add('active');

  const nodes = type === '' ? ALL_NODES : ALL_NODES.filter(n => n.type === type);
  const nodeIds = new Set(nodes.map(n => n.id));
  const links = ALL_LINKS.filter(l =>
    nodeIds.has(l.source.id||l.source) && nodeIds.has(l.target.id||l.target));
  init(JSON.parse(JSON.stringify(nodes)), JSON.parse(JSON.stringify(links)));
}

function searchNode(q) {
  if (!q) { nodeSel.classed('highlighted dimmed', false); return; }
  q = q.toLowerCase();
  nodeSel.classed('highlighted', d => d.label.toLowerCase().includes(q));
  nodeSel.classed('dimmed',      d => !d.label.toLowerCase().includes(q));
  labelSel.classed('dimmed',     d => !d.label.toLowerCase().includes(q));
}

window.addEventListener('resize', () => filterType(currentFilter));

// Boot
init(JSON.parse(JSON.stringify(ALL_NODES)), JSON.parse(JSON.stringify(ALL_LINKS)));
</script>
</body>
</html>
"@
}

# ============================================================
# REPORT HTML BUILDER
# ============================================================
function Build-HTML {
    param([string]$generated_at,[object]$subs_info)
    $sub_count     = $subs_info.Count
    $sidebar_items = ""
    $sections_html = ""

    foreach ($sub_key in $report.Keys) {
        $sidebar_items += "<li><a href='#$sub_key' class='sub-link'>$sub_key</a><ul>"
        $sections_html += "<div class='sub-block' id='$sub_key'><h2>$sub_key</h2>"
        foreach ($section in $report[$sub_key]) {
            $sec_title  = $section.title
            $sec_icon   = $section.icon
            $sec_data   = $section.data
            $sec_fields = $section.fields
            $sec_id     = ($sub_key + "_" + $sec_title) -replace '[^\w]','_'
            $count      = if ($sec_data) { $sec_data.Count } else { 0 }
            $sidebar_items += "<li><a href='#$sec_id'>$sec_icon $sec_title <span class='badge'>$count</span></a></li>"
            $headers = ""; foreach ($f in $sec_fields) { $headers += "<th>$f</th>" }
            $rows = Render-TableRows -items $sec_data -fields $sec_fields
            $sections_html += @"
<div class='section' id='$sec_id'>
  <div class='section-header'>
    <span class='section-icon'>$sec_icon</span>
    <span class='section-title'>$sec_title</span>
    <span class='count-badge'>$count items</span>
  </div>
  <div class='table-wrap'>
    <table><thead><tr>$headers</tr></thead><tbody>$rows</tbody></table>
  </div>
</div>
"@
        }
        $sections_html += "</div>"
        $sidebar_items += "</ul></li>"
    }

    return @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Azure Enumeration Report</title>
<style>
  *{box-sizing:border-box;margin:0;padding:0}
  body{font-family:'Segoe UI',Arial,sans-serif;background:#0f1117;color:#c9d1d9;display:flex;min-height:100vh}
  a{color:#58a6ff;text-decoration:none} a:hover{text-decoration:underline}
  #sidebar{width:260px;background:#161b22;border-right:1px solid #30363d;padding:20px 0;overflow-y:auto;position:fixed;top:0;bottom:0;left:0}
  #sidebar .logo{padding:0 20px 16px;border-bottom:1px solid #30363d;margin-bottom:12px}
  #sidebar .logo h1{font-size:15px;font-weight:600;color:#e6edf3}
  #sidebar .logo .meta{font-size:11px;color:#8b949e;margin-top:4px}
  #sidebar .graph-btn{display:block;margin:0 16px 12px;padding:8px 12px;background:#1f6feb;border-radius:6px;color:#fff;font-size:12px;font-weight:600;text-align:center}
  #sidebar .graph-btn:hover{background:#388bfd;text-decoration:none}
  #sidebar ul{list-style:none;padding:0 10px}
  #sidebar ul li{margin:2px 0}
  #sidebar ul li a{display:flex;align-items:center;justify-content:space-between;padding:5px 10px;border-radius:6px;font-size:12px;color:#8b949e;transition:background .15s,color .15s}
  #sidebar ul li a:hover{background:#21262d;color:#e6edf3;text-decoration:none}
  #sidebar ul ul{padding-left:10px;border-left:1px solid #30363d;margin-left:10px}
  .sub-link{font-weight:600;font-size:13px;color:#c9d1d9 !important}
  .badge{background:#21262d;border:1px solid #30363d;border-radius:10px;padding:1px 7px;font-size:10px;color:#8b949e}
  #main{margin-left:260px;padding:30px;flex:1;max-width:calc(100% - 260px)}
  .page-header{margin-bottom:30px;padding-bottom:20px;border-bottom:1px solid #30363d;display:flex;align-items:center;justify-content:space-between}
  .page-header h1{font-size:22px;font-weight:600;color:#e6edf3}
  .page-header .subtitle{font-size:13px;color:#8b949e;margin-top:6px}
  .graph-link-btn{display:inline-flex;align-items:center;gap:8px;background:#1f6feb;color:#fff;padding:8px 18px;border-radius:8px;font-size:13px;font-weight:600}
  .graph-link-btn:hover{background:#388bfd;text-decoration:none}
  .sub-block{margin-bottom:40px}
  .sub-block h2{font-size:16px;font-weight:600;color:#e6edf3;margin-bottom:16px;padding-bottom:8px;border-bottom:1px solid #30363d}
  .section{background:#161b22;border:1px solid #30363d;border-radius:8px;margin-bottom:16px;overflow:hidden}
  .section-header{display:flex;align-items:center;gap:10px;padding:12px 16px;background:#1c2128;border-bottom:1px solid #30363d;cursor:pointer}
  .section-header:hover{background:#21262d}
  .section-icon{font-size:16px}
  .section-title{font-size:14px;font-weight:500;color:#e6edf3;flex:1}
  .count-badge{background:#0d1117;border:1px solid #30363d;border-radius:12px;padding:2px 10px;font-size:11px;color:#8b949e}
  .table-wrap{overflow-x:auto;max-height:400px;overflow-y:auto}
  table{width:100%;border-collapse:collapse;font-size:12px}
  thead tr{background:#1c2128;position:sticky;top:0}
  th{padding:8px 12px;text-align:left;color:#8b949e;font-weight:500;border-bottom:1px solid #30363d;white-space:nowrap}
  td{padding:7px 12px;border-bottom:1px solid #21262d;color:#c9d1d9;word-break:break-all;vertical-align:top}
  tr:last-child td{border-bottom:none}
  tr:hover td{background:#1c2128}
  td.warn{color:#f0883e;font-weight:500}
  .search-bar{width:100%;padding:8px 14px;background:#21262d;border:1px solid #30363d;border-radius:6px;color:#c9d1d9;font-size:13px;margin-bottom:20px}
  .search-bar:focus{outline:none;border-color:#58a6ff}
  .hidden{display:none}
</style>
</head>
<body>
<nav id="sidebar">
  <div class="logo">
    <h1>Azure Enum Report</h1>
    <div class="meta">$generated_at</div>
    <div class="meta">$sub_count subscription(s)</div>
  </div>
  <a class="graph-btn" href="graph.html" target="_blank">&#9653; Open Relationship Graph</a>
  <ul>$sidebar_items</ul>
</nav>
<main id="main">
  <div class="page-header">
    <div>
      <h1>Azure Enumeration Report</h1>
      <div class="subtitle">$generated_at &mdash; $sub_count subscription(s) scanned</div>
    </div>
    <a class="graph-link-btn" href="graph.html" target="_blank">&#9653; Relationship Graph</a>
  </div>
  <input class="search-bar" type="text" placeholder="Filter any table..." oninput="filterTables(this.value)">
  $sections_html
</main>
<script>
document.querySelectorAll('.section-header').forEach(h => {
  h.addEventListener('click', () => { const w=h.nextElementSibling; if(w) w.classList.toggle('hidden'); });
});
function filterTables(q) {
  q = q.toLowerCase();
  document.querySelectorAll('tbody tr').forEach(r => {
    r.style.display = r.textContent.toLowerCase().includes(q) ? '' : 'none';
  });
}
</script>
</body>
</html>
"@
}

# ============================================================
# MAIN
# ============================================================
Write-Host "`n=====================================================" -ForegroundColor Yellow
Write-Host "   AZURE ENUMERATION SCRIPT" -ForegroundColor Yellow
Write-Host "   Output -> $output_dir" -ForegroundColor Yellow
Write-Host "=====================================================`n" -ForegroundColor Yellow

Add-Type -AssemblyName System.Web

# ------------------------------------------------------------
# 1. SUBSCRIPTIONS
# ------------------------------------------------------------
Write-Host "[+] ACCOUNT & SUBSCRIPTIONS" -ForegroundColor Green
$subs = Run-Az-Json "account list"
$subs | Format-Table name, id, state -AutoSize
$subs | ConvertTo-Json | Out-File "$output_dir\01_subscriptions.json"
Write-Host "`n[+] Found $($subs.Count) subscription(s)`n" -ForegroundColor Yellow

foreach ($sub in $subs) {
    $sid  = $sub.id
    $sname = $sub.name -replace '[^\w]','_'
    # Graph: subscription node
    GNode -id "sub_$sid" -label $sub.name -type "subscription" -sub $sub.name
}

Add-Section -sub "Global" -title "Subscriptions" -icon "🔑" -data $subs -fields @("name","id","state","tenantId")

# ------------------------------------------------------------
# ITERATE SUBSCRIPTIONS
# ------------------------------------------------------------
foreach ($sub in $subs) {
    $sub_id   = $sub.id
    $sub_name = $sub.name -replace '[^\w]','_'
    $sub_nid  = "sub_$sub_id"

    Write-Host "`n[>>] Subscription: $($sub.name) [$sub_id]" -ForegroundColor Magenta
    Invoke-Expression "$az account set --subscription $sub_id" 2>&1 | Out-Null

    # --------------------------------------------------------
    # 2. ROLES
    # --------------------------------------------------------
    Write-Host "  [+] IDENTITY & PERMISSIONS" -ForegroundColor Green
    $roles = Run-Az-Json "role assignment list --all"
    $roles | ConvertTo-Json | Out-File "$output_dir\${sub_name}_02_roles.json"
    Add-Section -sub $sub.name -title "Role Assignments" -icon "🛡️" -data $roles -fields @("principalName","roleDefinitionName","scope","principalType")

    foreach ($r in $roles) {
        $rid = "role_" + ($r.roleDefinitionName -replace '[^\w]','_')
        GNode -id $rid -label $r.roleDefinitionName -type "role" -sub $sub.name
        if ($r.principalName) {
            $pid = "princ_" + ($r.principalName -replace '[^\w@.]','_')
            GNode -id $pid -label $r.principalName -type ($r.principalType.ToLower() -replace 'serviceprincipals','sp' -replace 'users','user' -replace 'groups','group') -sub $sub.name
            GLink -src $pid -tgt $rid -rel "hasRole"
        }
    }

    $custom_roles = Run-Az-Json "role definition list --custom-role-only true"
    Add-Section -sub $sub.name -title "Custom Roles" -icon "⚙️" -data $custom_roles -fields @("roleName","description")

    # --------------------------------------------------------
    # 3. AZURE AD
    # --------------------------------------------------------
    Write-Host "  [+] AZURE AD" -ForegroundColor Green

    $users = Run-Az-Json "ad user list"
    $users | ConvertTo-Json | Out-File "$output_dir\${sub_name}_03_users.json"
    Add-Section -sub $sub.name -title "AD Users" -icon "👤" -data $users -fields @("displayName","userPrincipalName","accountEnabled","userType")
    foreach ($u in $users) {
        $uid = "user_" + ($u.userPrincipalName -replace '[^\w@.]','_')
        GNode -id $uid -label $u.displayName -type "user" -sub $sub.name
        GLink -src $sub_nid -tgt $uid -rel "contains"
    }

    $groups = Run-Az-Json "ad group list"
    Add-Section -sub $sub.name -title "AD Groups" -icon "👥" -data $groups -fields @("displayName","description","securityEnabled")
    foreach ($gr in $groups) {
        $gid = "group_" + ($gr.id -replace '[^\w]','_')
        GNode -id $gid -label $gr.displayName -type "group" -sub $sub.name
        GLink -src $sub_nid -tgt $gid -rel "contains"
        # Group members
        $members = Run-Az-Json "ad group member list --group $($gr.id)"
        foreach ($m in $members) {
            $mid = "user_" + ($m.userPrincipalName -replace '[^\w@.]','_')
            GNode -id $mid -label ($m.displayName) -type "user" -sub $sub.name
            GLink -src $mid -tgt $gid -rel "memberOf"
        }
    }

    $sps = Run-Az-Json "ad sp list --all"
    $sps | ConvertTo-Json | Out-File "$output_dir\${sub_name}_03_sps.json"
    Add-Section -sub $sub.name -title "Service Principals" -icon "🤖" -data $sps -fields @("displayName","appId","servicePrincipalType","accountEnabled")
    foreach ($sp in $sps) {
        $spid = "sp_" + ($sp.appId -replace '[^\w]','_')
        GNode -id $spid -label $sp.displayName -type "sp" -sub $sub.name
        GLink -src $sub_nid -tgt $spid -rel "contains"
    }

    $apps = Run-Az-Json "ad app list --all"
    Add-Section -sub $sub.name -title "App Registrations" -icon "📱" -data $apps -fields @("displayName","appId","signInAudience")

    # --------------------------------------------------------
    # 4. RESOURCE GROUPS
    # --------------------------------------------------------
    Write-Host "  [+] RESOURCE GROUPS" -ForegroundColor Green
    $rgs = Run-Az-Json "group list"
    Add-Section -sub $sub.name -title "Resource Groups" -icon "📁" -data $rgs -fields @("name","location","provisioningState")
    foreach ($rg in $rgs) {
        $rgid = "rg_" + ($rg.name -replace '[^\w]','_') + "_" + ($sub_id -replace '[^\w]','_')
        GNode -id $rgid -label $rg.name -type "rg" -sub $sub.name
        GLink -src $sub_nid -tgt $rgid -rel "contains"
    }

    $resources = Run-Az-Json "resource list"
    $resources | ConvertTo-Json | Out-File "$output_dir\${sub_name}_04_resources.json"
    Add-Section -sub $sub.name -title "All Resources" -icon "📦" -data $resources -fields @("name","type","resourceGroup","location")

    # --------------------------------------------------------
    # 5. VMs
    # --------------------------------------------------------
    Write-Host "  [+] VIRTUAL MACHINES" -ForegroundColor Green
    $vms = Run-Az-Json "vm list"
    $vms | ConvertTo-Json | Out-File "$output_dir\${sub_name}_05_vms.json"
    Add-Section -sub $sub.name -title "Virtual Machines" -icon "💻" -data $vms -fields @("name","resourceGroup","location","powerState")
    foreach ($vm in $vms) {
        $vmid = "vm_" + ($vm.name -replace '[^\w]','_')
        $rgid = "rg_" + ($vm.resourceGroup -replace '[^\w]','_') + "_" + ($sub_id -replace '[^\w]','_')
        GNode -id $vmid -label $vm.name -type "vm" -sub $sub.name
        GLink -src $rgid -tgt $vmid -rel "contains"
    }
    $vm_ips = Run-Az-Json "vm list-ip-addresses"
    Add-Section -sub $sub.name -title "VM IPs" -icon "🌐" -data $vm_ips -fields @("virtualMachine")

    # --------------------------------------------------------
    # 6. NETWORKING
    # --------------------------------------------------------
    Write-Host "  [+] NETWORKING" -ForegroundColor Green
    $vnets = Run-Az-Json "network vnet list"
    Add-Section -sub $sub.name -title "Virtual Networks" -icon "🔗" -data $vnets -fields @("name","resourceGroup","location","addressSpace")
    $pips = Run-Az-Json "network public-ip list"
    Add-Section -sub $sub.name -title "Public IPs" -icon "🌍" -data $pips -fields @("name","resourceGroup","ipAddress","publicIPAllocationMethod")
    $nsgs = Run-Az-Json "network nsg list"
    Add-Section -sub $sub.name -title "NSGs" -icon "🔒" -data $nsgs -fields @("name","resourceGroup","location")
    $all_nsg_rules = @()
    foreach ($nsg in $nsgs) {
        $nsgname=$nsg.name; $rg=$nsg.resourceGroup
        $rules = Run-Az-Json "network nsg rule list --nsg-name $nsgname --resource-group $rg"
        foreach ($r in $rules) { $r | Add-Member -NotePropertyName "nsgName" -NotePropertyValue $nsgname -Force }
        $all_nsg_rules += $rules
    }
    Add-Section -sub $sub.name -title "NSG Rules" -icon "📋" -data $all_nsg_rules -fields @("nsgName","name","direction","access","protocol","sourceAddressPrefix","destinationPortRange","priority")

    # --------------------------------------------------------
    # 7. STORAGE
    # --------------------------------------------------------
    Write-Host "  [+] STORAGE ACCOUNTS" -ForegroundColor Green
    $storages = Run-Az-Json "storage account list"
    $storages | ConvertTo-Json | Out-File "$output_dir\${sub_name}_07_storage.json"
    Add-Section -sub $sub.name -title "Storage Accounts" -icon "🗄️" -data $storages -fields @("name","resourceGroup","location","allowBlobPublicAccess","minimumTlsVersion")
    foreach ($sa in $storages) {
        $said = "storage_" + ($sa.name -replace '[^\w]','_')
        $rgid = "rg_" + ($sa.resourceGroup -replace '[^\w]','_') + "_" + ($sub_id -replace '[^\w]','_')
        GNode -id $said -label $sa.name -type "storage" -sub $sub.name
        GLink -src $rgid -tgt $said -rel "contains"
    }
    $all_containers = @()
    foreach ($sa in $storages) {
        $saname=$sa.name
        $containers = Run-Az-Json "storage container list --account-name $saname --auth-mode login"
        foreach ($c in $containers) { $c | Add-Member -NotePropertyName "storageAccount" -NotePropertyValue $saname -Force }
        $all_containers += $containers
    }
    Add-Section -sub $sub.name -title "Storage Containers" -icon "📂" -data $all_containers -fields @("storageAccount","name","publicAccess","leaseState")

    # --------------------------------------------------------
    # 8. KEY VAULTS
    # --------------------------------------------------------
    Write-Host "  [+] KEY VAULTS" -ForegroundColor Green
    $vaults = Run-Az-Json "keyvault list"
    $vaults | ConvertTo-Json | Out-File "$output_dir\${sub_name}_08_keyvaults.json"
    Add-Section -sub $sub.name -title "Key Vaults" -icon "🔐" -data $vaults -fields @("name","resourceGroup","location")
    $all_secrets = @()
    foreach ($vault in $vaults) {
        $vname=$vault.name
        $kvid = "kv_" + ($vname -replace '[^\w]','_')
        $rgid = "rg_" + ($vault.resourceGroup -replace '[^\w]','_') + "_" + ($sub_id -replace '[^\w]','_')
        GNode -id $kvid -label $vname -type "keyvault" -sub $sub.name
        GLink -src $rgid -tgt $kvid -rel "contains"
        $secrets = Run-Az-Json "keyvault secret list --vault-name $vname"
        foreach ($s in $secrets) { $s | Add-Member -NotePropertyName "vaultName" -NotePropertyValue $vname -Force }
        $all_secrets += $secrets
        # SPs/users with access -> KV link (from role assignments)
        foreach ($r in $roles) {
            if ($r.scope -match $vname -and $r.principalName) {
                $pid = "princ_" + ($r.principalName -replace '[^\w@.]','_')
                GLink -src $pid -tgt $kvid -rel "accessTo"
            }
        }
    }
    Add-Section -sub $sub.name -title "Key Vault Secrets" -icon "🗝️" -data $all_secrets -fields @("vaultName","name","enabled","contentType")

    # --------------------------------------------------------
    # 9. WEB APPS & FUNCTIONS
    # --------------------------------------------------------
    Write-Host "  [+] WEB APPS & FUNCTIONS" -ForegroundColor Green
    $webapps = Run-Az-Json "webapp list"
    $webapps | ConvertTo-Json | Out-File "$output_dir\${sub_name}_09_webapps.json"
    Add-Section -sub $sub.name -title "Web Apps" -icon "🌐" -data $webapps -fields @("name","resourceGroup","defaultHostName","state","httpsOnly")
    foreach ($app in $webapps) {
        $waid = "webapp_" + ($app.name -replace '[^\w]','_')
        $rgid = "rg_" + ($app.resourceGroup -replace '[^\w]','_') + "_" + ($sub_id -replace '[^\w]','_')
        GNode -id $waid -label $app.name -type "webapp" -sub $sub.name
        GLink -src $rgid -tgt $waid -rel "contains"
    }
    $all_appsettings = @()
    foreach ($app in $webapps) {
        $appname=$app.name; $rg=$app.resourceGroup
        $settings = Run-Az-Json "webapp config appsettings list --name $appname --resource-group $rg"
        foreach ($s in $settings) { $s | Add-Member -NotePropertyName "appName" -NotePropertyValue $appname -Force }
        $all_appsettings += $settings
    }
    Add-Section -sub $sub.name -title "WebApp AppSettings" -icon "⚙️" -data $all_appsettings -fields @("appName","name","value","slotSetting")
    $funcapps = Run-Az-Json "functionapp list"
    Add-Section -sub $sub.name -title "Function Apps" -icon "⚡" -data $funcapps -fields @("name","resourceGroup","defaultHostName","state")
    $all_func_settings = @()
    foreach ($func in $funcapps) {
        $fname=$func.name; $rg=$func.resourceGroup
        $fsettings = Run-Az-Json "functionapp config appsettings list --name $fname --resource-group $rg"
        foreach ($s in $fsettings) { $s | Add-Member -NotePropertyName "funcName" -NotePropertyValue $fname -Force }
        $all_func_settings += $fsettings
    }
    Add-Section -sub $sub.name -title "Function AppSettings" -icon "⚙️" -data $all_func_settings -fields @("funcName","name","value","slotSetting")

    # --------------------------------------------------------
    # 10. SQL
    # --------------------------------------------------------
    Write-Host "  [+] SQL SERVERS" -ForegroundColor Green
    $sqlservers = Run-Az-Json "sql server list"
    $sqlservers | ConvertTo-Json | Out-File "$output_dir\${sub_name}_10_sql.json"
    Add-Section -sub $sub.name -title "SQL Servers" -icon "🗃️" -data $sqlservers -fields @("name","resourceGroup","location","fullyQualifiedDomainName","administratorLogin")
    foreach ($srv in $sqlservers) {
        $sqlid = "sql_" + ($srv.name -replace '[^\w]','_')
        $rgid  = "rg_" + ($srv.resourceGroup -replace '[^\w]','_') + "_" + ($sub_id -replace '[^\w]','_')
        GNode -id $sqlid -label $srv.name -type "sql" -sub $sub.name
        GLink -src $rgid -tgt $sqlid -rel "contains"
    }
    $all_fw = @()
    foreach ($srv in $sqlservers) {
        $srvname=$srv.name; $rg=$srv.resourceGroup
        $fwrules = Run-Az-Json "sql server firewall-rule list --server $srvname --resource-group $rg"
        foreach ($r in $fwrules) { $r | Add-Member -NotePropertyName "serverName" -NotePropertyValue $srvname -Force }
        $all_fw += $fwrules
    }
    Add-Section -sub $sub.name -title "SQL Firewall Rules" -icon "🔥" -data $all_fw -fields @("serverName","name","startIpAddress","endIpAddress")

    # --------------------------------------------------------
    # 11. AUTOMATION
    # --------------------------------------------------------
    Write-Host "  [+] AUTOMATION ACCOUNTS" -ForegroundColor Green
    $automations = Run-Az-Json "automation account list"
    $automations | ConvertTo-Json | Out-File "$output_dir\${sub_name}_11_automation.json"
    Add-Section -sub $sub.name -title "Automation Accounts" -icon "🤖" -data $automations -fields @("name","resourceGroup","location","sku")
    foreach ($auto in $automations) {
        $autoid = "auto_" + ($auto.name -replace '[^\w]','_')
        $rgid   = "rg_" + ($auto.resourceGroup -replace '[^\w]','_') + "_" + ($sub_id -replace '[^\w]','_')
        GNode -id $autoid -label $auto.name -type "automation" -sub $sub.name
        GLink -src $rgid -tgt $autoid -rel "contains"
    }
    $all_runbooks = @()
    foreach ($auto in $automations) {
        $autoname=$auto.name; $rg=$auto.resourceGroup
        $runbooks = Run-Az-Json "automation runbook list --automation-account-name $autoname --resource-group $rg"
        foreach ($r in $runbooks) { $r | Add-Member -NotePropertyName "accountName" -NotePropertyValue $autoname -Force }
        $all_runbooks += $runbooks
    }
    Add-Section -sub $sub.name -title "Runbooks" -icon "📜" -data $all_runbooks -fields @("accountName","name","runbookType","state")

    # --------------------------------------------------------
    # 12. CONTAINERS
    # --------------------------------------------------------
    Write-Host "  [+] CONTAINERS (ACR & AKS)" -ForegroundColor Green
    $acrs = Run-Az-Json "acr list"
    Add-Section -sub $sub.name -title "Container Registries" -icon "🐳" -data $acrs -fields @("name","resourceGroup","location","loginServer","adminUserEnabled")
    foreach ($acr in $acrs) {
        $acrid = "acr_" + ($acr.name -replace '[^\w]','_')
        $rgid  = "rg_" + ($acr.resourceGroup -replace '[^\w]','_') + "_" + ($sub_id -replace '[^\w]','_')
        GNode -id $acrid -label $acr.name -type "acr" -sub $sub.name
        GLink -src $rgid -tgt $acrid -rel "contains"
    }
    $aks = Run-Az-Json "aks list"
    Add-Section -sub $sub.name -title "AKS Clusters" -icon "☸️" -data $aks -fields @("name","resourceGroup","location","kubernetesVersion","powerState")
    foreach ($ak in $aks) {
        $aksid = "aks_" + ($ak.name -replace '[^\w]','_')
        $rgid  = "rg_" + ($ak.resourceGroup -replace '[^\w]','_') + "_" + ($sub_id -replace '[^\w]','_')
        GNode -id $aksid -label $ak.name -type "aks" -sub $sub.name
        GLink -src $rgid -tgt $aksid -rel "contains"
    }
}

# ============================================================
# GENERATE HTML FILES
# ============================================================
Write-Host "`n[+] Generating report.html..." -ForegroundColor Cyan
$generated_at  = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$html_content  = Build-HTML -generated_at $generated_at -subs_info $subs
$html_content  | Out-File -FilePath $html_file -Encoding utf8

Write-Host "[+] Generating graph.html..." -ForegroundColor Cyan
$graph_content = Build-Graph-HTML -generated_at $generated_at
$graph_content | Out-File -FilePath $graph_file -Encoding utf8

# ============================================================
# FINAL SUMMARY
# ============================================================
Write-Host "`n=====================================================" -ForegroundColor Yellow
Write-Host "   ENUMERATION COMPLETE" -ForegroundColor Green
Write-Host "   Report : $html_file" -ForegroundColor Yellow
Write-Host "   Graph  : $graph_file" -ForegroundColor Cyan
Write-Host "   Nodes  : $($gNodes.Count)   Links: $($gLinks.Count)" -ForegroundColor White
Write-Host "=====================================================`n" -ForegroundColor Yellow

Start-Process $html_file

Write-Host "[+] Files with data:" -ForegroundColor Green
Get-ChildItem $output_dir | Where-Object { $_.Length -gt 10 } |
    Select-Object Name, @{N='Size';E={"{0:N0} bytes" -f $_.Length}} |
    Format-Table -AutoSize
