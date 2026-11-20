#requires -Version 5.1
<#
car_follow.ps1 — 车机重启期间盯着：跟住它的新 IP、重建引流、发现 feature_configuration 立刻报

  .\tools\car_follow.ps1 -Minutes 25

做的事：
  1) 每 5 秒按 MAC(4C-FC-AA-00-00-00) 在邻居表里找车机当前 IP
  2) IP 变了 -> 精确停掉旧的 arp_mitm，用新 IP 重启（保持 --rst-dst）
  3) 每 5 秒扫 hits.jsonl：出现 client=车机 且路径含 feature_configuration -> 打绿字 + 记文件
  4) 记录车机 DNS/请求的静默-恢复，判断它是否刚重启
日志：C:\fsd-mitm\logs\car_follow.log
#>
[CmdletBinding()]
param(
    [int]$Minutes = 25,
    [string]$CarMac = '4C-FC-AA-00-00-00',
    [string]$Ip = '192.168.199.95',
    [int]$IntervalSeconds = 5
)
$ErrorActionPreference = 'Continue'
$root  = Split-Path -Parent $PSScriptRoot
$py    = Join-Path $root 'venv\Scripts\python.exe'
$entry = Join-Path $root 'tools\arp_mitm.py'
$hit   = Join-Path $root 'logs\hits.jsonl'
$log   = Join-Path $root 'logs\car_follow.log'

function Log($m, $c = 'Gray') {
    $line = "{0} {1}" -f (Get-Date -Format 'HH:mm:ss'), $m
    Write-Host $line -ForegroundColor $c
    Add-Content -LiteralPath $log -Value $line -Encoding UTF8
}

function Get-CarIp {
    $n = @(Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue |
           Where-Object { $_.LinkLayerAddress -eq $CarMac })
    if ($n.Count -gt 0) { return $n[0].IPAddress }
    return $null
}

function Restart-Forwarder([string]$target) {
    $procs = @(Get-CimInstance Win32_Process -Filter "Name like 'python%'" -ErrorAction SilentlyContinue |
               Where-Object { $_.CommandLine -match 'arp_mitm\.py' -and $_.Name -notin @('powershell.exe','pwsh.exe','cmd.exe','DeepSeek Harness.exe') })
    foreach ($p in $procs) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 2
    Start-Process -FilePath $py -ArgumentList @(
        $entry,'--target',$target,'--gateway','192.168.199.1',
        '--our-ip','192.168.199.148','--answer','192.168.199.148',
        '--iface','Wi-Fi','--duration','7200','--rst-dst','52.81.9.181'
    ) -WindowStyle Hidden
    Log ("引流已针对 {0} 重启" -f $target) 'Cyan'
}

Log ("car_follow start  ip={0} mac={1}" -f $Ip, $CarMac) 'Cyan'
$seen = 0
if (Test-Path $hit) { $seen = @(Get-Content $hit -ErrorAction SilentlyContinue).Count }
$lastCar = Get-Date
$deadline = (Get-Date).AddMinutes($Minutes)
$hitFound = $false

while ((Get-Date) -lt $deadline -and -not $hitFound) {
    Start-Sleep -Seconds $IntervalSeconds

    # 1) 跟 IP
    $now = Get-CarIp
    if ($now -and $now -ne $Ip) {
        Log ("车机 IP 变化: {0} -> {1}，重建引流" -f $Ip, $now) 'Yellow'
        $Ip = $now
        Restart-Forwarder $Ip
    } elseif (-not $now) {
        # 车机重启中，邻居表里暂时没有它 —— 正常
    }

    # 2) 扫新请求
    if (Test-Path $hit) {
        $lines = @(Get-Content $hit -ErrorAction SilentlyContinue)
        if ($lines.Count -gt $seen) {
            foreach ($ln in $lines[$seen..($lines.Count-1)]) {
                try { $o = $ln | ConvertFrom-Json } catch { continue }
                if ($o.client -and $o.client -ne '127.0.0.1') {
                    $lastCar = Get-Date
                    if ($o.url -match 'feature_configuration') {
                        Log ("*** 车机命中 feature_configuration: {0} {1} client={2}" -f $o.kind, $o.url, $o.client) 'Green'
                        $hitFound = $true
                    }
                }
            }
            $seen = $lines.Count
        }
    }

    # 3) 静默/恢复提示
    $gap = ((Get-Date) - $lastCar).TotalMinutes
    if ($gap -gt 3 -and $gap -lt 3.2) { Log '车机已静默 3 分钟（可能正在重启）' 'DarkYellow' }
}
Log ("car_follow exit  hitFound={0}  ip={1}" -f $hitFound, $Ip) 'Cyan'