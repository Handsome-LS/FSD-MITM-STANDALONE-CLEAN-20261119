#requires -Version 5.1
<#
car_check.ps1 — 一条命令看车机链路到底卡在哪

  .\tools\car_check.ps1                 # 自动扫 192.168.199.0/24
  .\tools\car_check.ps1 -Subnet 192.168.137

判读：
  1) 车机在不在线（Tesla MAC 前缀 4C:FC:AA）
  2) 4567 / 8080 / 53 / 8899 四个服务活着没有
  3) DNS 劫持生效没有（本机查 192.168.199.148 应得到 192.168.199.148）
  4) 车机有没有真的来查过 DNS / 打过 4567（看 logs\dns.jsonl、logs\hits.jsonl）
#>
[CmdletBinding()]
param(
    [string]$Subnet = '192.168.199',
    [string]$LocalIp = '192.168.199.148'
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$py = Join-Path $root 'venv\Scripts\python.exe'

function Line($t) { Write-Host "`n=== $t ===" -ForegroundColor Cyan }

Line "1. 本机地址"
Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
    ForEach-Object { "  {0,-16} {1}" -f $_.IPAddress, $_.InterfaceAlias }

Line "2. 局域网设备（找 Tesla 4c-fc-aa）"
& $py (Join-Path $root 'tools\lan_scan.py') $Subnet

Line "3. 服务端口（用真实请求判断）"
$t = $null
try { $t = Invoke-WebRequest "http://127.0.0.1:4567/vehicles/CHK/feature_configuration" -Headers @{ Host = 'mothership.vn.teslamotors.com' } -Method Post -ContentType 'application/json' -Body '{"source":"car_check"}' -UseBasicParsing -TimeoutSec 6
      "  4567 reverse : OK $($t.StatusCode) / $($t.RawContentLength) bytes / X-Checksum=$($t.Headers['X-Checksum'])" }
catch { "  4567 reverse : DOWN ($($_.Exception.Message))" }
try { $h = Invoke-WebRequest 'http://127.0.0.1:8899/api/state' -UseBasicParsing -TimeoutSec 6
      $st = $h.Content | ConvertFrom-Json
      "  8899 看板    : OK  hits=$($st.stats.hits) flows=$($st.stats.flows) reverse=$($st.mitm.reverse.running) proxy=$($st.mitm.proxy.running)" }
catch { "  8899 看板    : DOWN" }
$dnsEndpoints = @(Get-NetUDPEndpoint -LocalPort 53 -ErrorAction SilentlyContinue |
                  Where-Object { $_.LocalAddress -in @('0.0.0.0', $LocalIp) })
$sharing = Get-CimInstance -ClassName Win32_Service -Filter "Name='SharedAccess'" -ErrorAction SilentlyContinue
if ($sharing -and $sharing.ProcessId -in $dnsEndpoints.OwningProcess) {
    "  项目 DNS     : UDP 53 由 Windows SharedAccess 占用"
} else {
    try { $d = Resolve-DnsName 'mothership.vn.teslamotors.com' -Server $LocalIp -Type A -DnsOnly -NoHostsFile -ErrorAction Stop | Where-Object IPAddress
          if ($d.IPAddress -contains $LocalIp) { "  项目 DNS     : OK -> $LocalIp" } else { "  项目 DNS     : 返回 $($d.IPAddress -join ',')" } }
    catch { "  项目 DNS     : DOWN ($($_.Exception.Message))" }
}

Line "4. 车机有没有来过"
$dnsLog = Join-Path $root 'logs\dns.jsonl'
$hitLog = Join-Path $root 'logs\hits.jsonl'
if (Test-Path $dnsLog) {
    $fromCar = Get-Content $dnsLog -Tail 200 | ForEach-Object { try { $_ | ConvertFrom-Json } catch {} } |
               Where-Object { $_.peer -ne $LocalIp -and $_.peer -ne '127.0.0.1' }
    if ($fromCar) { "  DNS 查询来自: " + (($fromCar | Select-Object -ExpandProperty peer -Unique) -join ', ') }
    else { "  DNS 日志里还没有别的客户端来查（车机 DNS 还没指向本机？）" }
} else { "  没有 dns.jsonl" }
if (Test-Path $hitLog) {
    $hits = Get-Content $hitLog -Tail 200 | ForEach-Object { try { $_ | ConvertFrom-Json } catch {} } |
            Where-Object { $_.kind -eq 'HIT' -and $_.client -notin @($LocalIp, '127.0.0.1') }
    if ($hits) { $hits | Select-Object -Last 3 | ForEach-Object { "  命中: $($_.ts) $($_.client) $($_.url)" } }
    else { "  还没有来自车机的命中" }
}

Write-Host ''
Write-Host '下一步：' -ForegroundColor Yellow
Write-Host "  * 车机不在线 → 唤醒车机（开车门/用 App 唤醒），或让它重连 WiFi"
Write-Host "  * 车机在线但 DNS 没指向 $LocalIp → 车机 Wi-Fi 高级里把 DNS 改成 $LocalIp，或在 F50 后台把 LAN/DHCP 的 DNS 改成 $LocalIp"
Write-Host "  * DNS 指对了但 5–10 分钟没命中 → 重启车机；仍无则看台架上是否有其它端口/域名请求"
