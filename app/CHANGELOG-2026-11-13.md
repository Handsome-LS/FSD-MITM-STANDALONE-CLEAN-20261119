# 变更记录 · 2026-11-13

本次会话对 `C:\fsd-mitm` 的所有改动、验证证据、回滚方式。项目不是 git 仓库（本机没装 git），
所以用"文件备份 + 本清单"来做版本快照。

---

## 0. 一句话

- **代码**：`svc\stack.py` 加单实例锁；`dns_sink.py` 改成按客户端反查出口 IP；新增 3 个工具脚本。
- **环境**：自启从"启动文件夹 .cmd"改为 `HKCU\...\Run`；防火墙 4 条入站放行；移动热点 `FSD-PC` 已开。
- **链路**：服务端全绿（4567/8080/8899/UDP53 全通，回包 282B 校验一致）；车机仍在 F50，未进链路，真命中 0 条。

---

## 1. 备份与回滚点

```
C:\fsd-mitm\backup\2026-11-13_1910\
├─ svc\stack.py                 (改后版本)
├─ svc\stack_start.cmd          (11-12 换过的启动器)
├─ dns_sink.py                  (改后版本)
├─ tools\watch_car.ps1
├─ tools\keep_hotspot.ps1
├─ fsd-mitm-stack.cmd           (桌面 TESLA 里的那份，与 svc 副本一致)
├─ MANIFEST.sha256              (上面 6 个文件的 SHA256 前缀 + 字节数)
├─ registry-run.txt             (HKCU Run 键导出)
├─ firewall-rules.txt           (4 条防火墙规则导出)
└─ runtime-state.txt            (19:08:09 运行态快照)
```

回滚单个文件：从上面目录拷回去即可；整体回滚见第 5 节。

---

## 2. 代码变更

### 2.1 `svc\stack.py` — 单实例锁（+845 B → 7794 B）

**动机**：同一时刻可能有多个启动器触发（Startup `.cmd`、`HKCU Run`、手动双击），
`stack.py` 原来没有互斥，会起两份守护进程、各自 `spawn` 一套 dns/reverse/proxy/web。

```python
LOCK_PORT = 45799
_lock_sock: socket.socket | None = None

def acquire_single_instance() -> bool:
    global _lock_sock
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.bind(("127.0.0.1", LOCK_PORT))
        s.listen(1)
    except OSError:
        s.close()
        return False
    _lock_sock = s
    return True

def main() -> None:
    if not acquire_single_instance():
        log("another stack.py instance is already running; exiting (single-instance lock)")
        return
```

**验证**：`127.0.0.1:45799` 处于 LISTEN（属主 = 当前 pythonw）；重复启动被挡，`pythonw` 逻辑实例仍为 1。

### 2.2 `dns_sink.py` — 按客户端回连 IP 作答（+728 B → 6819 B）

**动机**：原来用启动时固定的 `--ip` 作答。开移动热点后车机在 `192.168.137.0/24`，
而 `local_ip()` 取的是上行 F50 的 `192.168.199.148`，车机拿到这个地址不可达。

```python
def local_ip_for(peer_ip: str) -> str | None:
    """返回"客户端能回连到的那张网卡 IP"。"""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect((peer_ip, 9))
        ip = s.getsockname()[0]
        return ip if ip and not ip.startswith("0.") else None
    except OSError:
        return None
    finally:
        s.close()

# handle() 里：
answer_ip = local_ip_for(peer[0]) or self.ip
```

**验证**（源地址绑定后自问自答）：

| 问的来源 | 期望 | 实测 |
|---|---|---|
| `192.168.137.1` | `192.168.137.1` | ✅ |
| `192.168.199.148` | `192.168.199.148` | ✅ |

### 2.3 `tools\watch_car.ps1`（新增，4437 B）

三层判读车机是否进链路，只读、不改配置：

- **L1**：车机出现在 `192.168.137.x`（热点客户端）或 Tesla MAC `4C-FC-AA…` 邻居状态变化
- **L2**：`logs\dns.jsonl` 里 `peer` 不是本机 → 车机开始问我们的 DNS
- **L3**：`logs\hits.jsonl` 里 `HIT` 且 `client` 不是本机 → 请求落到 mitmproxy

用法：

```powershell
C:\fsd-mitm\tools\watch_car.ps1 -Once                                   # 看一眼
C:\fsd-mitm\tools\watch_car.ps1 -Minutes 15                             # 盯 15 分钟
C:\fsd-mitm\tools\watch_car.ps1 -Once -Since 2026-11-13T19:00:00        # 只看某时刻之后
```

`-Since` 很关键：`dns.jsonl` 里有 11-10 的历史记录（`192.168.1.11`），不设基线会误报。

### 2.4 `tools\keep_hotspot.ps1`（新增，2119 B）

**动机**：实测 Windows 移动热点**空闲约 5 分钟自动关闭**（WLAN 事件 18:55:25 开 → 19:00:25 关，期间无客户端）。
车机连 `FSD-PC` 之前热点必须还在，否则白折腾。

做法：每 90 秒检查 `192.168.137.1`，不在就重新拉起；日志 `logs\hotspot-keeper.log`。

### 2.5 `tools\install.ps1`（新增）

把"环境变更"变成可重复执行的脚本（幂等）：

