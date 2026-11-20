# 车机 FSD `feature_configuration` 拦截包（Windows PC / mitmproxy）

目标：车机连到这台 PC 的 WiFi 链路后，任何 `/feature_configuration` 请求都被 mitmproxy 直接回包：

```json
{"eu_fsd_allowed_country_codes":"CHN","eu_fsd_allow_region_override":true,"enable_eu_fsd_behavior":true,"full_self_driving":true,"fsd_navigation_supported":true,"fsd_stops_maps":true,"drive_on_nav_maps":true,"lane_support_system":true,"lab_diagnostic_marker":"cn-region-http-probe"}
```

282 字节，`X-Checksum: 104ccde7d817ab00667f2d98326259ec`（md5(body)），`Content-Type: application/json`，`Cache-Control: no-store`。

同时按你的要求强制加上了：

```
--ignore-hosts '^(hermes-prd|hermes-stream-prd|telemetry-prd)\.vn\.cloud\.tesla\.cn(?::\d+)?$'
```

---

## 一、本机实测结果（不是纸上配置）

| 验证项 | 结果 |
|---|---|
| `POST/GET /feature_configuration`（HTTP 明文，4567 反向） | 200，282 字节，checksum 正确 |
| HTTPS `api-prd.vn.cloud.tesla.cn`（8080 代理，`--emudhra`） | TLS1.3，leaf `CN=api-prd...`，issuer `EM OV TLS CA - G3C`，用 **emSign ECC Root CA - G3** 校验证书链 + 主机名 **通过** → 车机不用装 CA |
| 你给的 `mitmproxy-ca.pem`（`certs3`，`-NoEmudhra`） | issuer `EM DV TLS CA - G3B`，SAN 含 `api-prd.vn.cloud.tesla.cn` / `device-api.prd.*`，同样链校验通过 |
| `--ignore-hosts` 三台域名 | 只做 TCP 隧道，不 MITM（curl 看到的是真实服务端证书） |
| `connection_strategy=lazy` | 必需。默认 eager 会先连上游，上游不通时连 mock 都回不了（实测卡死） |
| Windows `--mode transparent` | 非管理员直接 `WinError 5`，官方提示 *unsupported, flaky, deprecated* → 只作兜底 |

自检命令（随时可复跑）：

```powershell
cd C:\fsd-mitm
.\test.ps1 -WithProxy     # 会自己起 4567、跑完自己收掉
```

---

## 二、目录结构

