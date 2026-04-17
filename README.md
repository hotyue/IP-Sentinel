# 🛡️ IP-Sentinel (分布式 IP 哨兵集群)

![Agent Installs](https://img.shields.io/endpoint?url=https://ip-sentinel-count.samanthaestime296.workers.dev/stats/agent)
![Master Commands](https://img.shields.io/endpoint?url=https://ip-sentinel-count.samanthaestime296.workers.dev/stats/master)
![License](https://img.shields.io/github/license/hotyue/IP-Sentinel)

> **一个极度轻量、零感知、支持中枢遥控的 VPS IP 自动化养护与区域纠偏引擎。**

📢 官方战术交流频道: 🛰️ [IP-Sentinel Matrix](https://t.me/IP_Sentinel_Matrix)

专为解决 VPS IP 被 Google 等数据库错误定位到中国大陆/香港（俗称“送中”）等问题而生。IP-Sentinel 已从单机脚本全面跃升为 **Master-Agent 分布式架构**。它像影子一样潜伏在全球各地的服务器后台，通过高度拟真的真实用户行为为你默默积累 IP 权重，并允许你通过 Telegram 随时随地对整个舰队进行毫秒级“点名”与“遥控”。

## ✨ 核心极客特性 (Core Architecture)

- 🎛️ **L5 降维中枢与动态状态机 (Microservices Console)**：引入四级战区降维解析与双轨身份制。全 Inline Keyboard 原位重绘交互，支持在 TG 面板一键下发毫秒级模块热启停 (Toggle)、丝滑改名与日志抓取，底层数据库实时刷新，彻底告别刷屏烦恼。
- 🔄 **SSOT 溯源与热更新装甲 (Smooth Upgrade Engine)**：全系脚本彻底消灭硬编码，部署时动态抓取云端版本信标。搭载状态机嗅探逻辑与 OTA 预警探针，一键回车瞬间完成配置继承、数据同步与无损换代。
- 🗺️ **全球拓扑矩阵与活体词库 (Global Nexus)**：守护版图横跨亚欧美三大洲。接入 GitHub Actions 云端流水线，每日静默同步全球各大区当日 Google 真实热搜榜单与高权重本土站点，让伪装行为永远贴合当地网络脉搏。
- 👻 **资产持久化与错峰调度 (Hash-Seeded Persona)**：摒弃随机抽取指纹，基于节点物理 IP 哈希永久锁定 3 个绝对专属设备，完美构建高权重真实家庭内网画像。叠加按需智能分频与随机防并发休眠，化解“惊群效应”。
- 🖧 **底层路由死锁与高精度探针 (Hard-Bind Routing)**：底层探测引擎强力接管 curl 核心参数 (`--interface`)，将发出的每一滴伪装流量死死绑定在物理网卡或隧道 IP 上。配合多级 ISP 容灾链路，彻底杜绝双栈环境下的流量溢出与 API 误判。

**—— 💎 骨干基建特征 ——**
- 🏭 **自动化指纹兵工厂**：依托 GitHub Actions CI/CD 流水线，每月 1 日无人值守锻造 4000+ 带绝对物理分区的真实终端设备数据。
- 🔒 **叹息之墙 (Zero-Trust HMAC)**：底层通讯引入 时间戳 + HMAC-SHA256 军用级动态签名。指令有效期仅 60 秒（阅后即焚），未授权请求直接触发系统级 403 物理熔断，彻底免疫中间人抓包与重放攻击。
- ☁️ **云端中枢 (Public Master)**：官方公共机器人 [@OmniBeacon_bot](https://t.me/OmniBeacon_bot) ，新手免自建，一键接入极速入伍！同时支持硬核极客私有化 SQLite 分布式部署。
- 👁️‍🗨️ **玻璃房透明遥测 (Glasshouse)**：基于 Cloudflare Workers 的全透明计数中枢，绝对零隐私收集，仅作原子累加，底层网关源码全开源。

## 📂 项目架构 (Monorepo)

本项目采用企业级的“主从控制”与“冷热数据分离”双重架构：

```text
📦 IP-Sentinel
 ┣ 📂 .github/workflows/      # 🏭 自动化兵工厂：每月定时触发指纹生成的 CI/CD 流水线
 ┣ 📂 master/                 # 🧠 司令部：SQLite 存储、TG 监听与 Webhook 调度中心
 ┣ 📂 core/                   # 🛡️ 边缘哨兵：Webhook 被动监听、哈希锚定执行引擎
 ┣ 📂 scripts/                # 🐍 兵工厂引擎：基于 Python 的多物理分区 UA 生成器
 ┣ 📂 data/                   # 🗂️ 全球数据规则库 (动态拓扑)
 ┃  ┣ 📜 map.json             # 🌍 全球区域大脑 (v3.5.0 大洲战区拓扑)
 ┃  ┣ 📂 regions/             # 🧊 冷数据：按 [国家/省州/城市] 深度细分的 LBS 锚点
 ┃  ┣ 📂 keywords/            # 🔥 热数据：按国家归类的动态搜索词库 (OTA 自动更新)
 ┃  ┗ 📜 user_agents.txt      # 🔥 热数据：由兵工厂每月锻造的绝对坐标专属设备库
 ┣ 📜 version.txt             # 🚩 双端版本信标：Agent/Master 独立解耦的 KV 环境配置 (v3.5.1)
 ┗ 📂 telemetry/              # 👁️‍🗨️ 玻璃房计划：Cloudflare Workers 透明计数器网关源码
```

## 🚀 极速部署 (Quick Start)
系统现提供两种接入模式，请根据您的战术需求选择：

### 🔹 模式 A：私有独立模式 (全自主、强烈推荐)
适合追求绝对数据隐私与舰队最高控制权的领主。

    💡 前瞻战略提示：强烈推荐采用私有部署！系统下一步即将支持基于私有中枢的 OTA 远程在线升级，届时全网边缘节点可实现一键静默换代！

- 部署 Master (中枢大脑)：找一台 VPS 作为司令部（仅需部署一台），执行：

```Bash
bash <(curl -sL https://raw.githubusercontent.com/hotyue/IP-Sentinel/main/master/install_master.sh)
```
- 部署 Agent (边缘哨兵)：在需要养护的机器上执行 Agent 脚本，安装时选择私有独立中枢，并分别输入您自建机器人的 Token 以及您的个人 Chat ID：

```Bash
bash <(curl -sL https://raw.githubusercontent.com/hotyue/IP-Sentinel/main/core/install.sh)
```
- 激活节点：安装完成后，您的手机会收到一条 #REGISTER# 注册暗号，将其转发给您自己的机器人即可完成编队入库。

### 🔸 模式 B：官方公共模式 (最简体验)
适合不想折腾、只想快速体验养护效果的新兵。

- 关注机器人：在 TG 中关注官方安全网关 [@OmniBeacon_bot](https://t.me/OmniBeacon_bot) 并发送 /start。

- 部署 Agent：在目标 VPS 上执行以下指令，安装过程中选择官方公共网关，并输入您的 Chat ID：

```Bash
bash <(curl -sL https://raw.githubusercontent.com/hotyue/IP-Sentinel/main/core/install.sh)
```
- 激活节点：同上，将收到的暗号转发给官方机器人即可。

### ⚠️ 架构级热升级指引 (Upgrade to v3.5.0)

得益于 **v3.5.0 全新引入的 SSOT 版本锚点与状态机路由**，系统升级现已变得极其智能化。

**如果您是从远古旧版 (v3.3.1 / v3.3.2) 升级：**
1. 在终端再次运行对应的官方部署指令。
2. 脚本会识别到您处于“前版本锚点时代”，会自动为您执行【跨代架构重组】。
3. **关键动作**：由于节点命名防撞机制变更，升级后您的 TG 会收到一条新的 `#REGISTER#` 指令，请点击并发送一次以同步新身份。
4. **清理**：在面板中手动剔除失联的旧节点即可。

**如果您已处于 v3.4.0+：**
所有的升级已进入**“极致静默平滑模式”**。安装引擎会动态抓取云端 `version.txt`，自动修正本地 `config.conf` 的版本号，一键回车，3 秒即可完成全系组件的热重载换代！

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