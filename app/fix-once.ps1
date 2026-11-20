#requires -Version 5.1
<#
fix-once.ps1 — 一次 UAC，把车机能进来的条件配好

  .\fix-once.ps1              # 加防火墙入站规则 + 打印车机侧要填的 DNS
  .\fix-once.ps1 -OpenF50     # 顺手打开 F50 后台（http://192.168.199.1）

做的事：
  1) TCP 4567 / 8080、UDP 53 入站放行（当前网络是 Public，默认阻止）
  2) 打印本机 IP，告诉你在车机/F50 里该填哪个 DNS
  不改 hosts（PC 不是网关时没用），不改车机任何设置。
#>
[CmdletBinding()]
param(
    [switch]$OpenF50
)

$ErrorActionPreference = 'Stop'
$shell = (Get-Process -Id $PID).Path

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host '需要管理员权限 → 弹 UAC 重新启动...' -ForegroundColor Yellow
    # 自提权后在新窗口里跑，避免结果一闪而过
    Start-Process -FilePath $shell -Verb RunAs -ArgumentList @(
        '-NoExit', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath
    ) | Out-Null
    return
}

Write-Host '=== 1. 防火墙入站放行 ===' -ForegroundColor Cyan
$rules = @(
    @{ Name = 'fsd-mitm-reverse-4567'; Proto = 'TCP'; Port = 4567 },
    @{ Name = 'fsd-mitm-proxy-8080';   Proto = 'TCP'; Port = 8080 },
    @{ Name = 'fsd-mitm-dns-53';       Proto = 'UDP'; Port = 53 }
)
foreach ($r in $rules) {
    $existing = Get-NetFirewallRule -DisplayName $r.Name -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host ("  {0,-24} 已存在" -f $r.Name) -ForegroundColor DarkGray
        continue
    }
    New-NetFirewallRule -DisplayName $r.Name -Direction Inbound -Action Allow `
        -Protocol $r.Proto -LocalPort $r.Port -Profile Any -Description 'F50 FSD lab proxy' | Out-Null
    Write-Host ("  {0,-24} allow {1}/{2}" -f $r.Name, $r.Proto, $r.Port) -ForegroundColor Green
}

Write-Host ''
Write-Host '=== 2. 车机侧填什么 ===' -ForegroundColor Cyan
$wifi = Get-NetIPConfiguration -InterfaceAlias 'Wi-Fi' -ErrorAction SilentlyContinue
$ip = ($wifi.IPv4Address | Where-Object { $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1).IPAddress
$gw = $wifi.IPv4DefaultGateway.NextHop | Select-Object -First 1
Write-Host ("  本机 IP      : {0}" -f $ip)
Write-Host ("  F50 网关     : {0}" -f $gw)
Write-Host ''
Write-Host '  二选一：' -ForegroundColor Yellow
Write-Host ("  A) 车机 Wi-Fi 高级里，DNS 填 {0}" -f $ip)
Write-Host ("  B) F50 后台 http://{0} → LAN/DHCP 设置 → DNS 填 {1}" -f $gw, $ip)
Write-Host ''
Write-Host '  改完重启车机，等 5–10 分钟；看板 http://127.0.0.1:8899 会显示命中。'

if ($OpenF50 -and $gw) {
    Start-Process ("http://" + $gw)
}

Write-Host ''
Write-Host '按任意键关闭...' -ForegroundColor DarkGray
[void]$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
