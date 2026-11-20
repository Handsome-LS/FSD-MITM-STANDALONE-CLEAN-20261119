#requires -Version 5.1
<#
web.ps1 — 启动 WEB 看板（车机连接状态 + feature_configuration 回传）

  .\web.ps1                # 默认 http://127.0.0.1:8899，自动开浏览器
  .\web.ps1 -Port 8900 -NoBrowser
#>
[CmdletBinding()]
param(
    [int]$Port = 8899,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$python = Join-Path $root 'venv\Scripts\python.exe'
$server = Join-Path $root 'web\server.py'

if (-not (Test-Path $python)) { throw "缺少 $python" }
if (-not $NoBrowser) {
    Start-Job -ScriptBlock { param($u) Start-Sleep -Seconds 2; Start-Process $u } -ArgumentList "http://127.0.0.1:$Port" | Out-Null
}
$env:PYTHONIOENCODING = 'utf-8'
& $python $server --port $Port