```powershell
C:\fsd-mitm\tools\install.ps1            # 自启项 + 防火墙 + 起栈
C:\fsd-mitm\tools\install.ps1 -Hotspot   # 顺带开热点
C:\fsd-mitm\tools\install.ps1 -Check     # 只体检
C:\fsd-mitm\tools\install.ps1 -Uninstall # 撤自启 + 删防火墙 + 停栈
```

### 2.6 `svc\stack_start.cmd`（11-12 改过，本次沿用）

纯 ASCII + 全绝对路径 + `/check` 自检 + `8899` 在听就跳过。11-12 之前的版本有两个 bug：
UTF-8 中文注释在 CP936 下被 cmd 解析成乱码命令行；`%~dp0..` 相对路径在启动文件夹里失效。

---

## 3. 环境变更（不在文件里，需单独记录）

### 3.1 自启：`HKCU\Software\Microsoft\Windows\CurrentVersion\Run`

```
fsd-mitm-stack  REG_SZ  "C:\fsd-mitm\venv\Scripts\pythonw.exe" "C:\fsd-mitm\svc\stack.py"
```

- 为什么换：11-12 08:12 之后 Startup 里的 `fsd-mitm-stack.cmd` 消失了（删除原因不明），
  11-12 22:36 / 11-13 08:23 / 18:46 三次登录都没有任何启动记录。
- 为什么不走 cmd：Run 项直连 `pythonw`，**不创建控制台**，顺带消掉了 11-12 那 8 次
  `exited rc=3221225786`（`0xC000013A STATUS_CONTROL_C_EXIT`，启动器控制台关闭时把子进程一起带走的抖动）。
- 导出：`backup\2026-11-13_1910\registry-run.txt`

### 3.2 防火墙：4 条入站放行（`Profile=Any`）

| 规则 | 协议/端口 |
|---|---|
| `fsd-mitm-reverse-4567` | TCP 4567 |
| `fsd-mitm-proxy-8080` | TCP 8080 |
| `fsd-mitm-dns-53` | UDP 53 |
| `fsd-mitm-web-8899` | TCP 8899 |

改动前：`fsd-mitm*` 规则 0 条 + 网络配置 `Public` → 车机 SYN 会被默认丢弃。
导出：`backup\2026-11-13_1910\firewall-rules.txt`

### 3.3 移动热点 `FSD-PC`

- SSID `FSD-PC`，口令 `fsd2026!!`，本机 `192.168.137.1`，上行仍是 `FSD-SCORE`（Wi-Fi 未断）
- ICS `ScopeAddress = 192.168.137.1`，`SharedAccess` / `icssvc` 均在运行
- 空闲会自动关 → 由 `tools\keep_hotspot.ps1` 保活

---

## 4. 验证记录（19:00–19:08 实跑）

```
watch_car.ps1 -Once
[19:05:17] WAIT  热点=On  DNS(车)=0 HIT(车)=0 HIT(总)=0  热点客户端=0  Tesla邻居=1
  L1 Tesla  192.168.199.95  4C-FC-AA-00-00-00

install.ps1 -Check
  自启项   : OK  "C:\fsd-mitm\venv\Scripts\pythonw.exe" "C:\fsd-mitm\svc\stack.py"
  防火墙   : 4 条
  监听 TCP : 4567, 8080, 8899
  监听 UDP : 53
  移动热点 : On
  进程     : 12 个
  车机命中 : 0 条

反向代理自测（热点网段发起）
POST http://192.168.137.1:4567/vehicles/HOTSPOT-TEST/feature_configuration
-> HTTP 200 / 282 bytes / X-Checksum=104ccde7d817ab00667f2d98326259ec
```

---

## 5. 回滚

```powershell
# 全撤（自启 + 防火墙 + 栈）
C:\fsd-mitm\tools\install.ps1 -Uninstall

# 关热点
C:\fsd-mitm\hotspot.ps1 -Action stop

# 单文件回退
Copy-Item C:\fsd-mitm\backup\2026-11-13_1910\svc\stack.py    C:\fsd-mitm\svc\stack.py -Force
Copy-Item C:\fsd-mitm\backup\2026-11-13_1910\dns_sink.py     C:\fsd-mitm\dns_sink.py -Force
```

> 注意：备份里 `stack.py` / `dns_sink.py` 是**改后**版本（改前的原件没有留底）。
> 若要退回"无单实例锁 / 固定 IP 作答"，按第 2.1、2.2 节的片段反向删除即可。

---

## 6. 已知未决

1. **车机 DNS 仍在 F50**（`192.168.199.1`）。F50 的 UFI 固件没有任何 LAN DNS 设置项（11-10 已核），
   所以只能靠"车机连 PC 热点"或"ARP 劫持"两条路把它引到本机。
2. **移动热点空闲 5 分钟自动关闭**：已加保活，但保活本身是会话级后台任务，不是系统服务。
3. **`hits.jsonl` 在 19:04:03 被清空**：`web\server.py:612` 有 `POST /api/logs/clear`，
   看板上的"清空记录"按钮会清；已确认不是程序故障。
4. **车机命中 0 条**：截至 19:08，`hits.jsonl` 里所有 HIT 的 client 都是 `127.0.0.1` 或 `192.168.137.1`（自测）。
