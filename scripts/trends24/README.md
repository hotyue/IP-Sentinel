# Trends24 Scraper

自动从 [trends24.in](https://trends24.in/) 获取各国 Twitter 热门话题并更新关键词文件。

## 功能

- 每天自动获取7个国家的热门话题
- 支持的国家：美国、日本、英国、德国、法国、新加坡、香港
- 智能更新：移除旧关键词，添加新趋势话题
- 与 IP-Sentinel 关键词系统集成

## 本地运行

```bash
cd scripts/trends24
pip install -r requirements.txt
python scraper.py
```

## 文件说明

- `scraper.py` - 主脚本
- `country_mapping.py` - 国家代码映射配置
- `requirements.txt` - Python 依赖
- `../../data/keywords/kw_*.txt` - 更新的关键词文件

## 关键词更新机制

- **自动添加位置**：新获取的关键词添加到文件**末尾**
- **自动移除位置**：文件末尾的 5 个旧关键词会被移除
- **手动添加位置**：如需手动添加关键词，请添加到文件**第一行**（开头），这样不会被自动移除

## GitHub Actions 自动化

每天早上 8:00 UTC 自动运行，更新所有国家的关键词。
