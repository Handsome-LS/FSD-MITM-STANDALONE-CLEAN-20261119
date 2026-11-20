# FSD feature_configuration 拦截项目 — 交接说明（给外部协助者）

生成时间：2026-11-10 00:36 (+08:00)
机器：Windows 11 Pro（`DESKTOP-XXXXXXX`，用户 `NIO`，**非管理员会话**，所有提权操作需用户点 UAC）

---

## 1. 目标

车机（Tesla，MAC `4C:FC:AA:00:00:00`）在 F50 的 WiFi 下，把
`POST …/feature_configuration` 请求送到 PC 上的 mitmproxy，由插件短路返回固定 JSON：

```json
{"eu_fsd_allowed_country_codes":"CHN","eu_fsd_allow_region_override":true,"enable_eu_fsd_behavior":true,
 "full_self_driving":true,"fsd_navigation_supported":true,"fsd_stops_maps":true,"drive_on_nav_maps":true,
 "lane_support_system":true,"lab_diagnostic_marker":"cn-region-http-probe"}
```

282 字节，`X-Checksum: 104ccde7d817ab00667f2d98326259ec`（md5(body)），`Content-Type: application/json`，`Cache-Control: no-store`。
mitmproxy 必须带：
`--ignore-hosts '^(hermes-prd|hermes-stream-prd|telemetry-prd)\.vn\.cloud\.tesla\.cn(?::\d+)?$'`（三域名只隧道不解密）。

---

## 2. 项目目录

| 路径 | 说明 |
|---|---|
| **`C:\fsd-mitm`** | 主力部署包（成品、可运行） |
| `C:\Users\USER\Desktop\TESL` | 封闭实验室包（合成 payload、host 限定 `feature-config.f50.test`、8082/8083），与车机链路无关 |

### `C:\fsd-mitm` 关键文件