| 路径 | 作用 |
|---|---|
| `fsd_mock.py` | mitmproxy 插件：命中 `/feature_configuration` 就短路回包，命中写 `logs\hits.jsonl` |
| `run.ps1` | 启动器：`reverse` / `proxy` / `both` / `sniff` / `transparent` |
| `hotspot.ps1` | 用 WinRT 开关 Windows 移动热点（不需要管理员） |
| `hosts.ps1` | 加/删 hosts 劫持条目（自动备份 + UAC） |
| `fw.ps1` | 放行 4567 / 8080 / UDP 53（UAC） |
| `ca.ps1` | 导出可装到车机的信任证书 |
| `test.ps1`，`tools\selftest.py` | 本机自检（HTTP + TLS 链） |
| `dns_sink.py` | 极简 DNS：只把指定域名指到本机，其余转发上游 |
| `venv\` | 独立 Python 3.12 + mitmproxy 12.3.1（不污染系统） |
| `certs2\` | 默认证书库（`--emudhra` 实际签名 CA = `EM OV TLS CA - G3C`） |
| `certs3\` | 用你给的 `mitmproxy-ca.pem` 当 CA 的证书库（`-NoEmudhra -Confdir ...\certs3`） |
| `certs\` | 拆出来的 `1-leaf-ca.pem` / `2-intermediate.pem` / `3-root-emsign-ecc-g3.pem` / `ca-key.pem` |
| `logs\hits.jsonl` | 命中流水（HIT / FLOW / NEAR_MISS） |

---

## 三、先让车机的流量走到这台 PC

> **这台机器现在的实际拓扑（2026-11-09 实测）**
> PC 的 Wi-Fi 连的是 **FSD-SCORE**（BSSID `5c:7d:ae:6a:6f:b0`，OUI = zte corporation），网关 `192.168.199.1` 是 **ZTE 的 5G CPE（F50 那台）**，本机 IP `192.168.199.148`。
> PC 自己的「移动热点」是 **Off**，系统里没有 `192.168.137.x`，所以**车机应该连 F50 的 WiFi，不是 PC 热点**。
> 这种情况下走「路线 A」：车机 DNS 指向 `192.168.199.148`（PC 上已跑 `dns_sink.py`，实测能把 `mothership.vn.teslamotors.com` 答成 `192.168.199.148`，其它域名正常转发）。
> 只有在 F50 不允许改 DNS/客户端隔离关不掉时，才退回「路线 B」用 PC 热点 + ICS + hosts。
>
> **常驻栈（2026-11-09 已部署）**：`svc\stack.py` 由 WMI 拉起，8 秒自检、挂了自动重启，管着
> DNS sink(UDP 53) / reverse(4567) / proxy(8080) / 看板(8899)；开机自启项 `Startup\fsd-mitm-stack.cmd`。
> 停止：`.\svc\stop_stack.ps1`；一键体检：`.\tools\car_check.ps1`。
> 车机实测：`192.168.199.95`，MAC `4c-fc-aa-00-00-00`（Tesla,Inc.），PC 能 ping 通 → F50 没开客户端隔离。

### 当前版本（二代）的三条接入链路

链路的本质只有一件事：**让车机把 `api-prd.vn.cloud.tesla.cn` 的流量交给这台 PC**。三选一，选定再决定跑不跑 ARP。

| 链路 | 谁当网关 / DNS | 需要 ARP 投毒 | 网段 | 适用场景 |
|---|---|---|---|---|
| **① 手机 USB 共享 → 电脑开热点 → 车机连电脑** | 电脑 `192.168.137.1` | **不需要** | `192.168.137.0/24` | 没有 F50，或 F50 不让改 DNS。**最稳** |
| **② 电脑连手机热点 → 电脑再开热点 → 车机连电脑** | 电脑 `192.168.137.1` | **不需要** | 手机网段 + `192.168.137.0/24` | 只有一张无线网卡且驱动支持 STA+AP 并发；比 ① 多一跳 NAT |
| **③ 车机 + 电脑都连 F50 的 `FSD-SCORE`** | F50 `192.168.199.1` | **需要** | `192.168.199.0/24` | 原方案，已真实命中 8 次 |

> **别混用**：①② 里电脑本身就是网关，**不要跑 `arp_mitm.py`**（多余且干扰）；③ 必须跑。

#### ① 手机 USB 共享 → 电脑开热点（推荐）

```powershell
# 1) 手机 USB 连电脑，开启「USB 共享网络」，确认电脑有上行
Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway } |
  Select-Object InterfaceAlias, @{n='IP';e={$_.IPv4Address.IPAddress}}, @{n='GW';e={$_.IPv4DefaultGateway.NextHop}}

# 2) 电脑开热点（项目自带脚本；SSID/密码可改）
.\route-b.ps1 -Ssid FSD-PC -Key fsd2026!!
#    预期：本机多出 192.168.137.1

# 3) 车机连 FSD-PC → 应拿到 192.168.137.x，网关/DNS = 192.168.137.1
```

然后**不要用 `start_all.ps1`**（它会拉起 ARP 投毒），手工起三个组件：

```powershell
# 环境变量：不设的话 fsd_mock 会用内置 282B，而不是 payload.json
New-Item -ItemType Directory -Path C:\fsd-mitm\logs -Force | Out-Null   # 日志目录丢了会静默丢记录
$env:FSD_MOCK_JSON      = 'C:\fsd-mitm\payload.json'
$env:FSD_MOCK_LOG_DIR   = 'C:\fsd-mitm\logs'
$env:FSD_MOCK_MODE_FILE = 'C:\fsd-mitm\mode.json'

