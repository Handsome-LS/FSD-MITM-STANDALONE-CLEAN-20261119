# FSD 拦截环境 · 二代独立包（ARP + 443 反向）

> 打包时间：2026-11-19 22:35（+08:00）　来源：`C:\fsd-mitm`
> 一句话：车机拉功能配置时，把 `POST /mothership/vehicles/<VIN>/feature_configuration` 短路成自定义 JSON，把 `full_self_driving` 等开关置真。
> 这套是**已验证**的那套：真实车机命中 8 次（11-13 ×3、11-14 ×1、11-15 ×3、11-19 ×1）。

```
FSD-MITM-STANDALONE-20261119\
├─ 一键安装.cmd        ← 双击即装（推荐入口，纯 ASCII，不会乱码）
├─ install.ps1         ← 安装器本体（7 步，幂等）
├─ README.md           ← 本文件
└─ app\                ← 要部署的全部程序（74 个文件 / 289 KB）
    ├─ start_all.ps1 / start_all.cmd      启动（栈 + ARP + 443 + 看板 + 看门狗）
    ├─ stop_fsd_all.ps1                   全停（含看门狗）
    ├─ stop_api_intercept.ps1             只撤 api-prd 拦截，车机 API 立刻恢复
    ├─ fsd_mock.py                        命中即短路 + 热加载 payload
    ├─ payload.json                       ★ 当前下发载荷（602 B / 20 字段）
    ├─ payload-16f.json / payload-282b.json   回滚样本（476 B / 282 B）
    ├─ mode.json                          reply / observe 切换
    ├─ dns_sink.py                        DNS：指定域名 → 本机
    ├─ svc\stack.py                       常驻栈守护（4567 / 8080 / 53 / 8899）
    ├─ tools\arp_mitm.py                  ★ ARP 投毒 + DNS 应答 + 二层转发
    ├─ tools\supervise_all.py             ★ 看门狗（30 s 巡检）
    ├─ web\fsd_panel.py                   ★ 8900 看板（纯服务端渲染，0 JS）
    ├─ web\server.py                      8899 旧看板
    ├─ certs\  certs2\  certs3\           三套伪造 CA（certs2 = G3C，命中时用这套）
    ├─ requirements.txt                   依赖清单（44 个固定版本）
    └─ HANDOVER-2026-11-14.md             原始移交说明（坑清单在第 6 节，必读）
```

---

## 1. 安装

**要求**：Windows 10/11 x64 · PowerShell 5.1+ · 有网（装依赖）· 一次管理员 UAC（补防火墙规则）。

**Python 3.10–3.13，没有也能装。** 安装器按 7 级顺序自动找：

```
-PythonExe → PATH（自动跳过 WindowsApps\python.exe 商店占位符）→ py 启动器
→ 标准安装目录 → 注册表 → 随附运行时（如 DSH 自带 Python）→ 现有 venv 的 base
```

都找不到时加 `-AutoInstallPython`，用 winget 静默装 3.12。Windows 上 `python` 命令经常只是
`%LOCALAPPDATA%\Microsoft\WindowsApps\python.exe` —— 0 字节的应用商店占位符，**不是真 Python**，
安装器会识别并跳过。

### 方式 A：双击

双击 **`一键安装.cmd`**，看完提示按任意键关闭。

### 方式 B：命令行（可带参数）

```powershell
cd C:\Users\USER\Desktop\FSD-MITM-STANDALONE-20261119
.\install.ps1                 # 全套：体检 → 复制 → venv → 依赖 → 快捷方式 → 自启 → 启动
.\install.ps1 -Check          # 只体检，不动任何文件（先在目标机跑这个）
.\install.ps1 -NoStart        # 部署完不启动
.\install.ps1 -UseMirror      # pip 走清华源（国内慢时用）
.\install.ps1 -SkipVenv       # 已有可用 venv，跳过重建
.\install.ps1 -Force          # 目标已有部署时强制覆盖源码
.\install.ps1 -AutoInstallPython   # 没装 Python 时用 winget 自动装 3.12
.\install.ps1 -PythonExe "C:\Python312\python.exe"
```

