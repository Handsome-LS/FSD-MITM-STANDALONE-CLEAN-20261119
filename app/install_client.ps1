#requires -Version 5.1
<#
install_client.ps1 — 部署/修复本机 FSD 拦截环境（一键客户端入口）

  .\install_client.ps1              # 检查 + 建快捷方式 + 注册自启 + 启动全部组件
  .\install_client.ps1 -NoStart     # 只做部署，不启动
  .\install_client.ps1 -Check       # 只体检，不动手

做四件事：
  1) 检查依赖（venv / mitmdump / CA / payload）
  2) 在桌面创建「FSD一键启动 / FSD一键停止」快捷方式
  3) 注册登录自启 HKCU\...\Run\fsd-mitm-supervisor
  4) 调用 start_all.ps1 启动全部组件（缺防火墙规则会弹一次 UAC）
#>
[CmdletBinding()]
param([switch]$NoStart, [switch]$Check)

$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot
$pyw  = Join-Path $root 'venv\Scripts\pythonw.exe'
$mitm = Join-Path $root 'venv\Scripts\mitmdump.exe'
$ca   = Join-Path $root 'certs2\mitmproxy-ca.pem'
$payload = Join-Path $root 'payload.json'
$startPs1 = Join-Path $root 'start_all.ps1'
$stopPs1  = Join-Path $root 'stop_fsd_all.ps1'

function Chk($name, $path) {
    $ok = Test-Path $path
    Write-Host (("{0,-22} {1}  {2}") -f $name, $(if ($ok) { 'OK  ' } else { 'MISS' }), $path)
    return $ok
}

Write-Host "`n===== FSD 客户端部署 =====" -ForegroundColor Cyan
Write-Host "安装目录: $root`n"

$ok = $true
$ok = (Chk 'pythonw.exe' $pyw) -and $ok
$ok = (Chk 'mitmdump.exe' $mitm) -and $ok
$ok = (Chk 'CA(拦截用)' $ca) -and $ok
$ok = (Chk 'payload.json' $payload) -and $ok
$ok = (Chk 'start_all.ps1' $startPs1) -and $ok
$ok = (Chk 'stop_fsd_all.ps1' $stopPs1) -and $ok

if (-not $ok) {
    Write-Host "`n依赖不完整：请把整个项目解压到 C:\fsd-mitm（路径写死），或补齐上面 MISS 的文件。" -ForegroundColor Red
    Write-Host "如需重建 venv： python -m venv C:\fsd-mitm\venv && C:\fsd-mitm\venv\Scripts\pip install mitmproxy==12.3.1 scapy flask cryptography" -ForegroundColor Yellow
    return
}

if ($Check) { Write-Host "`n体检通过（未做任何改动）" -ForegroundColor Green; return }

# 1) 桌面快捷方式
$ws = New-Object -ComObject WScript.Shell
$desktop = [Environment]::GetFolderPath('Desktop')
$lnk1 = $ws.CreateShortcut((Join-Path $desktop 'FSD一键启动.lnk'))
$lnk1.TargetPath = Join-Path $root 'start_all.cmd'
$lnk1.WorkingDirectory = $root
$lnk1.IconLocation = 'C:\Windows\System32\shell32.dll,137'
$lnk1.Description = '一键启动 FSD 拦截环境'
$lnk1.Save()
$lnk2 = $ws.CreateShortcut((Join-Path $desktop 'FSD一键停止.lnk'))
$lnk2.TargetPath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
$lnk2.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $stopPs1 + '" -NoExit'
$lnk2.WorkingDirectory = $root
$lnk2.IconLocation = 'C:\Windows\System32\shell32.dll,131'
$lnk2.Save()
Write-Host "`n[1/3] 桌面快捷方式: 已创建 FSD一键启动 / FSD一键停止" -ForegroundColor Green

# 2) 登录自启（指向看门狗）
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$val = '"' + $pyw + '" "' + (Join-Path $root 'tools\supervise_all.py') + '"'
Set-ItemProperty -Path $runKey -Name 'fsd-mitm-supervisor' -Value $val -Type String
Write-Host "[2/3] 登录自启: HKCU\Run\fsd-mitm-supervisor 已写入" -ForegroundColor Green

# 3) 启动
if ($NoStart) {
    Write-Host "[3/3] 已跳过启动（-NoStart）" -ForegroundColor Yellow
} else {
    Write-Host "[3/3] 启动全部组件..." -ForegroundColor Yellow
    & $startPs1
}

Write-Host "`n部署完成。看板: http://127.0.0.1:8900   配置: http://127.0.0.1:8900/config`n" -ForegroundColor Green