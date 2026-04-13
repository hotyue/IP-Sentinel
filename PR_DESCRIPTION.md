# ✨ feat(trends24): add automated Twitter trends scraper with GitHub Actions

## 功能概述

添加自动化 Twitter 趋势抓取功能，每天从 trends24.in 获取全球各国热门话题，并自动更新到 IP-Sentinel 的关键词系统中。

## 主要特性

- 🤖 **GitHub Actions 自动化**: 每天北京时间 16:00 (UTC 08:00) 自动运行
- 🌍 **多国家支持**: 支持美国、日本、英国、德国、法国、新加坡、香港等7个国家/地区
- 📝 **智能关键词更新**: 
  - 自动获取各国前5个热门 Twitter 话题
  - 智能替换关键词文件末尾的5个旧关键词
  - 新添加的关键词追加到文件末尾
- 🔧 **动态配置**: 从 `trender.txt` 读取国家/地区 URL 映射，支持灵活扩展
- 🌐 **兼容性处理**: 对于不支持的国家/地区（如香港），自动使用全球趋势数据

## 文件变更

```
.github/workflows/trends24_scraper.yml    # GitHub Actions 工作流
scripts/trends24/
├── scraper.py                            # 主抓取脚本
├── country_mapping.py                    # 国家代码映射配置
├── trender.txt                           # trends24.in URL 映射表
├── requirements.txt                      # Python 依赖
└── README.md                             # 使用说明
data/keywords/kw_*.txt                    # 更新的关键词文件
```

## 技术细节

- 使用 `requests` 从 trends24.in 抓取 meta description 中的热门话题
- 支持从 `map.json` 动态读取国家/地区配置
- 关键词更新逻辑：
  - 文件不存在或关键词少于5个 → 直接添加5个新关键词
  - 文件存在且关键词充足 → 移除末尾5个旧关键词，添加5个新关键词
- 避免 Windows 终端编码问题，使用 UTF-8 写入文件

## 使用说明

1. **自动运行**: 每天自动更新，无需手动干预
2. **手动运行**:
   ```bash
   cd scripts/trends24
   pip install -r requirements.txt
   python scraper.py
   ```
3. **手动添加关键词**: 如需手动添加关键词，请添加到文件**第一行**（不会被自动移除）

## 扩展支持

如需添加新国家/地区：
1. 在 `data/map.json` 中添加国家/地区配置
2. 在 `scripts/trends24/trender.txt` 中添加对应的 trends24.in URL
3. 在 `data/keywords/` 创建对应的 `kw_XX.txt` 文件（可选，脚本会自动创建）

## 测试

- ✅ 已在本地测试所有7个国家/地区的数据获取
- ✅ 关键词文件更新逻辑验证通过
- ✅ GitHub Actions 工作流语法验证通过

---

**Author**: @Seameee
**Related Commit**: a0a9e335871f280ca9648e8cd7a413790f0635da