### 安装器做了什么（7 步）

| 步 | 动作 | 说明 |
|---|---|---|
| 0 | 环境检查 | PS 版本 / x64 / 源完整性 |
| 1 | 目录检查 | **必须是 `C:\fsd-mitm`**；已有部署会提示加 `-Force`；检测 443/4567/8080/8899/8900 占用 |
| 2 | 复制文件 | robocopy；**不覆盖 `logs\` `venv\`**；已有 `payload.json` 自动备份为 `payload.json.preinstall-<时间戳>` |
| 3 | 虚拟环境 | 自动找 Python（7 级顺序，见第 1 节），建 venv，`pip install -r requirements.txt`；坏 venv 改名 `venv.broken-<时间戳>` 而非删除 |
| 4 | 文件体检 | 10 项关键文件 + payload JSON 合法性 |
| 5 | 快捷方式 | 桌面「FSD一键启动 / FSD一键停止」 |
| 6 | 登录自启 | `HKCU\...\Run\fsd-mitm-supervisor` → 看门狗 |
| 7 | 启动 | 调 `start_all.ps1`（首次会弹一次 UAC 补防火墙） |

全程日志：`C:\fsd-mitm\logs\install-<时间戳>.log`。

### 为什么只能装到 `C:\fsd-mitm`

项目里约 24 处路径是写死的：`svc\stack.py`、`tools\supervise_all.py`（`ROOT`）、`web\server.py`、`stop_stack.ps1`、`svc\stack_start.cmd`（`ROOT`）、`tools\selftest.py`（`CAFILE`）。安装器**不做**路径改写 —— 装到别的盘，脚本会在错误的路径找文件。要换盘必须先手工改完这批再装。

---

## 2. 装完之后怎么用

> **先选接入链路**：车机流量怎么送到这台电脑有三种方式（手机 USB + 电脑热点 / 电脑连手机热点再开热点 / F50 的 `FSD-SCORE`），详见文末 **第 9 节**。拓扑选错，`start_all.cmd` 起来也抓不到东西。

```powershell
# 启动（幂等，可重复执行）
C:\fsd-mitm\start_all.cmd
# 或双击桌面「FSD一键启动」

# 看状态（9 项：栈/代理/看板/443/看板8900/ARP/看门狗/防火墙/自启）
powershell -File C:\fsd-mitm\start_all.ps1 -Status

# 停止（含看门狗，否则会被拉起）
powershell -File C:\fsd-mitm\stop_fsd_all.ps1
# 或双击桌面「FSD一键停止」

