#requires -Version 5.1
<#
start_fsd_panel.ps1 — 起 FSD 拦截实况看板（独立进程，127.0.0.1:8900）

  .\tools\start_fsd_panel.ps1
  .\tools\start_fsd_panel.ps1 -Port 8901
  .\tools\start_fsd_panel.ps1 -Stop

只读 logs\ 下的证据文件，不改任何配置。
#>
[CmdletBinding()]
param([int]$Port = 8900, [switch]$Stop)
$ErrorActionPreference = 'Continue'
$root  = Split-Path -Parent $PSScriptRoot
$pyw   = Join-Path $root 'venv\Scripts\pythonw.exe'
$panel = Join-Path $root 'web\fsd_panel.py'
$log   = Join-Path $root 'logs\fsd_panel.log'

$existing = @(Get-CimInstance Win32_Process -Filter "Name like 'python%'" -ErrorAction SilentlyContinue |
              Where-Object { $_.CommandLine -and $_.CommandLine -match 'fsd_panel\.py' })
if ($Stop) {
    foreach ($p in $existing) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue; Write-Host "stopped pid=$($p.ProcessId)" }
    return
}
if ($existing.Count -gt 0) {
    Write-Host ("看板已在运行（{0} 个进程）: http://127.0.0.1:{1}" -f $existing.Count, $Port)
    return
}
Start-Process -FilePath $pyw -ArgumentList @($panel,'--port',"$Port") -WindowStyle Hidden `
    -RedirectStandardOutput $log -RedirectStandardError ($log -replace '\.log$','.err.log')
Start-Sleep -Seconds 3
try {
    $r = Invoke-WebRequest "http://127.0.0.1:$Port/api/state" -UseBasicParsing -TimeoutSec 5
    Write-Host ("看板已启动: http://127.0.0.1:{0}  (HTTP {1})" -f $Port, $r.StatusCode) -ForegroundColor Green
} catch {
    Write-Host ("启动失败: " + $_.Exception.Message) -ForegroundColor Red
    Get-Content $log -Tail 10 -ErrorAction SilentlyContinue
}