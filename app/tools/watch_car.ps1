#requires -Version 5.1
<#
watch_car.ps1 — 持续盯车机是否进来（只读，不改任何配置）

  .\tools\watch_car.ps1                  # 从现在起一直盯
  .\tools\watch_car.ps1 -Minutes 10      # 盯 10 分钟
  .\tools\watch_car.ps1 -Once            # 只看一眼
  .\tools\watch_car.ps1 -Once -Since 2026-11-13T19:00:00

三层判读（只看 -Since 之后的新记录）：
  L1 车机加入热点 192.168.137.x / Tesla MAC 出现在邻居表
  L2 车机来问本机 DNS（dns.jsonl 里 peer 不是本机）
  L3 车机请求落到 mitmproxy（hits.jsonl 里 HIT 且 client 不是本机）
#>
[CmdletBinding()]
param(
    [int]$Minutes = 0,
    [switch]$Once,
    [string]$Since = ''
)
$ErrorActionPreference = 'Continue'
$root   = Split-Path -Parent $PSScriptRoot
$dnsLog = Join-Path $root 'logs\dns.jsonl'
$hitLog = Join-Path $root 'logs\hits.jsonl'
$mine   = @('127.0.0.1', '192.168.199.148', '192.168.137.1')
$since  = if ($Since) { $Since } else { (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss') }

function Get-Clients {
    $n = @(Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue)
    $hot   = @($n | Where-Object { $_.IPAddress -like '192.168.137.*' -and $_.IPAddress -ne '192.168.137.1' -and $_.LinkLayerAddress -notlike 'FF-FF*' })
    $tesla = @($n | Where-Object { $_.LinkLayerAddress -like '4C-FC-AA*' })
    $ap    = if (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -eq '192.168.137.1' }) { 'On' } else { 'Off' }
    [pscustomobject]@{ Hotspot = $hot; Tesla = $tesla; Ap = $ap }
}

function Snapshot {
    $d = @(); $h = @()
    if (Test-Path $dnsLog) { $d = @(Get-Content $dnsLog -Tail 800 -ErrorAction SilentlyContinue | ForEach-Object { try { $_ | ConvertFrom-Json } catch {} }) }
    if (Test-Path $hitLog) { $h = @(Get-Content $hitLog -Tail 800 -ErrorAction SilentlyContinue | ForEach-Object { try { $_ | ConvertFrom-Json } catch {} }) }
    [pscustomobject]@{ Dns = $d; Hits = $h; Clients = (Get-Clients) }
}

function Report($snap) {
    $carDns = @($snap.Dns  | Where-Object { $_.peer -and $_.peer -notin $mine -and $_.ts -ge $since })
    $carHit = @($snap.Hits | Where-Object { $_.kind -eq 'HIT' -and $_.client -notin $mine -and $_.ts -ge $since })
    $allHit = @($snap.Hits | Where-Object { $_.kind -eq 'HIT' -and $_.ts -ge $since })
    $hot    = @($snap.Clients.Hotspot)
    $tesla  = @($snap.Clients.Tesla)

    $tag = if ($carHit.Count -gt 0) { 'L3-HIT' } elseif ($carDns.Count -gt 0) { 'L2-DNS' } elseif ($hot.Count -gt 0) { 'L1-JOIN' } else { 'WAIT' }
    Write-Host ("[{0}] {1,-7} 热点={2,-3} DNS(车)={3} HIT(车)={4} HIT(总)={5} 热点客户端={6} Tesla邻居={7}" -f `
        (Get-Date -Format 'HH:mm:ss'), $tag, $snap.Clients.Ap, $carDns.Count, $carHit.Count, $allHit.Count, $hot.Count, $tesla.Count) -ForegroundColor Gray

    $tesla | ForEach-Object { Write-Host ("  L1 Tesla  {0}  {1}  ({2})" -f $_.IPAddress, $_.LinkLayerAddress, $_.State) -ForegroundColor Cyan }
    $hot   | ForEach-Object { Write-Host ("  L1 热点   {0}  {1}  ({2})" -f $_.IPAddress, $_.LinkLayerAddress, $_.State) -ForegroundColor Cyan }
    $carDns | Select-Object -Last 3 | ForEach-Object { Write-Host ("  L2 DNS    {0} {1} -> {2} (client {3})" -f $_.ts, $_.q, $_.ip, $_.peer) -ForegroundColor Yellow }
    $carHit | Select-Object -Last 3 | ForEach-Object { Write-Host ("  L3 HIT    {0} client={1} vin={2} bytes={3}" -f $_.ts, $_.client, $_.vin, $_.bytes) -ForegroundColor Green }
    if ($carDns.Count -eq 0 -and $carHit.Count -eq 0 -and $hot.Count -eq 0) {
        Write-Host '  等待中：车机未连 FSD-PC，也没有把 DNS 指向本机' -ForegroundColor DarkYellow
    }
    [pscustomobject]@{ Since=$since; Tag=$tag; Ap=$snap.Clients.Ap; CarDns=$carDns.Count; CarHit=$carHit.Count; Hotspot=$hot.Count }
}

$snap = Snapshot
$r = Report $snap
if ($Once) { return $r }

$deadline = if ($Minutes -gt 0) { (Get-Date).AddMinutes($Minutes) } else { (Get-Date).AddDays(7) }
$lastKey = ''; $tick = 0
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 5
    $s = Snapshot
    $key = "{0}/{1}/{2}/{3}" -f $s.Dns.Count, $s.Hits.Count, $s.Clients.Ap, (($s.Clients.Hotspot | ForEach-Object { $_.IPAddress }) -join ',')
    if ($key -ne $lastKey) { $lastKey = $key; Report $s | Out-Null }
    elseif (($tick++ % 60) -eq 0) { Report $s | Out-Null }
}