# 只撤 api-prd 拦截，让车机 API 立刻恢复正常
powershell -File C:\fsd-mitm\stop_api_intercept.ps1
```

**看板**：<http://127.0.0.1:8900>　（配置 `/config`、载荷编辑 `/payload`、命中与握手时间线）
**旧看板**：<http://127.0.0.1:8899>

**改载荷**：直接编辑 `C:\fsd-mitm\payload.json`，插件按 mtime 热加载，不用重启任何进程。改完车机不会立刻来取，等它下一次请求（或重启车机）。

**命中判据**（三条都成立才算成功）：

1. `logs\hits.jsonl` 新增 `"kind":"HIT"`，且 `"client"` 是**车机 IP**（`127.0.0.1` 是自测，不算）
2. 响应字节数 = `payload.json` 长度
3. `logs\requests\*.bin` 里有车机原始请求体

---

## 3. 上车的参数在哪改（本包已按上次现场写死，换车/换网段必改）

| 位置 | 值 | 说明 |
|---|---|---|
| `app\start_all.ps1` 第 ~91 行 | `--target 192.168.199.95` | 车机 IP |
| 同上 | `--gateway 192.168.199.1` | 真实网关 |
| 同上 | `--our-ip 192.168.199.148` / `--answer 192.168.199.148` | 本机 IP（也是 DNS 应答） |
| 同上 | `--iface Wi-Fi` | 网卡名 |
| 同上 | `--rst-dst 52.81.9.181` | 被 RST 的旧上游 |
| `app\tools\arp_mitm.py` | `--target` 默认值 | 脚本级默认，实际由 start_all 传参覆盖 |

本机必须处于同一二层网段（和车机连同一个 `FSD-SCORE` Wi-Fi），否则 ARP 投毒发不出去（`arp_mitm.log` 里 `poison` 会涨但 `dns=0 fwd_l2=0`，等于空转）。

---

## 4. 旧部署迁移

本机 `C:\fsd-mitm` 已在运行时，安装器会拦住：

```powershell
# 先停
powershell -File C:\fsd-mitm\stop_fsd_all.ps1
# 再覆盖源码（logs / venv 保留，payload 自动备份）
.\install.ps1 -Force -SkipVenv
```

---

## 5. 目标机没有网络怎么办

`pip install` 需要外网。离线机器的做法：把**本机可用的** `C:\fsd-mitm\venv` 整个目录拷到目标机同路径（venv 里带绝对路径，路径必须一致），然后：

```powershell
.\install.ps1 -SkipVenv -NoStart
```

注意：从别处拷来的 venv 只有在 `C:\fsd-mitm\venv` 且 Python 版本一致时可用。

---

## 6. 敏感材料 —— 不要外发

| 文件 | 内容 |
|---|---|
| `app\certs2\mitmproxy-ca.pem`（及 `certs\` `certs3\`） | 伪造 CA **私钥**（eMudhra 同名链，私钥标量 d=4） |
| `app\HANDOVER-2026-11-14.md`、`CAR-ENDPOINTS-2026-11-13.md` | 真实车机 **VIN**、MAC、内网 IP |

这套 CA 能骗过该车机对 `api-prd.vn.cloud.tesla.cn` 的任意 TLS 连接 —— 只在受控机器与受控网段内使用。

---

## 7. 已知限制（别当 bug）

| 现象 | 原因 |
|---|---|
| 装完几分钟没命中 | 接口 12h±2h，启动后 5–10 分钟才首次；只能重启车机催 |
| 拦截期音乐/通知/天气 400 | 非 mock 接口要客户端证书，上游过不去，这是方法的固有代价 |
| 车机短暂断网 | ARP 引流断 30 秒以上；恢复后要 1 秒内重新投毒 |
| 后台进程随会话消失 | 必须用 WMI 启动（`Invoke-CimMethod Win32_Process Create`），HANDOVER 坑 #1 |
| `pythonw -m mitmproxy.tools.dump` 静默退出 | 这个 venv 的毛病，直接调 `mitmdump.exe`（安装器与 start_all 都已这么做） |
| 浏览器每 2 秒闪黑框 | `pythonw` 里调了控制台程序，所有 `subprocess` 需 `creationflags=0x08000000` |

---

## 8. 包里两个 install 别混

| 脚本 | 用途 |
|---|---|
| **根目录 `一键安装.cmd` / `install.ps1`** | 全新机器从零装（建 venv、装依赖、快捷方式、自启） |
| `app\install_client.cmd` / `install_client.ps1` | 原项目自带，假设 venv 已存在，只做体检 + 快捷方式 + 自启 + 启动 |

新机器用根目录那个；已有 venv 的机器两个都能用。

---

## 9. 接入方式：三条链路，先选一条

链路的本质只有一件事：**让车机把 `api-prd.vn.cloud.tesla.cn` 的流量交给这台电脑**。

| 链路 | 谁当网关 / DNS | 需要 ARP 投毒 | 网段 | 适用场景 |
|---|---|---|---|---|
| **① 手机 USB 共享 → 电脑开热点 → 车机连电脑** | 电脑 `192.168.137.1` | **不需要** | `192.168.137.0/24` | 没有 F50，或 F50 不让改 DNS。**最稳** |
| **② 电脑连手机热点 → 电脑再开热点 → 车机连电脑** | 电脑 `192.168.137.1` | **不需要** | 手机网段 + `192.168.137.0/24` | 只有一张无线网卡且驱动支持 STA+AP 并发；比 ① 多一跳 NAT |
| **③ 车机 + 电脑都连 F50 的 `FSD-SCORE`** | F50 `192.168.199.1` | **需要** | `192.168.199.0/24` | 原方案，已真实命中 8 次 |

> **别混用**：①② 里电脑本身已经是网关，**不要跑 `arp_mitm.py`**（多余、还会干扰）；③ 必须跑。

### ① 手机 USB 共享 → 电脑开热点（推荐）

```powershell
# 1) 手机 USB 连电脑，开启「USB 共享网络」，确认电脑有上行
Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway } |
  Select-Object InterfaceAlias, @{n='IP';e={$_.IPv4Address.IPAddress}}, @{n='GW';e={$_.IPv4DefaultGateway.NextHop}}

