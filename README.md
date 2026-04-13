# 🛡️ IP-Sentinel (分布式 IP 哨兵集群)

![Agent Installs](https://img.shields.io/endpoint?url=https://ip-sentinel-count.samanthaestime296.workers.dev/stats/agent)
![Master Commands](https://img.shields.io/endpoint?url=https://ip-sentinel-count.samanthaestime296.workers.dev/stats/master)
![License](https://img.shields.io/github/license/hotyue/IP-Sentinel)

> **一个极度轻量、零感知、支持中枢遥控的 VPS IP 自动化养护与区域纠偏引擎。**

📢 官方战术交流频道: 🛰️ [IP-Sentinel Matrix](https://t.me/IP_Sentinel_Matrix)

专为解决 VPS IP 被 Google 等数据库错误定位到中国大陆/香港（俗称“送中”）等问题而生。IP-Sentinel 已从单机脚本全面跃升为 **Master-Agent 分布式架构**。它像影子一样潜伏在全球各地的服务器后台，通过高度拟真的真实用户行为为你默默积累 IP 权重，并允许你通过 Telegram 随时随地对整个舰队进行毫秒级“点名”与“遥控”。

## ✨ 核心极客特性

 - 🗺️ **全球拓扑矩阵 (Global Nexus)**：v3.1 跨洲际跃升。守护版图现已横跨亚、欧、美三大洲（美、日、英、德、法、新、港）。为每个国家注入极其硬核的“原生本地化”搜索词库与本土高权重站点（如政府、权威媒体、高铁网），真正实现“拟真融入”。

 - 👻 **设备资产持久化 (Hash-Seeded Persona)**：v3.2 核心换代。彻底摒弃传统的“随机抽取指纹”，引入基于节点物理 IP 的哈希锚定引擎。利用不可变哈希种子，为您的每台 VPS 在千万级指纹库中永久锁定 3 个绝对专属设备（如固定表现为 1台 Mac、1台 iPhone、1台 PC 交替上网）。完美构建高权重真实家庭内网画像，根除“僵尸网络”同质化特征！

 - 🏭 **自动化指纹兵工厂 (Automated UA Factory)**：依托 GitHub Actions CI/CD 流水线，每月 1 日无人值守全自动生成 4000+ 带绝对物理分区的真实终端设备数据。配合边缘节点的守护进程静默拉取，实现千万级指纹资产的“自动驾驶”级演进。

 - 🖧 **底层路由死锁 (Hard-Bind Routing)**：v3.2.1 热修复升级。底层探测引擎强力接管 curl 核心参数 (--interface)，强制将发出的每一滴伪装流量死死绑定在您设定的物理网卡或隧道 IP 上，彻底杜绝双栈或多网卡环境下的流量溢出漏洞。

- 🎯 **多级容灾与高精度探针 (High-Precision Probe)**：v3.2.2 底层重构。重写战报模块与底层协议自适应逻辑，植入多级 ISP 容灾探针链路，并按“底层数据共识原则”智能清洗冗余 AS 号。确保在纯 V6、隧道或弱网环境下，数据获取依然 100% 精准畅通。

 - 🔄 **平滑热更新装甲 (Smooth Upgrade Engine)**：v3.2.2 体验进化。全系植入状态机嗅探逻辑。无论是 Master 司令部还是 Agent 边缘节点，再次执行部署脚本时将自动识别并继承历史配置、SQLite 数据库与锚定 IP，一键回车即可瞬间完成无损换代，告别繁琐的重复配置。
 
 - ☁️ **云端中枢 (Public Master)**：引入官方公共机器人 @OmniBeacon_bot，新手无需部署 Master 司令部，部署 Agent 时一键回车即可调用官方加密网关，30 秒极速入伍！

 - 🧠 **分布式中枢 (Master-Agent)**：对于硬核极客，支持私有化部署。一台 Master 主控集成 SQLite 数据库，统管无数台 Agent 边缘节点，确保数据绝对私有。

 - 🔒 **叹息之墙 (Zero-Trust HMAC)**：全面废弃明文 Token，底层通讯引入 时间戳 + HMAC-SHA256 军用级动态签名。指令有效期仅 60 秒（阅后即焚），彻底免疫中间人抓包、重放攻击与端口爆破。

 - 🛡️ **工业级并发与自净引擎**：底层 Webhook 采用多线程模型彻底免疫慢速耗尽攻击；独创“智能清道夫”逻辑，覆盖安装/升级时自动绞杀僵尸进程与冗余定时任务，绝对纯净，告别玄学冲突。

 - 🎮 **TG 战术面板 (Command Center)**：无需记忆繁琐命令，全 Inline Keyboard 交互。支持一键下发伪装指令、一键索要精准战报、毫秒级抓取边缘节点实时运行日志。

 - 👁️‍🗨️ **玻璃房透明遥测 (Glasshouse Telemetry)**：引入基于 Cloudflare Workers 的全透明计数中枢，首页动态徽章实时展示全球真实装机与调用量。绝对零隐私收集，仅作原子累加，底层网关源码全开源，接受全网极客审计。

 - ⚡ **丝滑战术交互 (Seamless UI)**：司令部交互面板像素级打磨。新节点发送暗号入伍成功后，司令部将无缝零延迟自动呼出最新的活跃节点阵列面板，彻底免除重复输入命令的繁琐，掌控感拉满。

## 📂 项目架构 (Monorepo)

本项目采用企业级的“主从控制”与“冷热数据分离”双重架构：

```text
📦 IP-Sentinel
 ┣ 📂 .github/workflows/      # 🏭 自动化兵工厂：每月定时触发指纹生成的 CI/CD 流水线
 ┣ 📂 master/                 # 🧠 司令部：SQLite 存储、TG 监听与 Webhook 调度中心
 ┣ 📂 core/                   # 🛡️ 边缘哨兵：Webhook 被动监听、哈希锚定执行引擎
 ┣ 📂 scripts/                # 🐍 兵工厂引擎：基于 Python 的多物理分区 UA 生成器
 ┣ 📂 data/                   # 🗂️ 全球数据规则库 (动态拓扑)
 ┃  ┣ 📜 map.json             # 🌐 全球区域索引大脑 (Master Index)
 ┃  ┣ 📂 regions/             # 🧊 冷数据：按 [国家/省州/城市] 深度细分的 LBS 锚点
 ┃  ┣ 📂 keywords/            # 🔥 热数据：按国家归类的动态搜索词库 (OTA 自动更新)
 ┃  ┗ 📜 user_agents.txt      # 🔥 热数据：由兵工厂每月锻造的绝对坐标专属设备库
 ┗ 📂 telemetry/              # 👁️‍🗨️ 玻璃房计划：Cloudflare Workers 透明计数器网关源码
```

## 🚀 极速部署 (Quick Start)

v3.2.x 提供了两种接入模式，请根据您的战术需求选择：

### 🔹 模式 A：官方公共模式 (最简、推荐)
**适合不想折腾、只想快速养护 IP 的新兵。**

1. **关注机器人**：在 TG 中关注 [@OmniBeacon_bot](https://t.me/OmniBeacon_bot) 并发送 `/start`。
2. **部署 Agent**：在目标 VPS 上执行以下指令，安装过程中**直接回车**使用官方机器人，并输入您的 Chat ID：
```Bash
bash <(curl -sL https://raw.githubusercontent.com/hotyue/IP-Sentinel/main/core/install.sh)

```
3. **激活节点**：安装完成后，您的手机会收到一条 #REGISTER# 暗号，将其转发给机器人即可完成入库。

### 🔸 模式 B：私有独立模式 (全自主、硬核)
**适合追求绝对数据隐私、需自建机器人的领主。**

1. **部署 Master**：找一台 VPS 作为大脑（仅需部署一台），执行：
```Bash
bash <(curl -sL https://raw.githubusercontent.com/hotyue/IP-Sentinel/main/master/install_master.sh)

```
2. **部署 Agent**：在需要养护的机器上执行 Agent 脚本，输入您自建机器人的 Token 以及与 Master 一致的配置。
```Bash
bash <(curl -sL https://raw.githubusercontent.com/hotyue/IP-Sentinel/main/core/install.sh)

```
3. **激活节点**：同上，将暗号转发给您自己的机器人即可。

### ⚠️ 平滑升级指引 (Upgrade to v3.2.2)

得益于 **v3.2.2 全新引入的平滑热更新引擎 (Smooth Upgrade Engine)**，系统升级现已变得极其优雅与安全。

无需卸载旧版本，无论您是要升级 Agent 边缘节点还是 Master 控制中枢，只需在您的终端中**再次运行上方对应的官方部署指令**。

安装雷达会自动嗅探您的历史部署状态（包括您的 Token、区域设定、SQLite 数据库及物理网卡锚点）。当询问是否平滑升级时，您只需**一路回车 (默认选 y)**，脚本将在短短 3 秒内瞬间完成核心装甲的无损换脑手术，您的所有战术资产将得到 100% 保留！

🗑️ 一键无痕卸载
如果你需要清理某个边缘节点，只需重新运行 `core/install.sh` 并选择 **[2]**，或直接在节点终端执行：

```Bash
bash /opt/ip_sentinel/core/uninstall.sh

```

### 🧓 传家宝老旧系统专用通道 (Debian 9)

如果你的小鸡系统版本过低（如 Debian 9），由于官方 APT 源已关闭且 Python 版本过旧，无法使用主线版本，请使用 **Legacy 兼容分支** 部署。
*(注意：该分支仅作基础维护，不享受新功能迭代，请尽可能升级你的系统)*

```bash
bash <(curl -sL https://raw.githubusercontent.com/hotyue/IP-Sentinel/legacy/core/install.sh)
```

📡 战术联络 (Community)
如果你在使用过程中遇到任何疑难杂症，或者想围观大佬们的养护战报，欢迎加入我们的基地：
- Telegram 频道: [@IP_Sentinel_Matrix](https://t.me/IP_Sentinel_Matrix)

🤝 参与贡献
如果你想为项目增加新的节点区域（例如德国、英国、新加坡等），或者提供更丰富的本土化搜索词库，非常欢迎提交 Pull Request！

**v3.0 全球节点贡献规范：**
1. 在 `data/regions/国家代码/省州代码/` 目录下新增对应城市的配置 `.json`。
2. 在 `data/keywords/` 目录下新增或完善配套国家的词库 `kw_XX.txt`。
3. **最重要的一步：** 在 `data/map.json` 中登记你的国家、省州与城市信息。安装脚本将自动读取地图，在全球雷达中点亮你的节点！

⚠️ 免责声明
本项目仅供网络原理研究、个人 VPS 维护学习使用。请遵守当地法律法规及目标服务商的 TOS（服务条款），切勿用于恶意高频请求或任何非法用途。使用者需自行承担因不当使用造成的 IP 封禁或其他相关风险。

## Stargazers over time
[![Stargazers over time](https://starchart.cc/hotyue/IP-Sentinel.svg?variant=adaptive)](https://starchart.cc/hotyue/IP-Sentinel)