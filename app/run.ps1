#requires -Version 5.1
<#
run.ps1 — 启停车机 FSD feature_configuration 伪造代理

  .\run.ps1 -Mode reverse        # 车机 DNS/解析指到本机 + HTTP:4567 明文拦截（默认，已实测）
  .\run.ps1 -Mode proxy          # 车机/网关能设 HTTP 代理时用 8080（HTTPS 靠 --emudhra 证书链）
  .\run.ps1 -Mode both           # 4567 reverse + 8080 代理 同时起
  .\run.ps1 -Mode sniff          # 只看不拦：把车机请求记到 logs\hits.jsonl
  .\run.ps1 -Mode transparent    # 管理员身份透明代理（WinDivert，Windows 上官方标注 flaky）

常用参数：
  -UpstreamIp 10.1.2.3   4567 上游真实 IP（默认自动解析；解析不到用 192.0.2.1 黑洞，命中路径照常回包）
  -ListenHost 0.0.0.0    监听地址（车机要连就必须是 0.0.0.0）
  -Confdir C:\path       证书库目录，默认 <root>\certs2
  -NoEmudhra             不用 --emudhra，改用 confdir 里 mitmproxy-ca.pem 的 CA
  -LogAll                所有请求都写 logs\hits.jsonl（sniff 模式默认开）
#>
[CmdletBinding()]
param(
    [ValidateSet('reverse', 'proxy', 'both', 'sniff', 'transparent')]
    [string]$Mode = 'reverse',
    [string]$UpstreamIp = '',
    [int]$ReversePort = 4567,
    [int]$ProxyPort = 8080,
    [string]$HostName = 'mothership.vn.teslamotors.com',
    [string]$ListenHost = '0.0.0.0',
    [string]$Confdir = '',
    [switch]$NoEmudhra,
    [switch]$LogAll
)

$ErrorActionPreference = 'Stop'
$root      = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$shell     = (Get-Process -Id $PID).Path
$mitmdump  = Join-Path $root 'venv\Scripts\mitmdump.exe'
$addon     = Join-Path $root 'fsd_mock.py'
$confdir   = if ($Confdir) { $Confdir } else { Join-Path $root 'certs2' }
$logDir    = Join-Path $root 'logs'
$ignore    = '^(hermes-prd|hermes-stream-prd|telemetry-prd)\.vn\.cloud\.tesla\.cn(?::\d+)?$'

New-Item -ItemType Directory -Force -Path $confdir, $logDir | Out-Null
if (-not (Test-Path $mitmdump)) { throw "missing $mitmdump (先建 venv 并 pip install mitmproxy)" }

if ($Mode -eq 'sniff') { $LogAll = $true }
if ($LogAll) { $env:FSD_MOCK_LOG_ALL = '1' } else { $env:FSD_MOCK_LOG_ALL = '0' }
$env:FSD_MOCK_LOG_DIR = $logDir
$env:PYTHONUNBUFFERED = '1'

if (-not $UpstreamIp) {
    try {
        $rec = Resolve-DnsName -Name $HostName -Type A -DnsOnly -Server 223.5.5.5 -ErrorAction Stop |
               Where-Object { $_.IPAddress -and $_.IPAddress -notmatch ':' } | Select-Object -First 1
        if ($rec) { $UpstreamIp = $rec.IPAddress }
    } catch { }
    if (-not $UpstreamIp) {
        $UpstreamIp = '192.0.2.1'
        Write-Host '  ! 没有解析到上游真实 IP，上游回落 192.0.2.1（黑洞）：feature_configuration 照常回包，其它路径会失败' -ForegroundColor Yellow
    }
}

$common = @(
    '-s', $addon,
    '--set', "confdir=$confdir",
    '--set', 'ssl_insecure=true',
    '--set', 'connection_strategy=lazy',
    '--set', 'block_global=false',
    '--ignore-hosts', $ignore
)
if (-not $NoEmudhra) { $common += '--emudhra' }

$reverseArgs = @('--mode', "reverse:http://${UpstreamIp}:$ReversePort", '--listen-host', $ListenHost,
                 '--listen-port', "$ReversePort", '--set', 'keep_host_header=true')
$proxyArgs   = @('--mode', "regular@$ProxyPort", '--listen-host', $ListenHost)
$sniffArgs   = @('--mode', "regular@$ProxyPort", '--listen-host', $ListenHost, '--set', 'flow_detail=2')
$transArgs   = @('--mode', 'transparent', '--listen-host', $ListenHost, '--listen-port', "$ProxyPort")

Write-Host ''
Write-Host ('=' * 74) -ForegroundColor DarkCyan
Write-Host ("fsd_mock | mode={0} | upstream={1} | listen={2} | emudhra={3}" -f $Mode, $UpstreamIp, $ListenHost, (-not $NoEmudhra)) -ForegroundColor Cyan
Write-Host ('=' * 74) -ForegroundColor DarkCyan
Write-Host "confdir = $confdir"
Write-Host 'payload = 282 字节, X-Checksum = 104ccde7d817ab00667f2d98326259ec'
Write-Host ''
Write-Host '本机 IPv4:' -ForegroundColor Yellow
Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
    ForEach-Object { Write-Host ("  {0,-15} {1}" -f $_.IPAddress, $_.InterfaceAlias) }
Write-Host ''
Write-Host '命中日志: ' -NoNewline; Write-Host (Join-Path $logDir 'hits.jsonl') -ForegroundColor Green
Write-Host '实时观察: ' -NoNewline; Write-Host 'Get-Content .\logs\hits.jsonl -Tail 20 -Wait' -ForegroundColor Green
Write-Host ''

if ($Mode -in @('reverse', 'both')) {
    Write-Host '车机侧: 让 mothership.vn.teslamotors.com 解析到本机 → 端口 4567 命中（HTTP 明文，不需要装证书）' -ForegroundColor Yellow
}
if ($Mode -in @('proxy', 'sniff')) {
    Write-Host ("车机侧: Wi-Fi 代理 = 本机IP:{0}（HTTPS 靠 --emudhra 的 emSign 链）" -f $ProxyPort) -ForegroundColor Yellow
}
Write-Host ''

if ($Mode -eq 'transparent') {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Host '透明模式需要管理员（WinDivert 驱动）→ 弹 UAC 重开...' -ForegroundColor Yellow
        $argv = @('-NoExit', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath,
                  '-Mode', 'transparent', '-ProxyPort', $ProxyPort, '-ListenHost', $ListenHost)
        if ($NoEmudhra) { $argv += '-NoEmudhra' }
        Start-Process -FilePath $shell -Verb RunAs -ArgumentList $argv | Out-Null
        return
    }
    & $mitmdump @($common + $transArgs)
    return
}

if ($Mode -eq 'both') {
    Start-Process -FilePath $mitmdump -ArgumentList @($common + $reverseArgs) -WindowStyle Minimized | Out-Null
    Write-Host "reverse :$ReversePort 已在另一个窗口启动；前台跑 $ProxyPort ..." -ForegroundColor Green
    Start-Sleep -Seconds 2
    & $mitmdump @($common + $proxyArgs)
    return
}

$argsOne = switch ($Mode) {
    'reverse' { $reverseArgs }
    'proxy'   { $proxyArgs }
    'sniff'   { $sniffArgs }
}
& $mitmdump @($common + $argsOne)
