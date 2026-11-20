# 车机实际端点测绘（2026-11-13 19:15–19:25，ARP 引流期间实测）

来源：`logs\dns.jsonl` 中 `peer=192.168.199.95` 的记录 + `logs\arp_mitm.log` 的 top flows。
车机：Tesla，MAC `4C:FC:AA:00:00:00`，IP `192.168.199.95`，F50 的 `FSD-SCORE` 网段。

## 1. 关键发现：`mothership.vn.teslamotors.com` 现在是 NXDOMAIN

| 查询方式 | 结果 |
|---|---|
| `Resolve-DnsName -Server 223.5.5.5` | DNS name does not exist |
| `Resolve-DnsName -Server 1.1.1.1` | DNS name does not exist |
| `Resolve-DnsName -Server 192.168.199.1`（车机用的就是它） | DNS name does not exist |

也就是说：**这个域名在公网上根本不存在**，车机不经过我们的 DNS 时也解析不出来。
所以"等它自己查 mothership"不会发生 —— 必须靠我们本地应答（已经就绪：`mothership.*` → `192.168.199.148`），
或者它开机时按历史缓存/硬编码 IP 直连。

## 2. 车机实际解析并连接的域名（86 条 DNS，去重）

| 域名 | 次数 | 归属 |
|---|---|---|
| `telemetry-prd.vn.cloud.tesla.cn` | 28 | 遥测（F50 DNS 返回 **0.0.0.0**，被地区策略屏蔽） |
| `nav-prd-maps.tesla.cn` | 6 | 导航 |
| `vehicle-files.prd.cnn1.vn.cloud.tesla.cn` | 4 | 车机文件 |
| `str01/02/03-prd.tesla.services.vn.cloud.tesla.cn` | 4/4/2 | 流媒体服务 |
| `apigateway-x2-trigger.tesla.cn` | 3 | 车控网关触发 |
| `hermes-prd.vn.cloud.tesla.cn` | 2 | 长连通道 |
| `assistant-api.prd.cnn1.vn.cloud.tesla.cn` | 2 | 语音助手 |
| 百度 `itsmap3/api.map/route.map/tracknavi/appnavi…` | 12 | 导航底图 |
| 腾讯 `gw.tai.qq.com / wecarplat.map.qq.com / mqtthalley…` | 8 | 导航/消息 |
| `ntp1/2/3.aliyun.com`、`ntp.ntsc.ac.cn` | 6 | 对时 |

**没有任何一条是 `mothership.*`。**

## 3. 车机实际连的 IP（top flows，单位：包/分钟）

| IP | 端口 | 反解 | 判断 |
|---|---|---|---|
| `180.101.49.70` | 443 | - | 百度（导航底图） |
| `180.101.212.22` | 443 | - | 百度 |
| `124.223.74.214` | 8443 | - | 非标端口，疑似车机长连 |
| `71.132.30.120` | 443 | `ec2-…cn-north-1.compute.amazonaws.com.cn` | 特斯拉中国区（AWS 北京） |
| `52.81.9.181` | 443 | 同上；= `api-prd.vn.cloud.tesla.cn` | **特斯拉 API** |
| `54.222.174.68` | 443 | 同上 | 特斯拉中国区 |
| `180.97.107.210` / `123.235.30.38` | 443 | - | 百度/腾讯 |

`api-prd.vn.cloud.tesla.cn` → `52.81.9.181`（AWS cn-north-1），车机持续与它保持 TLS 流量。

## 4. 对拦截方案的结论

1. 原方案（DNS 劫持 `mothership.vn.teslamotors.com` → `192.168.199.148`，明文 `:4567`）**架构成立但触发条件苛刻**：
   该域名公网 NXDOMAIN，车机只可能在"需要重拉配置"时才发这个查询，而 `feature_configuration` 有 12h±2h 缓存。
2. **加速手段只有车辆侧动作**：重启车机 / 休眠后唤醒（唤醒会重跑配置拉取）。
3. **备选**：若要直接从 `api-prd.vn.cloud.tesla.cn`（443，TLS1.3）侧看请求，需要 mitmproxy 在 443 起反向监听
   + 用项目自带 emSign 中间 CA 给车机签 `api-prd` 的证书；该域要求客户端证书，上游会 400，
   所以只能"短路应答"，不能全量代理 —— 且车机 API 会在拦截期间报错。
   **代价明显，非必要不做。**

## 5. 当前就绪状态

- ARP 引流：车机全部流量经本机，`error=0`，每秒重新投毒
- DNS：`mothership.*` → `192.168.199.148`，A/AAAA 都验过格式
- 4567：明文 200/282B + TLS1.3 握手均通过
- 触发后 1 秒内可观测：`car -> us SYN dport=4567` 日志 + `hits.jsonl` 真命中