# 443 反向拦截（certs2 = 车机认的 G3C 链）
Start-Process C:\fsd-mitm\venv\Scripts\mitmdump.exe -WindowStyle Hidden -ArgumentList @(
  '-s','C:\fsd-mitm\fsd_mock.py',
  '--set','confdir=C:\fsd-mitm\certs2','--set','ssl_insecure=true',
  '--set','connection_strategy=lazy','--set','block_global=false','--emudhra',
  '--mode','reverse:https://api-prd.vn.cloud.tesla.cn@443')

# DNS：把车机对 api-prd 的解析指到本机
Start-Process C:\fsd-mitm\venv\Scripts\python.exe -WindowStyle Hidden -ArgumentList @(
  'C:\fsd-mitm\dns_sink.py','--ip','192.168.137.1',
  '--redirect','api-prd.vn.cloud.tesla.cn')

# 看板
Start-Process C:\fsd-mitm\venv\Scripts\pythonw.exe -WindowStyle Hidden -ArgumentList @(
  'C:\fsd-mitm\web\fsd_panel.py','--port','8900')
```

检查：

```powershell
netstat -ano | findstr ':53 '      # 53 被 ICS 的 DNS 代理占了 → dns_sink 绑不上
arp -a | findstr 192.168.137       # 应能看到车机
```

> Windows 移动热点空闲约 5 分钟会自动关；要长时间跑先执行 `.\tools\keep_hotspot.ps1`。

#### ② 电脑连手机热点 → 电脑再开热点

与 ① 完全一样，唯一区别是上行来自"电脑连着的手机热点"而不是 USB：

```powershell
# 先确认上行
Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway } | Select-Object InterfaceAlias

# 再开热点（网卡需支持 STA+AP 并发；不支持就回 ①）
.\route-b.ps1 -Ssid FSD-PC -Key fsd2026!!
```

后续 DNS / 443 / 看板命令与 ① 相同。代价：多一跳 NAT，延迟略高，热点更易被自动关闭，部分无线驱动开着热点就会掉 STA。

#### ③ 车机 + 电脑都连 F50 的 `FSD-SCORE`（原方案）

```powershell
# 电脑连 FSD-SCORE，期望 192.168.199.148 / 网关 192.168.199.1
Get-NetIPConfiguration -InterfaceAlias 'Wi-Fi' | Select-Object IPv4Address, IPv4DefaultGateway

# 一键：防火墙 → 常驻栈 → ARP 引流 → 443 拦截 → 看板 → 看门狗
C:\fsd-mitm\start_all.cmd
```

这条路电脑**不是**网关，必须靠 ARP 投毒把自己伪装成 `192.168.199.1`。`start_all.ps1` 里写死的参数（换车/换网段必改）：

```
--target  192.168.199.95      # 车机 IP
--gateway 192.168.199.1       # F50 真实网关
--our-ip  192.168.199.148     # 本机 IP
--answer  192.168.199.148     # DNS 应答指向本机
--iface   Wi-Fi
--rst-dst 52.81.9.181         # 对旧上游发 RST，逼车机重连
```

判据：看板出现车机，`logs\hits.jsonl` 出现 `"client":"192.168.199.95"` 的 `HIT`。

#### 三条链路共用同一套验收

```powershell
# 车机流量到没到本机
Get-Content C:\fsd-mitm\logs\hits.jsonl -Tail 3