# 2) 电脑开热点（项目自带；SSID/密码可改）
C:\fsd-mitm\route-b.ps1 -Ssid FSD-PC -Key fsd2026!!
#    预期：本机多出 192.168.137.1

# 3) 车机连 FSD-PC → 应拿到 192.168.137.x，网关/DNS = 192.168.137.1
```

然后**不要用 `start_all.ps1`**（它会拉起 ARP 投毒），手工起三个组件：

```powershell
# 环境变量：不设的话 fsd_mock 用内置 282B，而不是 payload.json
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

> Windows 移动热点空闲约 5 分钟会自动关；长时间跑先执行 `C:\fsd-mitm\tools\keep_hotspot.ps1`。

### ② 电脑连手机热点 → 电脑再开热点

与 ① 完全一样，区别只是上行来自"电脑连着的手机热点"：

```powershell
# 先确认上行
Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway } | Select-Object InterfaceAlias

# 再开热点（网卡需支持 STA+AP 并发；不支持就回 ①）
C:\fsd-mitm\route-b.ps1 -Ssid FSD-PC -Key fsd2026!!
```

后续 DNS / 443 / 看板命令与 ① 相同。代价：多一跳 NAT、延迟略高、热点更易被自动关闭，部分无线驱动开着热点就掉 STA。

### ③ 车机 + 电脑都连 F50 的 `FSD-SCORE`（原方案）

```powershell
# 电脑连 FSD-SCORE，期望 192.168.199.148 / 网关 192.168.199.1
Get-NetIPConfiguration -InterfaceAlias 'Wi-Fi' | Select-Object IPv4Address, IPv4DefaultGateway

# 一键：防火墙 → 常驻栈 → ARP 引流 → 443 拦截 → 看板 → 看门狗
C:\fsd-mitm\start_all.cmd
```

这条路电脑**不是**网关，必须靠 ARP 投毒伪装成 `192.168.199.1`。`start_all.ps1` 里写死的参数（换车/换网段必改）：

```
--target  192.168.199.95      # 车机 IP
--gateway 192.168.199.1       # F50 真实网关
--our-ip  192.168.199.148     # 本机 IP
--answer  192.168.199.148     # DNS 应答指向本机
--iface   Wi-Fi
--rst-dst 52.81.9.181         # 对旧上游发 RST，逼车机重连
```

判据：看板出现车机，`logs\hits.jsonl` 出现 `"client":"192.168.199.95"` 的 `HIT`。

### 三条链路共用同一套验收

```powershell
# 车机流量到没到本机
Get-Content C:\fsd-mitm\logs\hits.jsonl -Tail 3

# 组件状态（①② 里「ARP 引流」一项必然 DOWN，正常）
powershell -File C:\fsd-mitm\start_all.ps1 -Status
```
# FSD-MITM-STANDALONE-CLEAN-20261119
