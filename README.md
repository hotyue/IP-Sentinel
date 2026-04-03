# 🛡️ IP-Sentinel (分布式 IP 哨兵集群)

> **一个极度轻量、零感知、支持中枢遥控的 VPS IP 自动化养护与区域纠偏引擎。**

📢 官方战术交流频道: 🛰️ [IP-Sentinel Matrix](https://t.me/IP_Sentinel_Matrix)

专为解决 VPS IPv4 被 Google 等数据库错误定位到中国大陆/香港（俗称“送中”）等问题而生。IP-Sentinel 已从单机脚本全面跃升为 **Master-Agent 分布式架构**。它像影子一样潜伏在全球各地的服务器后台，通过高度拟真的真实用户行为为你默默积累 IP 权重，并允许你通过 Telegram 随时随地对整个舰队进行毫秒级“点名”与“遥控”。

## ✨ 核心极客特性

* 🧠 **分布式中枢 (Master-Agent)**：彻底解决多台 VPS 的管理痛点。一台 Master 主控集成 SQLite 数据库与 Telegram 机器人，统管无数台 Agent 边缘节点，告别 API 消息冲突。
* 🎮 **TG 战术面板 (Command Center)**：无需记忆繁琐命令，原生 Inline Keyboard 按钮驱动。支持一键调出节点列表、一键下发伪装指令、一键索要精准战报、**毫秒级抓取实时运行日志**。
* 🛡️ **NAT 穿透与安全网关 (NAT-Friendly)**：边缘节点采用 Python3 极轻量 Webhook 监听，**完全自定义通信端口**，完美支持受限 NAT 小鸡。独创 TG 转发授权机制，杜绝野生节点恶意接入。
* 👻 **高仿真人类行为 (Human-Like)**：摒弃死板的 Ping/Curl，引入单次会话指纹锁定、10 米级 GPS 坐标微抖动、以及 60~150 秒的真实阅读停顿拉伸，完美避开 AI 封控。
* 📡 **OTA 静默进化 (Smart Updates)**：系统每周日凌晨自动从云端拉取最新的“热搜词汇”和“真实设备指纹池”，确保养护行为与时俱进、永不过时。

## 📂 项目架构 (Monorepo)

本项目采用企业级的“主从控制”与“冷热数据分离”双重架构：

```text
📦 IP-Sentinel
 ┣ 📂 master/                 # 🧠 司令部：SQLite 存储、TG 监听与 Webhook 调度中心
 ┣ 📂 core/                   # 🛡️ 边缘哨兵：Webhook 被动监听、高拟真养护引擎
 ┗ 📂 data/                   # 🗂️ 全球数据规则库
    ┣ 📂 regions/             # 🧊 冷数据：各地区 GPS 基准配置 (固化)
    ┣ 📂 keywords/            # 🔥 热数据：动态搜索词库 (OTA 自动更新)
    ┗ 📜 user_agents.txt      # 🔥 热数据：全局真实设备指纹池
```

🚀 极速部署 (Quick Start)
请准备一个 Telegram Bot Token 和你的个人 Chat ID。整个集群的部署分为两步：

第一步：部署中枢司令部 (Master)
找一台网络稳定的 VPS 作为大脑（仅需部署一台），以 root 身份执行：

```Bash
bash <(curl -sL https://git.94211762.xyz/hotyue/IP-Sentinel/raw/branch/main/master/install_master.sh)
```
完成后，你的机器人将开始全局接客，等待边缘节点注册。

第二步：部署边缘哨兵 (Agent)
在你需要养护 IP 的无数台目标机器（包括 NAT 机器）上执行：

```Bash
bash <(curl -sL https://git.94211762.xyz/hotyue/IP-Sentinel/raw/branch/main/core/install.sh)
```
安装时输入与 Master 相同的 Bot Token 及自定义 Webhook 端口。安装完毕后，请在手机 TG 端将生成的 #REGISTER# 暗号转发给机器人，完成安全授权入库！

🗑️ 一键无痕卸载
如果你需要清理某个边缘节点，只需重新运行 core/install.sh 并选择 [3]，或直接在节点终端执行：

```Bash
bash /opt/ip_sentinel/core/uninstall.sh
```

📡 战术联络 (Community)
如果你在使用过程中遇到任何疑难杂症，或者想围观大佬们的养护战报，欢迎加入我们的基地：
- Telegram 频道: [@IP_Sentinel_Matrix](https://t.me/IP_Sentinel_Matrix)

🤝 参与贡献
如果你想为项目增加新的节点区域（例如德国、英国、新加坡等），或者提供更丰富的本土化搜索词库，非常欢迎提交 Pull Request！
只需在 data/regions/ 新增对应国家的 JSON 规则，并在 data/keywords/ 新增词库 txt 即可。

⚠️ 免责声明
本项目仅供网络原理研究、个人 VPS 维护学习使用。请遵守当地法律法规及目标服务商的 TOS（服务条款），切勿用于恶意高频请求或任何非法用途。使用者需自行承担因不当使用造成的 IP 封禁或其他相关风险。