# 组件状态（①② 里「ARP 引流」一项必然 DOWN，正常）
powershell -File C:\fsd-mitm\start_all.ps1 -Status
```

> 以下路线 A–D 属于 2026-11-09 的「明文 4567 / mothership」时代，保留作参考。当前版本走上面的三条链路。

### 路线 A：车机能改 DNS（最省事，明文 HTTP 4567，不需要证书）

1. 车机 Wi-Fi 设置里如果有静态 DNS / 高级设置 → DNS 填这台 PC 的 IP（和车机同网段，例如 `192.168.199.148`）。
2. PC 上放行端口并启动：
   ```powershell
   cd C:\fsd-mitm
   .\fw.ps1 -Action add                  # 一次性，弹 UAC
   .\run.ps1 -Mode reverse               # 前台跑，日志就在这个窗口
   ```
3. 车机连同一个 WiFi → **重启车机** → 等 **5–10 分钟**（首次 `feature_configuration` 就在这个窗口里）。

### 路线 B：PC 自己当热点 + 网关（车机改不了 DNS 时）

```powershell
cd C:\fsd-mitm
.\hotspot.ps1 -Action start              # SSID=FSD-SCORE  KEY=fsd2026!!（可 -Ssid/-Key 改）
```
- 「设置 → 网络和 Internet → 移动热点」里把「共享我的以下 Internet 连接」选成当前上网网卡（要给车机保留公网时必做）。
- 车机连 `FSD-SCORE`，会拿到 `192.168.137.x`，网关/DNS 都是 `192.168.137.1`。
- 然后在 PC 上做解析劫持 + 起反向代理：

```powershell
.\hosts.ps1 -Action add -Ip 192.168.137.1   # 管理员；自动备份 hosts
.\fw.ps1 -Action add
.\run.ps1 -Mode reverse
```

> 如果 ICS 的 DNS 没传到车机（车机报无网络/解析不了），改用车机静态 DNS 指向 `192.168.137.1`，
> 或者直接跑 `dns_sink.py` 当 DNS：`venv\Scripts\python.exe dns_sink.py --ip 192.168.137.1`。

### 路线 C：车机或网关能设 HTTP 代理（HTTPS 也能拦）

```powershell
.\run.ps1 -Mode proxy                     # 监听 0.0.0.0:8080
```
车机侧代理填 `PC_IP:8080`。HTTPS 由 `--emudhra` 的 emSign 链兜住，车机不用装证书；
车机若不信任 emSign 根：`.\ca.ps1` 然后把 `certs2\device-trust-EMOV-G3C.cer` 装进车机信任库。

### 路线 D：透明代理（想全量抓包/兜底）

```powershell
.\run.ps1 -Mode transparent               # 自动 UAC 提权，WinDivert
```
车机把 PC 当网关即可，不用改 DNS/代理。Windows 上这条是官方标注的 flaky 模式，失败就回 A/B。

### 先摸底（不知道车机到底发了什么）

```powershell
.\run.ps1 -Mode sniff                     # 只记录不拦截
Get-Content .\logs\hits.jsonl -Tail 50 -Wait
```
有 `FLOW` 记录 = 流量到了 PC；没有 = 链路/DNS/代理没生效。

---

## 四、车机侧动作与时间窗口

1. 连上上面那条 WiFi（DNS/代理/网关已按路线配好）。
2. 重启车机（长按两个滚轮约 10 秒，或车辆菜单里的重启）。
3. 启动后 **5–10 分钟** 内出现第一次 `feature_configuration` 检查。
4. 之后是 **12 小时 ± 2 小时** 一次 —— 命中后短时间内不会再请求，别以为没生效。
5. 观察命中：

```powershell
Get-Content C:\fsd-mitm\logs\hits.jsonl -Tail 20 -Wait
```

命中行长这样：

```json
{"ts":"2026-11-09T23:10:00+0800","kind":"HIT","method":"GET","url":"http://mothership.vn.teslamotors.com:4567/vehicles/<VIN>/feature_configuration","client":"192.168.137.42","bytes":282,"md5":"104ccde7d817ab00667f2d98326259ec"}
```

---

## 五、判定与排错

| 现象 | 含义 | 处理 |
|---|---|---|
| `hits.jsonl` 里出现 `HIT` | 成功 | 车机侧等它在下次检查里生效（必要时重启一次） |
| 只有 `FLOW` 没有 `HIT` | 流量到了 PC，但路径/主机没匹配 | 看 `url` / `host_header`；`FSD_MOCK_HOSTS` 留空即可全匹配 |
| 一条记录都没有 | 流量没到 PC | 路线没生效：DNS 没指过来、代理没设、防火墙拦了、热点没通 |
| `curl http://127.0.0.1:4567/...` 超时 | 没监听 | `.\run.ps1 -Mode reverse` 是否在跑；`-ListenHost` 必须 `0.0.0.0` |
| HTTPS 报证书错误 | 车机不信任 emSign / 做了证书固定 | 走路线 A（明文 4567 不需要证书）；或 `.\ca.ps1` 装 `EMOV-G3C` |
| 200 但 body 空 / 请求卡住 | `connection_strategy` 不是 lazy | `run.ps1` 已内置，别自己另拼参数 |
| 命中一次后再也不来 | 12h 缓存 | 等，或重启车机 |

