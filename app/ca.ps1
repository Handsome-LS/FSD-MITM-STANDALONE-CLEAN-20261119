#requires -Version 5.1
<#
ca.ps1 — 导出可装到车机/手机/网关的信任证书

  .\ca.ps1

产物在 certs2\：
  device-trust-EMOV-G3C.cer      --emudhra 用的中间 CA（设备不信任 emSign 根时装这个）
  device-trust-EMOV-G3C.pem
  device-trust-mitmproxy.cer     mitmproxy 常规 CA（-NoEmudhra 时用这个）
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
& (Join-Path $root 'venv\Scripts\python.exe') (Join-Path $root 'tools\export_device_ca.py')
if ($LASTEXITCODE -ne 0) { throw '导出失败' }
Get-ChildItem (Join-Path $root 'certs2') -Filter 'device-trust-*' | Select-Object Name, Length | Format-Table -AutoSize | Out-String -Width 100
