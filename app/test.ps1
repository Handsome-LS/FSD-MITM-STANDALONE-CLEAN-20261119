#requires -Version 5.1
<#
test.ps1 — 本机自检（不接车机也能验证）

  .\test.ps1                 # 反向模式 4567 自检
  .\test.ps1 -WithProxy      # 另外验证 8080 代理（含 --emudhra 证书链）

行为：
  * 4567 已经在跑（常驻栈）→ 直接借它自测，不会杀掉你的常驻实例
  * 4567 没在跑 → 临时起一个，测完只关自己起的那个
  * 用 POST + body，和车机真实请求一致

期望：200 / 282 字节 / X-Checksum 104ccde7d817ab00667f2d98326259ec
#>
[CmdletBinding()]
param(
    [int]$ReversePort = 4567,
    [int]$ProxyPort = 8080,
    [switch]$WithProxy
)

$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mitmdump = Join-Path $root 'venv\Scripts\mitmdump.exe'
$python   = Join-Path $root 'venv\Scripts\python.exe'
$addon    = Join-Path $root 'fsd_mock.py'
$logDir   = Join-Path $root 'logs'
$confdir  = Join-Path $root 'certs2'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

$expectMd5  = '104ccde7d817ab00667f2d98326259ec'
$expectSize = 282
$fail = 0

function Step($msg) { Write-Host "`n[测试] $msg" -ForegroundColor Cyan }
function Test-Port([int]$port) {
    $c = New-Object System.Net.Sockets.TcpClient
    try { return $c.ConnectAsync('127.0.0.1', $port).Wait(400) } catch { return $false } finally { $c.Dispose() }
}

Step "反向模式 HTTP:$ReversePort（POST）"
$owned = -not (Test-Port $ReversePort)
$p = $null
if ($owned) {
    $ignore = '^(hermes-prd|hermes-stream-prd|telemetry-prd)\.vn\.cloud\.tesla\.cn(?::\d+)?$'
    $mdArgs = @('-s', $addon, '--mode', 'reverse:http://192.0.2.1:4567', '--listen-host', '127.0.0.1',
                '--listen-port', "$ReversePort", '--set', 'keep_host_header=true', '--set', 'connection_strategy=lazy',
                '--ignore-hosts', $ignore, '--set', "confdir=$confdir")
    $p = Start-Process -FilePath $mitmdump -ArgumentList $mdArgs -PassThru -WindowStyle Minimized
    for ($i = 0; $i -lt 24; $i++) { Start-Sleep -Milliseconds 500; if (Test-Port $ReversePort) { break } }
}
else {
    Write-Host '  端口已在监听（常驻栈），直接借它自测，不重启你的实例' -ForegroundColor DarkGray
}

try {
    if (-not (Test-Port $ReversePort)) {
        $fail++
        Write-Host "  $ReversePort 没起来" -ForegroundColor Red
    }
    else {
        $probe = '{"vin":"SELFTEST","source":"test.ps1"}'
        $r = & curl.exe -sS -D - --max-time 10 -X POST "http://127.0.0.1:$ReversePort/vehicles/SELFTEST/feature_configuration" -H 'Host: mothership.vn.teslamotors.com' -H 'Content-Type: application/json' --data $probe 2>&1
        $text = ($r | Out-String)

        if ($text -match 'HTTP/1\.1 200') { Write-Host '  200 OK' -ForegroundColor Green }
        else { $fail++; Write-Host "  状态码不对:`n$text" -ForegroundColor Red }

        if ($text -match "X-Checksum:\s*$expectMd5") { Write-Host "  X-Checksum 正确 ($expectMd5)" -ForegroundColor Green }
        else { $fail++; Write-Host '  X-Checksum 不对' -ForegroundColor Red }

        $body = ($text -split "`r?`n`r?`n", 2)[-1].Trim()
        if ($body.Length -eq $expectSize) { Write-Host "  body $expectSize 字节" -ForegroundColor Green }
        else { $fail++; Write-Host "  body 长度 = $($body.Length)（期望 $expectSize）" -ForegroundColor Red }

        if ($body -match '"eu_fsd_allowed_country_codes":"CHN"' -and $body -match '"full_self_driving":true') {
            Write-Host '  关键字段齐全' -ForegroundColor Green
        }
        else { $fail++; Write-Host '  字段缺失' -ForegroundColor Red }
    }
}
finally {
    if ($owned -and $p) { & taskkill.exe /PID $p.Id /T /F *> $null }
    Start-Sleep -Milliseconds 300
}

if ($WithProxy) {
    Step "代理模式 HTTPS:$ProxyPort（--emudhra 链校验）"
    if (-not (Test-Port $ProxyPort)) {
        Write-Host "  $ProxyPort 没在监听，先跑 .\run.ps1 -Mode proxy 或等常驻栈" -ForegroundColor Yellow
    }
    else {
        & $python (Join-Path $root 'tools\selftest.py')
        if ($LASTEXITCODE -ne 0) { $fail++ } else { Write-Host '  TLS 链 + mock 均通过' -ForegroundColor Green }
    }
}

Write-Host ''
if ($fail -eq 0) {
    Write-Host 'PASS' -ForegroundColor Green
    exit 0
}
Write-Host "FAIL — $fail 项不通过" -ForegroundColor Red
exit 1
