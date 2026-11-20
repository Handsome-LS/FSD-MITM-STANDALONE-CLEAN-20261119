#requires -Version 5.1
<#
install.ps1 — 把 fsd-mitm 常驻栈"装好/修好"，可重复执行（幂等）

  .\tools\install.ps1                 # 自启项 + 防火墙 + 起栈
  .\tools\install.ps1 -Hotspot        # 顺带把移动热点 FSD-PC 打开
  .\tools\install.ps1 -Check          # 只体检，不动任何东西
  .\tools\install.ps1 -Uninstall      # 撤自启 + 删防火墙规则 + 停栈

做的事：
  1) HKCU Run: fsd-mitm-stack = "pythonw.exe" "svc\stack.py"
     登录即起、无控制台、不受"启动文件夹被清理"影响
  2) 防火墙入站放行 TCP 4567 / 8080 / 8899 + UDP 53（需要管理员，自动提权一次）
  3) 起栈（stack.py 内有单实例锁，重复执行不会起第二份）

回滚：-Uninstall，或直接用 backup\<时间戳>\ 里的旧文件覆盖。
#>
[CmdletBinding()]
param(
    [switch]$Hotspot,
    [switch]$Check,
    [switch]$Uninstall,
    [switch]$FirewallOnly
)
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$pyw  = Join-Path $root 'venv\Scripts\pythonw.exe'
$py   = Join-Path $root 'venv\Scripts\python.exe'
$entry = Join-Path $root 'svc\stack.py'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$runName = 'fsd-mitm-stack'
$runVal = '"{0}" "{1}"' -f $pyw, $entry
$rules = @(
    @{ Name='fsd-mitm-reverse-4567'; Proto='TCP'; Port=4567 },
    @{ Name='fsd-mitm-proxy-8080';   Proto='TCP'; Port=8080 },
    @{ Name='fsd-mitm-dns-53';       Proto='UDP'; Port=53 },
    @{ Name='fsd-mitm-web-8899';     Proto='TCP'; Port=8899 }
)

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ApState {
    if (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -eq '192.168.137.1' }) { 'On' } else { 'Off' }
}

function Show-Status {
    Write-Host "`n=== 状态 ===" -ForegroundColor Cyan
    $v = (Get-ItemProperty $runKey -Name $runName -ErrorAction SilentlyContinue).$runName
    if ($v) { Write-Host ("  自启项   : OK  {0}" -f $v) -ForegroundColor Green } else { Write-Host '  自启项   : 缺失' -ForegroundColor Yellow }
    $fw = @(Get-NetFirewallRule -DisplayName 'fsd-mitm*' -ErrorAction SilentlyContinue)
    Write-Host ("  防火墙   : {0} 条" -f $fw.Count)
    $ports = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -in 4567,8080,8899 } | Select-Object -ExpandProperty LocalPort | Sort-Object)
    Write-Host ("  监听 TCP : {0}" -f ($(if ($ports) { $ports -join ', ' } else { '无' })))
    $udp = @(Get-NetUDPEndpoint -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -eq 53 })
    Write-Host ("  监听 UDP : {0}" -f $(if ($udp) { '53' } else { '无' }))
    Write-Host ("  移动热点 : {0}" -f (Get-ApState))
    $pr = @(Get-CimInstance Win32_Process -Filter "Name like 'python%' or Name like 'mitmdump%'" -ErrorAction SilentlyContinue)
    Write-Host ("  进程     : {0} 个" -f $pr.Count)
    $hits = Join-Path $root 'logs\hits.jsonl'
    if (Test-Path $hits) {
        $mine = @('127.0.0.1','192.168.199.148','192.168.137.1')
        $car = @(Get-Content $hits -Tail 500 -ErrorAction SilentlyContinue | ForEach-Object { try { $_ | ConvertFrom-Json } catch {} } | Where-Object { $_.kind -eq 'HIT' -and $_.client -notin $mine })
        Write-Host ("  车机命中 : {0} 条" -f $car.Count)
    }
}