| 文件 | 作用 |
|---|---|
| `fsd_mock.py` | mitmproxy 插件：命中 `/feature_configuration`（任何方法，含 POST）→ 先记录原始请求（VIN/req_bytes/req_md5/落盘 `logs\requests\*.bin`）→ 回 282B；支持 `reply`/`observe` 模式（`mode.json` 热加载） |
| `payload.json` | 上面那 9 字段（改它即热加载） |
| `dns_sink.py` | UDP 53：`mothership.vn.teslamotors.com` → 本机 IP，其余转发 223.5.5.5/1.1.1.1 |
| `svc\stack.py` | 常驻守护：管 dns(53)/reverse(4567)/proxy(8080)/web(8899)，8s 自检；**本机 IP 变化会自动重启 dns_sink** |
| `web\server.py` + `web\static\index.html` | 看板 `http://127.0.0.1:8899`：状态灯 / 命中表 / 原始 POST / payload 编辑 / 模式切换 |
| `run.ps1` | 手动启动：`-Mode reverse\|proxy\|both\|sniff\|transparent` |
| `test.ps1` | 自检（POST；若端口已在跑则借用现有实例，不杀） |
| `tools\car_check.ps1` | 一键诊断（车机在线 / 端口 / DNS 劫持 / 是否命中） |
| `tools\lan_scan.py` | UDP 触发 ARP + 邻居表扫描找 Tesla MAC |
| `fix-once.ps1` | 一次 UAC：放行 TCP 4567/8080、UDP 53 并打印车机侧要填的 DNS |
| `route-b.ps1` | 备选方案：开移动热点 + ICS，让车机连 PC 热点（DNS 自动=PC） |
| `certs2\` | 默认证书库；`--emudhra` 实际签名 CA = `EM OV TLS CA - G3C`（emSign 根可信） |
| `certs3\` | 用用户提供的 `mitmproxy-ca.pem`（`EM DV TLS CA - G3B`）当 CA 的证书库 |
| `logs\hits.jsonl` | HIT / FLOW / OBSERVE 流水 |
| `logs\requests\` | 车机原始请求体（.bin） |
| `venv\` | Python 3.12 + mitmproxy 12.3.1（**非官方构建，带 `--emudhra/--emudhra-old`**） |

---

## 3. 当前状态（2026-11-10 00:36 实测）

| 项 | 状态 |
|---|---|
| PC 所连 WiFi | **`Sulwhasoo_5G_EXT`，IP `192.168.1.11`**（已离开 F50 的 `FSD-SCORE`/`192.168.199.x`） |
| 常驻栈 | **未运行**：无 `python/mitmdump` 进程，4567 / 8080 / 8899 全部不通 |
| 车机 `192.168.199.95` | ping 超时（不在同一网段，正常） |
| 本网段（192.168.1.x）扫描 | 无 Tesla MAC（`4c-fc-aa`），车机不在这个网段 |
| 防火墙 | `fsd-mitm*` 规则 **0 条**；网络配置文件 = Public，默认阻止入站 |
| 车机 DNS 查询到 PC | 历史 0 条 |
| 车机命中 | 历史 0 条（`hits.jsonl` 里 26 条全是 127.0.0.1 自测） |

---

## 4. 问题（按顺序）

1. **物理链路断了**：PC 现在不在 F50 网段，车机在 `192.168.199.95`，两边不可达 → 一切拦截都无从发生。
2. **PC 侧服务全停**：栈进程随会话/网络变化被杀（`Startup` 里的自启项只在登录时执行，不会自愈）。
3. **（结构性）车机 DNS 仍指向 F50**：`192.168.199.1`。F50 是 ZTE MU5002/MU5120 的 UFI 固件，**后台没有任何可用的 DNS 设置**（已核：`:2333` UFI-TOOLS 页面 0 处 dns；`:80` 厂商后台 `js/adm/lan.js` 0 处；APN 页的 `dnsMode/dns1/dns2` 被 `config.js` 的 `SHOW_APN_DNS:!1` 关死；goform 命令表里只有 `static_wan_primary_dns`，无 LAN DNS）。→ 即使 1、2 修好，车机也不会把请求发到 PC。
4. **防火墙未放行**：即便 DNS 指对了，车机连 `4567` 的 SYN 会被 Public 配置丢弃。

> 已解决/已验证（不要重复做）：插件 POST 命中 200/282B + checksum；HTTPS 侧 TLS1.3 + `--emudhra` 链（emSign 根校验通过）；`--ignore-hosts` 三域名隧道生效；`reply/observe` 热切换；看板与诊断工具可用；`stack.py` 的 IP 变更自愈已实测（换网后自动把 DNS 应答切到新 IP）。

---

## 5. 修复路径（二选一，都需要一点本机权限/设备操作）

### 路线 A：车机继续连 F50（需要车机里有 DNS 输入框）

```powershell
# 1) PC 连回 FSD-SCORE（F50 的 WiFi）
# 2) 放行防火墙（一次 UAC）
cd C:\fsd-mitm
.\fix-once.ps1
# 3) 起常驻栈
C:\fsd-mitm\venv\Scripts\python.exe C:\fsd-mitm\svc\stack.py
#    后台常驻写法：
#    Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
#      CommandLine='"C:\fsd-mitm\venv\Scripts\python.exe" "C:\fsd-mitm\svc\stack.py"'; CurrentDirectory='C:\fsd-mitm'}
# 4) 车机 Wi-Fi → FSD-SCORE → 高级/静态设置 → DNS = 192.168.199.148
#    车机若无 DNS 输入框 → 走路线 B
# 5) 重启车机，等 5–10 分钟
C:\fsd-mitm\tools\car_check.ps1
```

### 路线 B：车机改连 PC 热点（车机没有任何设置可改时用这个）

```powershell
cd C:\fsd-mitm
.\route-b.ps1          # 开热点 FSD-PC / fsd2026!! + ICS 共享（弹 UAC）
# 车机 Wi-Fi 连 FSD-PC → 拿到 192.168.137.x，DNS 自动是 192.168.137.1（本机）
# 重启车机，等 5–10 分钟；回滚：.\route-b.ps1 -Stop
```

### 验收标准

`C:\fsd-mitm\logs\hits.jsonl` 出现 `"kind":"HIT"` 且 `"client":"<车机IP>"`、`"bytes":282`；
看板 `http://127.0.0.1:8899`「最近命中」出现该行，「车机最近一条原始请求」显示真实 VIN。

