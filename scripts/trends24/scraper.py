#!/usr/bin/env python3
"""
Twitter Trends24 Scraper - GitHub Actions 版本
自动爬取多个国家的热门话题并更新关键词文件
"""

import re
import os
import sys
from datetime import datetime
from typing import List, Dict, Optional
import requests
from country_mapping import (
    COUNTRY_MAPPING,
    KEYWORD_FILE_MAPPING,
    KEYWORDS_PER_COUNTRY,
    REPLACE_COUNT,
    KEYWORDS_BASE_PATH,
    USE_WORLDWIDE
)


def fetch_trends_from_meta(country_url: str) -> List[str]:
    """
    从指定国家的 meta description 中提取热门话题
    
    Args:
        country_url: trends24.in 的国家路径，如 "japan", "united-states"
    
    Returns:
        热门话题列表（前 KEYWORDS_PER_COUNTRY 个）
    """
    base_url = "https://trends24.in"
    url = f"{base_url}/{country_url}/"
    
    headers = {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
    }
    
    try:
        print(f"[INFO] 正在获取: {url}")
        response = requests.get(url, headers=headers, timeout=30)
        response.raise_for_status()
        response.encoding = 'utf-8'
        html = response.text
        
        # 提取 meta description
        # 网站使用 <meta name=description content="..."> (无引号)
        pattern = r'<meta\s+name=description\s+content="([^"]+)"'
        match = re.search(pattern, html, re.IGNORECASE)
        
        if not match:
            # 尝试另一种属性顺序
            pattern = r'<meta\s+content="([^"]+)"\s+name=description'
            match = re.search(pattern, html, re.IGNORECASE)
        
        if match:
            description = match.group(1)
            
            # 提取关键词部分
            # 格式: "Today's top X (Twitter) trends and hashtags in Country: keyword1, keyword2..."
            if ':' in description:
                keywords_part = description.split(':')[-1].strip()
                # 移除末尾的 ". Explore more..." 或其他说明文字
                keywords_part = keywords_part.split('.')[0]
                # 按逗号分割并清理
                keywords = [kw.strip() for kw in keywords_part.split(',') if kw.strip()]
                # 只返回前 KEYWORDS_PER_COUNTRY 个
                return keywords[:KEYWORDS_PER_COUNTRY]
        
        print(f"[WARN] 未找到 meta description: {url}")
        return []
        
    except Exception as e:
        print(f"[ERROR] 获取 {url} 时出错: {e}")
        return []


def update_keyword_file(file_path: str, new_keywords: List[str]) -> bool:
    """
    更新关键词文件
    - 如果文件不存在或少于 REPLACE_COUNT 个关键词，直接添加新关键词
    - 否则移除末尾的 REPLACE_COUNT 个旧关键词，再添加新的 REPLACE_COUNT 个
    
    Args:
        file_path: 关键词文件的完整路径
        new_keywords: 新的关键词列表
    
    Returns:
        是否成功更新
    """
    try:
        # 读取现有内容
        existing_keywords = []
        if os.path.exists(file_path):
            with open(file_path, 'r', encoding='utf-8') as f:
                existing_keywords = [line.strip() for line in f if line.strip()]
        
        # 如果文件不存在或关键词数量不足 REPLACE_COUNT，直接添加新关键词
        if len(existing_keywords) < REPLACE_COUNT:
            print(f"[INFO] 文件不存在或关键词数量不足 {REPLACE_COUNT} 个，直接添加 {len(new_keywords[:REPLACE_COUNT])} 个新关键词")
            updated_keywords = existing_keywords + new_keywords[:REPLACE_COUNT]
        else:
            # 移除末尾的 REPLACE_COUNT 个旧关键词
            remaining_keywords = existing_keywords[:-REPLACE_COUNT]
            # 添加新的关键词到末尾
            updated_keywords = remaining_keywords + new_keywords[:REPLACE_COUNT]
            print(f"[INFO] 已更新 {file_path}: 移除了末尾 {REPLACE_COUNT} 个旧关键词，添加了 {len(new_keywords[:REPLACE_COUNT])} 个新关键词")
        
        # 确保目录存在
        os.makedirs(os.path.dirname(file_path), exist_ok=True)
        
        # 写回文件
        with open(file_path, 'w', encoding='utf-8') as f:
            for kw in updated_keywords:
                f.write(f"{kw}\n")
        
        return True
        
    except Exception as e:
        print(f"[ERROR] 更新文件 {file_path} 时出错: {e}")
        return False


def process_country(country_code: str) -> bool:
    """
    处理单个国家/地区的热门话题获取和更新
    
    Args:
        country_code: 国家/地区代码，如 "US", "JP", "HK"
    
    Returns:
        是否成功处理
    """
    print(f"\n{'='*60}")
    print(f"[INFO] 正在处理国家/地区: {country_code}")
    print(f"{'='*60}")
    
    # 获取 URL 路径
    country_url = COUNTRY_MAPPING.get(country_code)
    
    # 检查是否使用 worldwide
    if country_url is None:
        if country_code in USE_WORLDWIDE:
            print(f"[INFO] {country_code} 不支持单独查询，使用 worldwide (全球) 数据")
            country_url = ""  # worldwide 使用空路径
        else:
            print(f"[ERROR] 未知的国家/地区代码: {country_code}")
            return False
    
    # 获取热门话题
    keywords = fetch_trends_from_meta(country_url)
    
    if not keywords:
        print(f"[WARN] 未获取到 {country_code} 的热门话题")
        return False
    
    print(f"[INFO] 获取到 {len(keywords)} 个热门话题:")
    for i, kw in enumerate(keywords, 1):
        print(f"  {i}. {kw}")
    
    # 获取关键词文件路径
    keyword_filename = KEYWORD_FILE_MAPPING.get(country_code)
    if not keyword_filename:
        print(f"[ERROR] 未找到 {country_code} 对应的关键词文件名")
        return False
    
    # 构建完整路径
    # 从 scripts/trends24/ 到 data/keywords/
    script_dir = os.path.dirname(os.path.abspath(__file__))
    file_path = os.path.join(script_dir, KEYWORDS_BASE_PATH, keyword_filename)
    
    # 确保目录存在
    os.makedirs(os.path.dirname(file_path), exist_ok=True)
    
    # 更新关键词文件
    success = update_keyword_file(file_path, keywords)
    
    return success


def main():
    """主函数"""
    print(f"\n{'='*60}")
    print(f"[INFO] Trends24 Scraper - {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"{'='*60}\n")
    
    # 处理所有配置的国家
    success_count = 0
    fail_count = 0
    
    for country_code in COUNTRY_MAPPING.keys():
        if process_country(country_code):
            success_count += 1
        else:
            fail_count += 1
    
    # 输出总结
    print(f"\n{'='*60}")
    print(f"[INFO] 处理完成: 成功 {success_count}, 失败 {fail_count}")
    print(f"{'='*60}\n")
    
    # 如果有失败，返回非零退出码
    if fail_count > 0:
        sys.exit(1)
    
    sys.exit(0)


if __name__ == "__main__":
    main()