---

## 六、关键参数为什么这么写

| 参数 | 原因 |
|---|---|
| `--ignore-hosts '^(hermes-prd\|hermes-stream-prd\|telemetry-prd)\.vn\.cloud\.tesla\.cn(?::\d+)?$'` | 这三台是遥测/网关流，MITM 会踩证书固定或把上报打挂，直接隧道放行 |
| `--set connection_strategy=lazy` | 先收完请求再决定连不连上游；否则上游不可达时 mock 也回不出去（实测会卡到 curl 超时） |
| `--set keep_host_header=true` | reverse 模式保留原 `Host`，上游按域名路由不乱 |
| `--set ssl_insecure=true` | 这条网络里上游链在本机校验不过（`SEC_E_UNTRUSTED_ROOT`），不校验免得把整条流拖挂 |
| `--emudhra` | 用 emSign 根信任的中间 CA 签 leaf，车机不装证书也认（`certs2`） |
| `-NoEmudhra -Confdir C:\fsd-mitm\certs3` | 改用你给的 `mitmproxy-ca.pem`（`EM DV TLS CA - G3B`），已实测链校验通过 |
| `FSD_MOCK_METHOD` / `FSD_MOCK_HOSTS` | 想只拦 `POST` 或只拦某些 Host 时用；默认全放行 |

插件行为：路径正则 `r"/feature_configuration/?($|[?#])"`，所以
`http://mothership...:4567/vehicles/<VIN>/feature_configuration`、
`https://api-prd.../mothership/vehicles/<VIN>/feature_configuration`、
以及带 query 的变体都命中；命中即短路，不访问上游。

---

## 七、回滚

```powershell
# 1) 停 mitmproxy：在跑的那个窗口按 Ctrl+C
# 2) 热点
.\hotspot.ps1 -Action stop
# 3) hosts
.\hosts.ps1 -Action remove
# 4) 防火墙
.\fw.ps1 -Action remove
# 5) hosts 备份（可选）
Copy-Item C:\Windows\System32\drivers\etc\hosts.bak-fsd-mitm C:\Windows\System32\drivers\etc\hosts -Force
```

车机侧：把 WiFi 的 DNS/代理改回自动，重启一次即可恢复原状。

---

## 八、两点必须知道的事实

1. **这台机器上 venv 里的 mitmproxy 不是官方原版**：`mitmproxy\certs.py` 里内置了 eMudhra 中间 CA 私钥并新增了 `--emudhra / --emudhra-old` 选项（官方 PyPI 包没有这些）。
   它正好是这套方案能"不装证书"的关键；但也意味着**只在这台机器上用**，换机器部署请从官方 release 重装后自行装 CA。
2. **车机若对 `api-prd` 做双向认证或证书固定**，HTTPS 路线一定失败：`api-prd` 实测会要求客户端证书（`400 No required SSL certificate was sent`）。
   这种情况下走路线 A/B 的明文 `:4567` 路径，那条不需要证书。

---

## 九、WEB 看板（车机连接状态 + 回传内容）

```powershell
cd C:\fsd-mitm
.\web.ps1                 # 打开 http://127.0.0.1:8899
```

看板读 `logs\hits.jsonl` + WinRT 热点状态，只在本机 8899 上跑，不占车机要用的端口。