---

## 6. 已知坑（务必按这个来）

| 坑 | 说明 |
|---|---|
| `--set connection_strategy=lazy` 必须加 | 否则请求一到就去连上游，上游不通时 mock 也回不了（实测卡死） |
| reverse 模式上游别指自己 | 默认回落 `192.0.2.1`（黑洞），保证 feature_configuration 仍回包 |
| `--set ssl_insecure=true` | 该网络里上游链校验不过（`SEC_E_UNTRUSTED_ROOT`） |
| 车机侧是 **POST**，不是 GET | 插件按路径匹配、不限方法；自测也用 POST |
| 12h 缓存 | 命中后 12h±2h 才会再请求，验证别急，必要时重启车机 |
| 车机会睡眠 | Wi-Fi 省电，ping 时通时断（rtt 2–8ms），别用单次 ping 判断掉线 |
| 本机 mitmproxy 非官方 | `mitmproxy\certs.py` 内置 eMudhra 中间 CA 私钥 + `--emudhra` 选项，只在这台机器适用 |
| `api-prd` 需要客户端证书 | 直连返回 `400 No required SSL certificate was sent`，所以只做 mock，不做全量 HTTPS 代理 |

---

## 7. 期望的最终链路

```
车机 --WiFi--> F50 (192.168.199.1)
   │  DNS 指向 192.168.199.148（路线 A）/ 或车机在 PC 热点 192.168.137.x（路线 B）
   │  POST http://mothership.vn.teslamotors.com:4567/vehicles/<VIN>/feature_configuration
   ▼
PC  dns_sink:53 → 应答 192.168.199.148
PC  mitmproxy reverse:4567 → 200 / 282B / X-Checksum 104ccde7…
   其余流量 → 直出 F50（不过 PC）
```

---

## 8. 2026-11-13 更新（交接必读）

完整清单见 **`CHANGELOG-2026-11-13.md`**，备份在 `backup\2026-11-13_1910\`。要点：

| 项 | 变化 |
|---|---|
| 自启 | 改为 `HKCU\...\Run\fsd-mitm-stack` 直连 `pythonw`；**不再依赖启动文件夹**（那份 .cmd 曾于 11-12 消失，导致栈空转 23h） |
| `svc\stack.py` | 加单实例锁 `127.0.0.1:45799`，多启动器同时触发只起一份 |
| `dns_sink.py` | 改为按客户端反查出口 IP 作答 → 热点 `192.168.137.1` 与 F50 `192.168.199.148` 双网段都正确 |
| 防火墙 | 4 条入站放行（TCP 4567/8080/8899、UDP 53），`Profile=Any` |
| 移动热点 | `FSD-PC` / `fsd2026!!` 已开；**空闲约 5 分钟会被 Windows 自动关**，由 `tools\keep_hotspot.ps1` 保活 |
| 新工具 | `tools\install.ps1`（装/查/撤）、`tools\watch_car.ps1`（三层判读）、`tools\keep_hotspot.ps1` |

常用命令：

```powershell
C:\fsd-mitm\tools\install.ps1 -Check        # 一键体检
C:\fsd-mitm\tools\install.ps1 -Hotspot      # 装好并开热点
C:\fsd-mitm\tools\watch_car.ps1 -Minutes 15 # 盯车机是否进来
C:\fsd-mitm\tools\install.ps1 -Uninstall    # 全撤
```

当前阻断点不变：**车机 DNS 仍指向 F50（192.168.199.1）**，F50 的 UFI 固件没有 LAN DNS 设置项。
要么车机连 `FSD-PC` 热点（服务端已端到端验证），要么在本机做 ARP 劫持（需管理员）。
截至 19:08：`hits.jsonl` 里车机命中 0 条，所有 HIT 的 client 都是 `127.0.0.1` / `192.168.137.1` 自测。