if ($FirewallOnly) {
    foreach ($r in $rules) {
        if (Get-NetFirewallRule -DisplayName $r.Name -ErrorAction SilentlyContinue) {
            Write-Host ("  EXIST {0}" -f $r.Name)
        } else {
            New-NetFirewallRule -DisplayName $r.Name -Direction Inbound -Action Allow -Protocol $r.Proto -LocalPort $r.Port -Profile Any -Description 'F50 FSD lab' | Out-Null
            Write-Host ("  ADD   {0} {1}/{2}" -f $r.Name, $r.Proto, $r.Port)
        }
    }
    return
}

if ($Check) { Show-Status; return }

if ($Uninstall) {
    Remove-ItemProperty -Path $runKey -Name $runName -ErrorAction SilentlyContinue
    Write-Host '已撤自启项' -ForegroundColor Yellow
    & (Join-Path $root 'svc\stop_stack.ps1') | Out-Null
    if (Test-Admin) {
        Get-NetFirewallRule -DisplayName 'fsd-mitm*' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
        Write-Host '已删防火墙规则' -ForegroundColor Yellow
    } else {
        Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-Command',"Get-NetFirewallRule -DisplayName 'fsd-mitm*' -EA SilentlyContinue | Remove-NetFirewallRule" | Out-Null
        Write-Host '已请求提权删除防火墙规则（请确认 UAC）' -ForegroundColor Yellow
    }
    Show-Status
    return
}

Write-Host "`n=== 1. 自启项（HKCU Run） ===" -ForegroundColor Cyan
foreach ($p in @($pyw, $entry)) { if (-not (Test-Path $p)) { Write-Host ("  缺少文件: {0}" -f $p) -ForegroundColor Red; return } }
Set-ItemProperty -Path $runKey -Name $runName -Value $runVal -Type String
Write-Host ("  OK {0} = {1}" -f $runName, (Get-ItemProperty $runKey).$runName) -ForegroundColor Green

Write-Host "`n=== 2. 防火墙入站放行 ===" -ForegroundColor Cyan
$missing = @($rules | Where-Object { -not (Get-NetFirewallRule -DisplayName $_.Name -ErrorAction SilentlyContinue) })
if ($missing.Count -eq 0) {
    Write-Host '  4 条规则已存在' -ForegroundColor Green
} elseif (Test-Admin) {
    & $PSCommandPath -FirewallOnly
} else {
    $out = Join-Path $root 'logs\_install_fw.out'
    Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-FirewallOnly' | Out-Null
    Start-Sleep -Seconds 4
    $fw = @(Get-NetFirewallRule -DisplayName 'fsd-mitm*' -ErrorAction SilentlyContinue)
    if ($fw.Count -ge 4) { Write-Host ("  OK 已由提权进程写入 {0} 条规则" -f $fw.Count) -ForegroundColor Green }
    else { Write-Host '  规则未写全，请手动以管理员运行: ' -NoNewline; Write-Host ("powershell -File `"{0}`" -FirewallOnly" -f $PSCommandPath) -ForegroundColor Yellow }
}

Write-Host "`n=== 3. 启动常驻栈 ===" -ForegroundColor Cyan
& (Join-Path $root 'svc\stack_start.cmd')
Start-Sleep -Seconds 6

Write-Host "`n=== 4. 移动热点 ===" -ForegroundColor Cyan
if ($Hotspot) {
    if ((Get-ApState) -eq 'On') { Write-Host '  已经开着 (SSID=FSD-PC / 192.168.137.1)' -ForegroundColor Green }
    else { & (Join-Path $root 'hotspot.ps1') -Action start -Ssid 'FSD-PC' -Key 'fsd2026!!' | Out-Null; Write-Host ("  {0}" -f (Get-ApState)) -ForegroundColor Green }
} else {
    Write-Host ("  移动热点 : {0}（加 -Hotspot 可打开）" -f (Get-ApState))
}

Show-Status
Write-Host "`n下一步：车机 Wi-Fi 连 FSD-PC / fsd2026!! -> 重启车机 -> .\tools\watch_car.ps1 -Minutes 15" -ForegroundColor Yellow