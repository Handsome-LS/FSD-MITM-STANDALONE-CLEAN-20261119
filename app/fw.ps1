#requires -Version 5.1
<#
fw.ps1 — 放行车机进来的端口（需要管理员，脚本自己弹 UAC）

  .\fw.ps1 -Action add      # TCP 4567(reverse) / 8080(代理) + UDP 53(DNS)
  .\fw.ps1 -Action remove
  .\fw.ps1 -Action show
#>
[CmdletBinding()]
param(
    [ValidateSet('add', 'remove', 'show')] [string]$Action = 'add',
    [int]$ReversePort = 4567,
    [int]$ProxyPort = 8080
)

$ErrorActionPreference = 'Stop'
$shell = (Get-Process -Id $PID).Path
$prefix = 'fsd-mitm'

if ($Action -in @('add', 'remove') -and -not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process -FilePath $shell -Verb RunAs -ArgumentList @('-NoExit', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-Action', $Action) | Out-Null
    return
}

$rules = @(
    @{ Name = "$prefix-reverse-$ReversePort"; Proto = 'TCP'; Port = $ReversePort },
    @{ Name = "$prefix-proxy-$ProxyPort";     Proto = 'TCP'; Port = $ProxyPort },
    @{ Name = "$prefix-dns-53";               Proto = 'UDP'; Port = 53 }
)

switch ($Action) {
    'add' {
        foreach ($r in $rules) {
            if (Get-NetFirewallRule -DisplayName $r.Name -ErrorAction SilentlyContinue) { continue }
            New-NetFirewallRule -DisplayName $r.Name -Direction Inbound -Action Allow -Protocol $r.Proto -LocalPort $r.Port -Profile Any | Out-Null
            Write-Host ("allow {0}/{1}" -f $r.Proto, $r.Port) -ForegroundColor Green
        }
    }
    'remove' {
        foreach ($r in $rules) {
            Get-NetFirewallRule -DisplayName $r.Name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
            Write-Host ("removed {0}" -f $r.Name) -ForegroundColor Yellow
        }
    }
    'show' {
        Get-NetFirewallRule -DisplayName "$prefix-*" -ErrorAction SilentlyContinue |
            Select-Object DisplayName, Enabled, Direction, Action | Format-Table -AutoSize | Out-String -Width 100
    }
}
