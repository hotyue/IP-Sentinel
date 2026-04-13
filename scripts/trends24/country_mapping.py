#!/usr/bin/env python3
"""
国家/地区代码到 trends24.in URL 的映射配置
支持从 trender.txt 动态读取映射关系
"""

import json
import os
import re
from typing import Dict, List, Optional, Tuple

# 默认提取的关键词数量
KEYWORDS_PER_COUNTRY = 5

# 每次更新要替换的关键词数量
REPLACE_COUNT = 5

# 关键词文件基础路径
KEYWORDS_BASE_PATH = "../../data/keywords"

# map.json 文件路径（相对于脚本位置）
MAP_JSON_PATH = "../../data/map.json"

# trender.txt 文件路径（相对于脚本位置）
TRENDER_TXT_PATH = "trender.txt"


def load_map_json() -> Dict:
    """
    从 map.json 加载国家/地区配置
    
    Returns:
        map.json 的内容字典
    """
    script_dir = os.path.dirname(os.path.abspath(__file__))
    map_path = os.path.join(script_dir, MAP_JSON_PATH)
    
    try:
        with open(map_path, 'r', encoding='utf-8') as f:
            return json.load(f)
    except Exception as e:
        print(f"[WARN] 无法加载 map.json: {e}")
        return {"countries": []}


def load_trender_mapping() -> Dict[str, str]:
    """
    从 trender.txt 加载国家/地区名称到 URL 的映射
    
    Returns:
        字典: {国家/地区名称: URL路径}
    """
    mapping = {}
    script_dir = os.path.dirname(os.path.abspath(__file__))
    trender_path = os.path.join(script_dir, TRENDER_TXT_PATH)
    
    try:
        with open(trender_path, 'r', encoding='utf-8') as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith('#'):
                    continue
                
                # 解析格式: | Country Name | https://trends24.in/country-name/ |
                match = re.match(r'\|\s*([^|]+)\s*\|\s*https://trends24\.in/([^/]+)/?\s*\|', line)
                if match:
                    country_name = match.group(1).strip()
                    url_path = match.group(2).strip()
                    mapping[country_name] = url_path
                    
    except Exception as e:
        print(f"[WARN] 无法加载 trender.txt: {e}")
    
    return mapping


def extract_country_name(full_name: str) -> str:
    """
    从 "United States (美国)" 中提取 "United States"
    
    Args:
        full_name: 完整的国家/地区名称
    
    Returns:
        英文名称部分
    """
    # 移除括号及其中内容
    name = re.sub(r'\s*\([^)]*\)', '', full_name)
    return name.strip()


def get_country_mapping() -> Tuple[Dict[str, Optional[str]], List[str]]:
    """
    动态生成国家代码到 trends24.in URL 的映射
    
    Returns:
        (映射字典, 使用 worldwide 的国家/地区代码列表)
        映射字典: {国家代码: URL路径 或 None}
    """
    mapping = {}
    use_worldwide = []
    
    # 加载配置
    map_data = load_map_json()
    trender_mapping = load_trender_mapping()
    
    for country in map_data.get("countries", []):
        country_id = country.get("id")
        country_name_full = country.get("name", "")
        country_name = extract_country_name(country_name_full)
        
        if country_id:
            # 在 trender.txt 中查找对应的 URL
            url_path = trender_mapping.get(country_name)
            
            if url_path:
                mapping[country_id] = url_path
            else:
                # 如果在 trender.txt 中找不到，标记为使用 worldwide
                mapping[country_id] = None
                use_worldwide.append(country_id)
                print(f"[INFO] {country_id} ({country_name}) 在 trender.txt 中未找到，将使用 worldwide")
    
    return mapping, use_worldwide


def get_keyword_file_mapping() -> Dict[str, str]:
    """
    动态生成国家代码到关键词文件名的映射
    
    Returns:
        字典: {国家代码: 关键词文件名}
    """
    mapping = {}
    map_data = load_map_json()
    
    for country in map_data.get("countries", []):
        country_id = country.get("id")
        keyword_file = country.get("keyword_file")
        if country_id and keyword_file:
            mapping[country_id] = keyword_file
    
    return mapping


def get_supported_countries() -> List[str]:
    """
    获取所有支持的国家/地区代码列表
    
    Returns:
        国家代码列表
    """
    map_data = load_map_json()
    return [country.get("id") for country in map_data.get("countries", []) if country.get("id")]


# 在导入时生成映射（保持向后兼容）
COUNTRY_MAPPING, USE_WORLDWIDE = get_country_mapping()
KEYWORD_FILE_MAPPING = get_keyword_file_mapping()

if __name__ == "__main__":
    # 测试代码
    print("国家/地区映射:")
    for code, url in sorted(COUNTRY_MAPPING.items()):
        if url:
            print(f"  {code}: {url}")
        else:
            print(f"  {code}: (使用 worldwide)")
    
    print(f"\n使用 worldwide 的国家/地区: {USE_WORLDWIDE}")
    
    print("\n关键词文件映射:")
    for code, filename in KEYWORD_FILE_MAPPING.items():
        print(f"  {code}: {filename}")
