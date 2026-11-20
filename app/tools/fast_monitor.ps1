#requires -Version 5.1
<#
fast_monitor.ps1 — 1 秒刷新的一线监控 + 自愈（只动本机服务，不改网络配置）

  .\tools\fast_monitor.ps1                 # 默认 1 秒
  .\tools\fast_monitor.ps1 -IntervalSeconds 1 -Minutes 240

监控项：
  svc   4567 / 8080 / 8899 / UDP53 是否在听
  proc  stack.py 守护进程是否活着
  data  dns.jsonl / hits.jsonl 新行（只打印变化）
  net   Wi-Fi IP、热点状态、车机是否在邻居表
  mitm  有没有 ARP 引流进程（arp_mitm.py）

自愈：
  端口连续 3 次不通 -> 调 svc\stack_start.cmd 重新拉起
日志：C:\fsd-mitm\logs\fast_monitor.log
#>
[CmdletBinding()]
param(
    [int]$IntervalSeconds = 1,
    [int]$Minutes = 240
)
$ErrorActionPreference = 'Continue'
$root  = Split-Path -Parent $PSScriptRoot
$log   = Join-Path $root 'logs\fast_monitor.log'
$dnsLog = Join-Path $root 'logs\dns.jsonl'
$hitLog = Join-Path $root 'logs\hits.jsonl'
$stackCmd = Join-Path $root 'svc\stack_start.cmd'
$mine  = @('127.0.0.1','192.168.199.148','192.168.137.1')

function Log($m, $color = 'Gray') {
    $line = "{0} {1}" -f (Get-Date -Format 'HH:mm:ss'), $m
    Write-Host $line -ForegroundColor $color
    Add-Content -LiteralPath $log -Value $line -Encoding UTF8
}

function PortOpen($port) {
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $ok = $c.ConnectAsync('127.0.0.1', $port).Wait(150)
        $c.Dispose()
        return $ok
    } catch { return $false }
}

function UdP53Open {
    # 53 被占说明 dns_sink 在听；用 bind 反证
    $s = $null
    try {
        $s = New-Object System.Net.Sockets.UdpClient(5353)
        return $true
    } catch { return $false } finally { if ($s) { $s.Dispose() } }
}

function StateSig {
    $p1 = PortOpen 4567; $p2 = PortOpen 8080; $p3 = PortOpen 8899
    $pyw = @(Get-CimInstance Win32_Process -Filter "Name='pythonw.exe'" -ErrorAction SilentlyContinue)
    $arp = @(Get-CimInstance Win32_Process -Filter "Name like 'python%'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match 'arp_mitm' })
    $ip  = (Get-NetIPAddress -InterfaceAlias 'Wi-Fi' -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
    $ap  = if (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -eq '192.168.137.1' }) { 'On' } else { 'Off' }
    $car = @(Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.LinkLayerAddress -like '4C-FC-AA*' })
    $carIp = if ($car) { ($car | Select-Object -First 1).IPAddress } else { '-' }
    [pscustomobject]@{ P1=$p1; P2=$p2; P3=$p3; Pyw=$pyw.Count; Arp=$arp.Count; Ip=$ip; Ap=$ap; Car=$carIp }
}

if (-not (Test-Path (Split-Path -Parent $log))) { New-Item -ItemType Directory -Force -Path (Split-Path -Parent $log) | Out-Null }
$dnsLast = 0; $hitLast = 0
if (Test-Path $dnsLog) { $dnsLast = @(Get-Content $dnsLog -ErrorAction SilentlyContinue).Count }
if (Test-Path $hitLog) { $hitLast = @(Get-Content $hitLog -ErrorAction SilentlyContinue).Count }
Log ("monitor start  dns=$dnsLast hit=$hitLast  (interval ${IntervalSeconds}s)") 'Cyan'

$arpDown = 0
$lastCarSeen = Get-Date
$seenPaths = @{}
$arpLog = Join-Path $root 'logs\arp_mitm.log'
$arpLines = if (Test-Path $arpLog) { @(Get-Content $arpLog -ErrorAction SilentlyContinue).Count } else { 0 }
$sig = StateSig
Log ("baseline  4567={0} 8080={1} 8899={2} pythonw={3} arp_mitm={4} ip={5} 热点={6} 车机={7}" -f $sig.P1,$sig.P2,$sig.P3,$sig.Pyw,$sig.Arp,$sig.Ip,$sig.Ap,$sig.Car) 'Cyan'
$lastSig = "{0}{1}{2}{3}{4}{5}{6}{7}" -f $sig.P1,$sig.P2,$sig.P3,$sig.Pyw,$sig.Arp,$sig.Ip,$sig.Ap,$sig.Car
$downTicks = 0
$deadline = (Get-Date).AddMinutes($Minutes)