| 区域 | 内容 |
|---|---|
| 顶部指示灯 | reverse:4567 / proxy:8080 / 热点 / 车机 四路状态 |
| 命中次数 | 累计 HIT、最近命中时间，带「测试一次」「清空日志」 |
| mitmproxy | 累计 FLOW、一键启停 reverse / proxy、显示上游 IP 与 pid |
| 车机连接 | 车机 IP、MAC、命中/流量计数、最后活动时间、ping 在线判定 |
| 热点 | 移动热点 On/Off、SSID、在线客户端（MAC + 主机名 + ARP 对上来的 IP）、开/关按钮 |
| 最近命中 | 时间 / 方法 / URL / 字节 / 客户端，并按 Host 汇总 |
| 回传内容 | 实际发出去的 JSON、字节数、`X-Checksum`、payload 来源（`payload.json` / 默认） |
| payload 编辑 | 改 JSON → 保存即生效（插件按 mtime 热加载，不用重启 mitmproxy），可一键恢复默认 |
| 最近流量 | FLOW / NEAR_MISS 明细，用来判断车机到底发了什么 |

车机识别逻辑：优先取 mitm 日志里的客户端 IP（排除回环/本机），没有就退回热点客户端 + `arp -a` 对 IP；「在线」是 `ping -n 1` 的实时结果。

配套 HTTP API（想自己接脚本也能用）：

| 方法 | 路径 | 作用 |
|---|---|---|
| GET | `/api/state` | 一次性返回上面所有数据 |
| POST | `/api/proxy/reverse/start` `/stop` | 起停 4567 反向实例 |
| POST | `/api/proxy/proxy/start` `/stop` | 起停 8080 代理实例 |
| POST | `/api/hotspot/start` `/stop` | 开关移动热点 |
| POST | `/api/selftest` | 往运行中的实例打一发 `feature_configuration`，返回状态/字节/checksum |
| POST | `/api/payload` | 覆盖 payload（body：`{"payload":{...}}`），热加载 |
| POST | `/api/payload/reset` | 恢复默认 9 字段 |
| POST | `/api/logs/clear` | 清空 `hits.jsonl` |

> 网页启动的实例自带 `FSD_MOCK_LOG_ALL=1`，所以「最近流量」有数据；用 `run.ps1` 手动起的不带，只会有 HIT。

---

## 十、POST 请求 / 观察模式（先看到，再回包）

车机的 `feature_configuration` 是 **POST**，插件本来按路径匹配、不限方法，所以 POST 直接命中；现在把「收到请求 → 记录 → 再回包」这条链做全了：

| 能力 | 说明 |
|---|---|
| 原始请求落盘 | 每条命中的 body 存到 `logs\requests\<时间>-<md5前8>.bin`，日志里带 `req_bytes / req_md5 / req_ctype / vin / req_head(前256字节) / req_file` |
| 应答模式 `reply` | 默认。收到 POST → 记录 → 返回 282 字节 + `X-Checksum` |
| 观察模式 `observe` | 只记录、**不回包**（请求照常走上游）。用来先摸清车机真实 POST 结构 |
| 切换方式 | 看板右栏「应答模式 / 仅观察」按钮，或 `POST /api/mode {"mode":"reply"|"observe"}`；写在 `mode.json`，插件热加载，不必重启 |

实测（2026-11-09 23:40）：

```
POST /vehicles/5YJ3E1EA7KF000001/feature_configuration
  -> HIT 200 / 282B / X-Checksum 104ccde7d817ab00667f2d98326259ec
  -> 记录 vin=5YJ3E1EA7KF000001 req_bytes=46 req_md5=0ff139a5... req_file=20261109-234026-0ff139a5.bin
observe 模式同一请求 -> 无响应（curl 超时），日志里只有 OBSERVE 记录
切回 reply -> 又是 200 / 282B
```

看板 API 里也带出来了：`state.mode`、`state.last_request{method,vin,req_bytes,req_md5,req_head,req_file}`。