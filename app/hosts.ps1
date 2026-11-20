#requires -Version 5.1
<#
hosts.ps1 — 把车机要访问的域名在本机解析到本机（配合热点/ICS 做 DNS 劫持）

  .\hosts.ps1 -Action show
  .\hosts.ps1 -Action add                       # 默认指向 192.168.137.1（Windows 热点网关）
  .\hosts.ps1 -Action add -Ip 192.168.199.148   # 或指定本机在车机同网段的 IP
  .\hosts.ps1 -Action remove

说明：
  * 改 hosts 需要管理员 → 脚本自己弹 UAC；
  * 前提是车机的 DNS 最终落到这台 PC（PC 当热点/网关并开着 ICS 时成立）；
  * 只影响这台 PC 的解析，包括 ICS 的 DNS 转发。
#>
[CmdletBinding()]
param(
    [ValidateSet('add', 'remove', 'show')] [string]$Action = 'show',
    [string]$Ip = '192.168.137.1',
    [string[]]$Names = @('mothership.vn.teslamotors.com', 'api-prd.vn.cloud.tesla.cn')
)

$ErrorActionPreference = 'Stop'
$shell = (Get-Process -Id $PID).Path
$hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$mark = '# fsd-mitm'

if ($Action -in @('add', 'remove') -and -not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $argv = @('-NoExit', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-Action', $Action, '-Ip', $Ip, '-Names', ($Names -join ','))
    Start-Process -FilePath $shell -Verb RunAs -ArgumentList $argv | Out-Null
    return
}

$lines = Get-Content $hostsPath -ErrorAction Stop

switch ($Action) {
    'show' {
        Write-Host "hosts: $hostsPath"
        $lines | Select-String -Pattern 'fsd-mitm|teslamotors|tesla\.cn' | ForEach-Object { $_.Line }
        Write-Host ''
        Write-Host '本机 IPv4:'
        Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' } |
            Select-Object IPAddress, InterfaceAlias | Format-Table -AutoSize | Out-String -Width 100
    }
    'add' {
        Copy-Item $hostsPath "$hostsPath.bak-fsd-mitm" -Force
        $clean = $lines | Where-Object { $_ -notmatch [regex]::Escape($mark) }
        $add = $Names | ForEach-Object { "$Ip`t$_`t$mark" }
        Set-Content -Path $hostsPath -Value (@($clean) + @('') + $add) -Encoding ASCII
        ipconfig /flushdns | Out-Null
        Write-Host "已写入 $Ip -> $($Names -join ', ')" -ForegroundColor Green
        Write-Host "备份: $hostsPath.bak-fsd-mitm"
    }
    'remove' {
        $clean = $lines | Where-Object { $_ -notmatch [regex]::Escape($mark) }
        Set-Content -Path $hostsPath -Value $clean -Encoding ASCII
        ipconfig /flushdns | Out-Null
        Write-Host '已清除 fsd-mitm 条目' -ForegroundColor Green
    }
}