while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds $IntervalSeconds

    # --- 数据面：新记录 ---
    if (Test-Path $dnsLog) {
        $lines = @(Get-Content $dnsLog -ErrorAction SilentlyContinue)
        if ($lines.Count -gt $dnsLast) {
            $lines[($dnsLast..($lines.Count-1))] | ForEach-Object {
                try { $o = $_ | ConvertFrom-Json } catch { return }
                $flag = if ($o.peer -notin $mine) { '车机' } else { '自测' }
                if ($flag -eq '车机') {
                    $gap = ((Get-Date) - $lastCarSeen).TotalSeconds
                    if ($gap -gt 600) { Log ("车机唤醒：静默 {0:N0}s 后重新发 DNS（{1}）—— 配置拉取窗口临近" -f $gap, $o.q) 'Cyan' }
                    $lastCarSeen = Get-Date
$seenPaths = @{}
$arpLog = Join-Path $root 'logs\arp_mitm.log'
$arpLines = if (Test-Path $arpLog) { @(Get-Content $arpLog -ErrorAction SilentlyContinue).Count } else { 0 }
                }
                Log ("DNS  [{0}] {1} -> {2}  (client {3})" -f $flag, $o.q, $o.ip, $o.peer) $(if ($flag -eq '车机') { 'Yellow' } else { 'DarkGray' })
            }
            $dnsLast = $lines.Count
        }
    }
    if (Test-Path $hitLog) {
        $lines = @(Get-Content $hitLog -ErrorAction SilentlyContinue)
        if ($lines.Count -gt $hitLast) {
            $lines[($hitLast..($lines.Count-1))] | ForEach-Object {
                try { $o = $_ | ConvertFrom-Json } catch { return }
                if ($o.kind -eq 'FLOW' -and $o.client -notin $mine -and $o.url) {
                    $pp = try { ([uri]$o.url).AbsolutePath } catch { $o.url }
                    $k = "$($o.method) $pp"
                    if (-not $seenPaths.ContainsKey($k)) {
                        $seenPaths[$k] = 1
                        Log ("车机请求 {0}" -f $k) $(if ($pp -like '*feature_configuration*') { 'Green' } else { 'DarkCyan' })
                        if ($pp -like '*feature_configuration*') { Log '*** 目标接口已出现，检查是否返回 282B ***' 'Green' }
                    }
                }                if ($o.kind -eq 'HIT') {
                    $flag = if ($o.client -notin $mine) { '车机' } else { '自测' }
                    Log ("HIT  [{0}] client={1} vin={2} bytes={3} md5={4}" -f $flag, $o.client, $o.vin, $o.bytes, $o.md5) $(if ($flag -eq '车机') { 'Green' } else { 'DarkGray' })
                }
            }
            $hitLast = $lines.Count
        }
    }

    # --- 传输面：车机 TLS SNI / 到本机的连接 ---
    if (Test-Path $arpLog) {
        $ls = @(Get-Content $arpLog -ErrorAction SilentlyContinue)
        if ($ls.Count -gt $arpLines) {
            $ls[($arpLines..($ls.Count-1))] | Where-Object { $_ -match 'SNI=|car -> us' } | ForEach-Object {
                $m = if ($_ -match 'SNI=(\S+)') { "SNI " + $Matches[1] } elseif ($_ -match 'SYN dport=(\d+)') { "车机连本机 dport=" + $Matches[1] } else { $_ }
                Log ("TLS/连接  " + $m) $(if ($m -like 'SNI mothership*') { 'Green' } else { 'DarkCyan' })
            }
            $arpLines = $ls.Count
        }
    }
    # --- 控制面：状态变化 ---
    $s = StateSig
    $cur = "{0}{1}{2}{3}{4}{5}{6}{7}" -f $s.P1,$s.P2,$s.P3,$s.Pyw,$s.Arp,$s.Ip,$s.Ap,$s.Car
    if ($cur -ne $lastSig) {
        Log ("state 4567={0} 8080={1} 8899={2} pythonw={3} arp_mitm={4} ip={5} 热点={6} 车机={7}" -f $s.P1,$s.P2,$s.P3,$s.Pyw,$s.Arp,$s.Ip,$s.Ap,$s.Car) 'Magenta'
        $lastSig = $cur
    }

    # --- 自愈：ARP 引流消失就重新拉起 ---
    if ($s.Arp -eq 0) {
        $arpDown++
        if ($arpDown -ge 3) {
            Log ("arp_mitm missing {0}s -> relaunch" -f ($arpDown * $IntervalSeconds)) 'Red'
            $pywPath = Join-Path $root 'venv\Scripts\pythonw.exe'
            $arpPy   = Join-Path $root 'tools\arp_mitm.py'
            $args = @($arpPy,'--target','192.168.199.95','--gateway','192.168.199.1',
                      '--our-ip','192.168.199.148','--answer','192.168.199.148',
                      '--iface','Wi-Fi','--duration','7200','--rst-dst','52.81.9.181')
            Start-Process -FilePath $pywPath -ArgumentList $args -WindowStyle Hidden
            $arpDown = 0
            Start-Sleep -Seconds 5
        }
    } else { $arpDown = 0 }
    # --- 自愈：端口连续不通就重拉栈 ---
    if (-not ($s.P1 -and $s.P2 -and $s.P3)) {
        $downTicks++
        if ($downTicks -ge 3) {
            Log ("ports down {0}s -> restart stack" -f ($downTicks * $IntervalSeconds)) 'Red'
            & $stackCmd | Out-Null
            Start-Sleep -Seconds 8
            $downTicks = 0
        }
    } else { $downTicks = 0 }
}
Log 'monitor exit (deadline)' 'Cyan'