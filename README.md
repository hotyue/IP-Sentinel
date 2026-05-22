# 🛡️ IP-Sentinel

![Agent Installs](https://img.shields.io/endpoint?url=https://ip-sentinel-count.samanthaestime296.workers.dev/stats/agent)
![Master Commands](https://img.shields.io/endpoint?url=https://ip-sentinel-count.samanthaestime296.workers.dev/stats/master)
![License](https://img.shields.io/github/license/hotyue/IP-Sentinel)

> **一个支持 GeoAnchor 状态机、Telegram 中枢联控、灰度回滚的 VPS IP 自动化养护引擎。**

📢 官方战术交流频道: 🛰️ [IP-Sentinel Matrix](https://t.me/IP_Sentinel_Matrix)

IP-Sentinel 用于缓解 VPS 出口被 Google / YouTube 等服务错误识别为中国大陆、香港或其他非目标地区的问题。当前实现已从早期单机巡逻脚本演进为一套 **Master-Agent 分布式架构 + GeoAnchor 闭环调度**：

`preflight -> probe -> state machine -> browser anchor / local trust / cooldown -> rollout / rollback`

---

## ✨ 当前实现包含什么

- **Preflight 预检**：在执行养护前检查公网出口、IPv4/IPv6、一致性、DNS 解析、时区、NTP、代理污染、profile 可写性。
- **GeoScore 探针**：综合 Google Jump、YouTube Premium、YouTube Music、DNS、活跃 IP 栈、public IP match、host resolution 生成分数。
- **状态机调度**：支持 `UNKNOWN`、`CN_LOCKED`、`HK_DRIFT`、`OTHER_DRIFT`、`PARTIAL`、`TARGET`、`STABLE`、`BOT_RISK`、`DNS_RISK`、`DISABLED`。
- **真实浏览器锚定**：通过 Playwright + Chromium 的持久化 profile 执行低频浏览器锚定，不伪造账号登录，不绕验证码。
- **Local Trust 重构**：优先访问低风险公共站点；没有专用 trust profile 时，会自动回退到区域规则中的 trust URL。
- **Runner v2 闭环**：由 `core/runner_v2.sh` 串联 preflight、probe、state、anchor、trust、cooldown，并支持 conservative rollout 模式。
- **Telegram 控制面**：Master / Agent 已接入 `/status`、`/score`、`/preflight`、`/probe`、`/anchor`、`/trust`、`/cooldown`、`/resume`，且手动动作也受状态机限制。
- **灰度与回滚**：支持 3 天灰度观测、BOT_RISK 自动冷却、连续无改善自动降为 conservative；支持回滚到旧 `runner.sh` 并保留 state / profiles / logs。

---

## 📂 项目结构

```text
IP-Sentinel
├─ master/                    # Telegram Master、SQLite、节点面板与指令分发
├─ core/
│  ├─ runner.sh              # 旧调度器，保留作兼容/回滚目标
│  ├─ runner_v2.sh           # GeoAnchor 闭环调度器
│  ├─ preflight.sh           # 预检
│  ├─ mod_probe.sh           # GeoScore 探针
│  ├─ mod_state.py           # 状态机 / quota / cooldown
│  ├─ mod_anchor_browser.py  # 浏览器锚定
│  ├─ mod_local_trust.py     # Local Trust
│  ├─ geoanchor_control.py   # Telegram / Agent GeoAnchor 控制入口
│  ├─ geoanchor_rollout.py   # 灰度快照记录器
│  └─ geoanchor_rollback.sh  # 回滚脚本
├─ data/
│  ├─ regions/               # 按 [国家/州/城市] 的区域冷数据
│  ├─ trust_profiles/        # 精修 trust profile（当前仅少量）
│  ├─ keywords/              # 国家级关键词热数据
│  └─ user_agents.txt        # 浏览器 UA 热数据
├─ baseline/                 # 阶段基线与进度记录
└─ version.txt               # Agent / Master 版本信标
```

---

## 🚀 快速部署

> 支持 Debian / Ubuntu / CentOS / RHEL / Alpine / Arch Linux

### 1. 部署 Master

```bash
curl -fsSL https://raw.githubusercontent.com/hotyue/IP-Sentinel/main/master/install_master.sh -o /tmp/ins_master.sh && sudo bash /tmp/ins_master.sh
```

### 2. 部署 Agent

```bash
curl -fsSL https://raw.githubusercontent.com/hotyue/IP-Sentinel/main/core/install.sh -o /tmp/ins_agent.sh && sudo bash /tmp/ins_agent.sh
```

安装 Agent 时会选择目标地区，并写入：

- `TARGET_COUNTRY`
- `TARGET_STATE`
- `TARGET_CITY`
- `TRUST_PROFILE_FILE`
- `GEOANCHOR_VENV`
- `PLAYWRIGHT_BROWSERS_PATH`
- `GEOANCHOR_ROLLOUT_MODE`

安装完成后，节点仍通过 `#REGISTER#` 向 Master 入库。

---

## 🧠 GeoAnchor 调度逻辑

### 运行链路

1. `core/preflight.sh`
2. `core/mod_probe.sh`
3. `core/mod_state.py update-from-probe`
4. `core/mod_state.py next-action`
5. 按状态执行：
   - `anchor_browser`
   - `local_trust`
   - `probe_only`
   - `cooldown`
6. 执行后再次 probe，并回写状态

### 关键行为

- `BOT_RISK`：停止高风险动作，进入冷却
- `DNS_RISK`：停止 anchor，仅保留低频 probe
- `TARGET` / `STABLE`：自动降频
- `CN_LOCKED` / `HK_DRIFT` / `OTHER_DRIFT`：进入恢复期策略
- `GEOANCHOR_ROLLOUT_MODE=conservative`：`runner_v2` 会把 `anchor_browser` / `local_trust` 降为 `probe_only`

---

## 🤖 Telegram 控制面

当前 GeoAnchor 手动控制命令：

```text
/status <node>      查看当前状态、最近探针、下一动作
/score <node>       查看最近 7 天 GeoScore 趋势
/preflight <node>   执行一次 preflight
/probe <node>       执行一次轻量 probe
/anchor <node>      执行一次 browser anchor（受状态机限制）
/trust <node>       执行一次 local trust（受状态机限制）
/cooldown <node>    手动进入冷却
/resume <node>      手动解除冷却
```

### 重要限制

- 手动 `/anchor` **不会绕过状态机**
- `BOT_RISK` 下 `/anchor` 会被拒绝
- `DNS_RISK` 下 `/anchor` 会被拒绝
- 配额耗尽时手动动作会被拒绝
- 所有手动动作都会写入日志

---

## 🌍 地区支持说明

### 当前支持原则

系统并不是“自动支持全球任意 VPS 所属地”，而是：

1. **仓库里存在 `data/regions/...` 区域 JSON 的地区，可以直接作为目标地区使用**
2. **存在专用 `data/trust_profiles/...` 的地区，Local Trust 会更精细**
3. **没有专用 trust profile 的地区，Local Trust 会回退到 region JSON 中的 trust URL**

### 当前明确已支持的典型地区

- **美国**：多州多城市
- **新加坡**
- **日本**：东京、大阪
- **香港**
- 以及仓库中已存在 region JSON 的其他地区

### 当前限制

- **精修 trust profile 目前只有 `US-CA-Los_Angeles`**
- 其他地区虽然可以运行，但 Local Trust 主要依赖 fallback 规则，不代表已经做了同等精细化本地画像
- 如果某地区在 `data/regions/` 中没有对应 JSON，就不能直接选为目标地区

### 新增地区的方法

1. 在 `data/regions/国家代码/州代码或Default/城市.json` 增加区域文件
2. 在 `data/keywords/` 增加对应国家词库
3. 在 `data/map.json` 登记国家 / 州 / 城市
4. 如需更精细 Local Trust，再增加 `data/trust_profiles/国家-州-城市.json`

---

## 🆙 升级

### 通过安装脚本平滑升级

```bash
curl -fsSL https://raw.githubusercontent.com/hotyue/IP-Sentinel/main/core/install.sh -o /tmp/ins_agent.sh && sudo bash /tmp/ins_agent.sh
```

升级时会尽量继承既有配置、state、profile 和定时任务。

### 通过 Telegram OTA 升级

- 升级 Master：`/start` 顶部升级入口
- 升级全舰队 Agent：全舰队 OTA
- 升级单节点 Agent：节点控制台中的 OTA 按钮

---

## 🧪 灰度测试与回滚

### 灰度建议

建议选择 1 台问题 VPS 连续观察 3 天，每日记录：

- GeoScore
- Google Jump
- YouTube Premium
- YouTube Music
- DNS 出口
- IPv4 / IPv6 状态
- BOT_RISK 次数

当前实现里，`core/geoanchor_rollout.py snapshot` 会记录这些灰度快照，并在：

- 出现 `BOT_RISK` 时自动施加冷却
- 连续 3 天无改善时自动把 `GEOANCHOR_ROLLOUT_MODE` 切到 `conservative`

### 回滚

回滚脚本：

```bash
bash /opt/ip_sentinel/core/geoanchor_rollback.sh
```

回滚会做以下事情：

- 备份 `state/`
- 备份 `profiles/`
- **不删除 logs**
- 将 systemd / cron / scheduler 中的 `runner_v2.sh` 恢复为 `runner.sh`
- 将 `GEOANCHOR_ROLLOUT_MODE` 恢复为 `normal`

---

## 🗑️ 卸载

```bash
bash /opt/ip_sentinel/core/uninstall.sh
```

---

## 🤝 贡献

欢迎补充：

- 新国家 / 新州 / 新城市的 `data/regions`
- 更本地化的 `data/keywords`
- 更精细的 `data/trust_profiles`
- Master / Agent 控制面与状态机策略

特别是当前 `trust_profiles` 覆盖还远不完整，欢迎按城市继续补齐。

---

## ⚠️ 免责声明

本项目仅供网络原理研究、个人 VPS 维护学习使用。请遵守当地法律法规及目标服务商 TOS，勿用于恶意高频请求、绕过风控或任何非法用途。使用者需自行承担由不当使用引发的封禁或其他风险。

---

## 保持联系

[![Blog](https://img.shields.io/badge/Blog-个人博客-blue)](https://blog.iot-architect.com)

如果这个项目对你有帮助，欢迎关注博客或前往 GitHub 点亮 Star。

## Stargazers over time

[![Stargazers over time](https://starchart.cc/hotyue/IP-Sentinel.svg?variant=adaptive)](https://starchart.cc/hotyue/IP-Sentinel)
