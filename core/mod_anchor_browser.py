#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs


RISK_PATTERNS = (
    "unusual traffic",
    "captcha",
    "recaptcha",
    "sorry/index",
    "verify you are not a robot",
    "our systems have detected unusual traffic",
)

BLOCKED_TRUST_PATTERNS = (
    "login",
    "signin",
    "checkout",
    "cart",
    "account",
    "bank",
    "banking",
    "pay",
    "payment",
    "amazon.",
    "walmart.",
    "target.",
    "chase.",
)

DEFAULT_VIEWPORT = {"width": 1365, "height": 768}
DEFAULT_LOCALE_BY_COUNTRY = {
    "US": "en-US",
    "GB": "en-GB",
    "CA": "en-CA",
    "AU": "en-AU",
    "DE": "de-DE",
    "FR": "fr-FR",
    "JP": "ja-JP",
    "KR": "ko-KR",
    "TW": "zh-TW",
    "HK": "zh-HK",
    "MO": "zh-HK",
    "SG": "en-SG",
}
DEFAULT_TIMEZONE_BY_COUNTRY = {
    "US": "America/Los_Angeles",
    "GB": "Europe/London",
    "CA": "America/Toronto",
    "AU": "Australia/Sydney",
    "DE": "Europe/Berlin",
    "FR": "Europe/Paris",
    "NL": "Europe/Amsterdam",
    "JP": "Asia/Tokyo",
    "KR": "Asia/Seoul",
    "TW": "Asia/Taipei",
    "HK": "Asia/Hong_Kong",
    "MO": "Asia/Macau",
    "SG": "Asia/Singapore",
}
US_STATE_TIMEZONE = {
    "CA": "America/Los_Angeles",
    "WA": "America/Los_Angeles",
    "OR": "America/Los_Angeles",
    "NV": "America/Los_Angeles",
    "AZ": "America/Phoenix",
    "UT": "America/Denver",
    "CO": "America/Denver",
    "TX": "America/Chicago",
    "KS": "America/Chicago",
    "IL": "America/Chicago",
    "IA": "America/Chicago",
    "GA": "America/New_York",
    "FL": "America/New_York",
    "NC": "America/New_York",
    "NY": "America/New_York",
    "NJ": "America/New_York",
    "VA": "America/New_York",
    "OH": "America/New_York",
    "HI": "Pacific/Honolulu",
}


def utc_now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def parse_config(config_path: Path) -> dict[str, str]:
    config: dict[str, str] = {}
    if not config_path.exists():
        return config
    for raw_line in config_path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        config[key.strip()] = value.strip().strip('"').strip("'")
    return config


def normalize_country_code(value: str | None) -> str:
    if not value:
        return ""
    return "GB" if value.upper() == "UK" else value.upper()


def safe_profile_segment(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.-]+", "-", value.strip("[]")) or "default"


def locale_from_lang_params(lang_params: str, target_country: str) -> str:
    parsed = parse_qs(lang_params)
    locale = parsed.get("hl", [None])[0]
    if locale:
        if "-" in locale:
            return locale
        return f"{locale}-{target_country}" if target_country else locale
    return DEFAULT_LOCALE_BY_COUNTRY.get(target_country, "en-US")


def infer_timezone(target_country: str, target_state: str, config: dict[str, str], region: dict[str, Any]) -> str:
    if config.get("BROWSER_TIMEZONE"):
        return config["BROWSER_TIMEZONE"]
    if region.get("timezone"):
        return str(region["timezone"])
    if target_country == "US":
        return US_STATE_TIMEZONE.get(target_state, "America/Los_Angeles")
    return DEFAULT_TIMEZONE_BY_COUNTRY.get(target_country, "UTC")


def resolve_region_path(args: argparse.Namespace, install_dir: Path, config: dict[str, str]) -> Path | None:
    if args.region:
        return Path(args.region)
    target_country = normalize_country_code(config.get("TARGET_COUNTRY") or config.get("REGION_CODE"))
    target_state = config.get("TARGET_STATE", "Default")
    target_city = config.get("TARGET_CITY", "")
    if not target_country or not target_city:
        return None
    return install_dir / "data" / "regions" / target_country / target_state / f"{target_city}.json"


def load_json_file(path: Path | None) -> dict[str, Any]:
    if not path or not path.exists():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


def choose_public_urls(region: dict[str, Any], trust_profile: dict[str, Any]) -> list[str]:
    urls: list[str] = []
    tiers = trust_profile.get("tiers", {})
    if isinstance(tiers, dict):
        for tier in tiers.values():
            urls.extend(url for url in tier.get("urls", []) if isinstance(url, str))
    else:
        trust_module = region.get("trust_module", {})
        urls.extend(url for url in trust_module.get("static_urls", []) if isinstance(url, str))
        urls.extend(url for url in trust_module.get("white_urls", []) if isinstance(url, str))

    filtered: list[str] = []
    seen: set[str] = set()
    for url in urls:
        lower = url.lower()
        if any(pattern in lower for pattern in BLOCKED_TRUST_PATTERNS):
            continue
        if url not in seen:
            seen.add(url)
            filtered.append(url)
    return filtered[:3]


def state_command(script_path: Path, *args: str) -> tuple[int, str]:
    completed = subprocess.run(
        [sys.executable, str(script_path), *args],
        capture_output=True,
        text=True,
        check=False,
    )
    return completed.returncode, completed.stdout.strip() or completed.stderr.strip()


def should_skip_anchor(args: argparse.Namespace, install_dir: Path) -> tuple[bool, dict[str, Any]]:
    state_script = install_dir / "core" / "mod_state.py"
    if not state_script.exists():
        return False, {}

    code, next_action_raw = state_command(state_script, "next-action", "--json")
    if code != 0:
        return False, {}
    next_action = json.loads(next_action_raw)
    if next_action.get("action") != "anchor_browser":
        return True, {
            "ok": True,
            "skipped": True,
            "reason": next_action.get("reason", "state_machine_blocked"),
            "next_action": next_action,
        }

    code, can_run = state_command(state_script, "can-run", "anchor")
    if code == 0 and can_run.strip() != "true":
        return True, {
            "ok": True,
            "skipped": True,
            "reason": "anchor_quota_exhausted",
            "next_action": next_action,
        }
    return False, next_action


def update_state_bot_risk(install_dir: Path, reason: str) -> None:
    state_script = install_dir / "core" / "mod_state.py"
    if state_script.exists():
        subprocess.run(
            [sys.executable, str(state_script), "set-state", "BOT_RISK", "--reason", reason, "--cooldown-hours", "72"],
            capture_output=True,
            text=True,
            check=False,
        )


def consume_anchor_budget(install_dir: Path) -> None:
    state_script = install_dir / "core" / "mod_state.py"
    if state_script.exists():
        subprocess.run(
            [sys.executable, str(state_script), "consume", "anchor"],
            capture_output=True,
            text=True,
            check=False,
        )


def load_playwright():
    try:
        from playwright.sync_api import sync_playwright  # type: ignore
    except ImportError as exc:  # pragma: no cover - exercised via runtime validation
        raise RuntimeError("Playwright is not installed. Provision the browser runtime first.") from exc
    return sync_playwright


def maybe_reexec_into_venv(config: dict[str, str]) -> None:
    if os.environ.get("IP_SENTINEL_SKIP_VENV_REEXEC") == "1":
        return
    venv_python = config.get("GEOANCHOR_VENV", "")
    if not venv_python:
        return
    candidate = Path(venv_python) / "bin" / "python"
    if not candidate.exists():
        return
    if Path(sys.executable).resolve() == candidate.resolve():
        return
    env = os.environ.copy()
    env["IP_SENTINEL_SKIP_VENV_REEXEC"] = "1"
    completed = subprocess.run([str(candidate), Path(__file__).resolve(), *sys.argv[1:]], env=env, check=False)
    raise SystemExit(completed.returncode)


def build_google_urls(region: dict[str, Any], config: dict[str, str], locale: str) -> list[str]:
    lang_params = config.get("LANG_PARAMS", "hl=en-US&gl=US")
    base_lat = region.get("google_module", {}).get("base_lat", config.get("BASE_LAT", "34.0522"))
    base_lon = region.get("google_module", {}).get("base_lon", config.get("BASE_LON", "-118.2437"))
    gl = parse_qs(lang_params).get("gl", [normalize_country_code(config.get("TARGET_COUNTRY") or config.get("REGION_CODE")) or "US"])[0]
    return [
        f"https://www.google.com/?{lang_params}",
        f"https://news.google.com/home?hl={locale}&gl={gl}&ceid={gl}:{locale.split('-')[0]}",
        f"https://www.google.com/maps/@{base_lat},{base_lon},12z?{lang_params}",
        "https://www.youtube.com/premium",
    ]


def detect_risk_from_text(text: str) -> bool:
    lower = text.lower()
    return any(pattern in lower for pattern in RISK_PATTERNS)


def append_log(log_path: Path, payload: dict[str, Any]) -> None:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(payload, ensure_ascii=False) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser(description="GeoAnchor browser anchor session")
    parser.add_argument("--mode", default="auto", choices=["auto", "recovery", "manual"])
    parser.add_argument("--region")
    parser.add_argument("--trust-profile")
    parser.add_argument("--ip-stack", choices=["ipv4", "ipv6"])
    parser.add_argument("--bind-ip")
    parser.add_argument("--locale")
    parser.add_argument("--timezone")
    parser.add_argument("--headless", default="true", choices=["true", "false"])
    parser.add_argument("--viewport-width", type=int, default=DEFAULT_VIEWPORT["width"])
    parser.add_argument("--viewport-height", type=int, default=DEFAULT_VIEWPORT["height"])
    args = parser.parse_args()

    config_path = Path(os.environ.get("IP_SENTINEL_CONFIG", "/opt/ip_sentinel/config.conf"))
    config = parse_config(config_path)
    if not config:
        print(json.dumps({"ok": False, "error": f"Missing config file: {config_path}"}))
        return 1
    maybe_reexec_into_venv(config)

    install_dir = Path(config.get("INSTALL_DIR", "/opt/ip_sentinel"))
    log_path = install_dir / "logs" / "anchor_browser.log"
    region_path = resolve_region_path(args, install_dir, config)
    trust_profile_path = Path(args.trust_profile) if args.trust_profile else None
    region = load_json_file(region_path)
    trust_profile = load_json_file(trust_profile_path)

    target_country = normalize_country_code(config.get("TARGET_COUNTRY") or config.get("REGION_CODE"))
    target_state = config.get("TARGET_STATE", "Default")
    target_city = config.get("TARGET_CITY", "")
    ip_stack = args.ip_stack or ("ipv6" if config.get("IP_PREF") == "6" else "ipv4")
    bind_ip = (args.bind_ip or config.get("BIND_IP") or config.get("PUBLIC_IP") or "").strip()
    profile_dir = install_dir / "profiles" / ip_stack / safe_profile_segment(bind_ip or target_city or "default") / "chromium-profile"
    profile_dir.mkdir(parents=True, exist_ok=True)

    locale = args.locale or config.get("BROWSER_LOCALE") or locale_from_lang_params(config.get("LANG_PARAMS", ""), target_country)
    timezone = args.timezone or infer_timezone(target_country, target_state, config, region)
    accept_language = f"{locale},{locale.split('-')[0]};q=0.9"

    if config.get("ENABLE_GEOANCHOR_BROWSER", "true").lower() != "true":
        payload = {
            "ok": True,
            "checked_at": utc_now_iso(),
            "skipped": True,
            "reason": "geoanchor_browser_disabled",
            "profile_dir": str(profile_dir),
        }
        append_log(log_path, payload)
        print(json.dumps(payload, ensure_ascii=False))
        return 0

    skip, skip_payload = should_skip_anchor(args, install_dir)
    if skip:
        payload = {
            "checked_at": utc_now_iso(),
            "profile_dir": str(profile_dir),
            **skip_payload,
        }
        append_log(log_path, payload)
        print(json.dumps(payload, ensure_ascii=False))
        return 0

    candidate_urls = build_google_urls(region, config, locale) + choose_public_urls(region, trust_profile)
    visited: list[dict[str, Any]] = []
    started_at = time.time()
    bot_risk = False

    try:
        sync_playwright = load_playwright()
        with sync_playwright() as playwright:
            browser_path = config.get("PLAYWRIGHT_BROWSER_PATH")
            launch_kwargs: dict[str, Any] = {
                "user_data_dir": str(profile_dir),
                "headless": args.headless == "true",
                "locale": locale,
                "timezone_id": timezone,
                "viewport": {"width": args.viewport_width, "height": args.viewport_height},
                "extra_http_headers": {"Accept-Language": accept_language},
                "ignore_https_errors": False,
            }
            if browser_path:
                launch_kwargs["executable_path"] = browser_path
            elif config.get("PLAYWRIGHT_BROWSERS_PATH"):
                os.environ["PLAYWRIGHT_BROWSERS_PATH"] = config["PLAYWRIGHT_BROWSERS_PATH"]

            context = playwright.chromium.launch_persistent_context(**launch_kwargs)
            try:
                page = context.new_page()
                for url in candidate_urls:
                    response = page.goto(url, wait_until="domcontentloaded", timeout=30000)
                    page.wait_for_timeout(1500)
                    content = page.content()
                    status = response.status if response is not None else 0
                    risk = status in {403, 429} or detect_risk_from_text(content)
                    visited.append({"url": url, "status": status, "risk": risk})
                    if risk:
                        bot_risk = True
                        update_state_bot_risk(install_dir, f"browser_risk:{status or 'content'}")
                        break
            finally:
                context.close()
    except Exception as exc:  # pragma: no cover - runtime surfaced as JSON
        payload = {
            "ok": False,
            "checked_at": utc_now_iso(),
            "error": str(exc),
            "profile_dir": str(profile_dir),
            "visited": visited,
        }
        append_log(log_path, payload)
        print(json.dumps(payload, ensure_ascii=False))
        return 1

    if not bot_risk:
        consume_anchor_budget(install_dir)

    payload = {
        "ok": not bot_risk,
        "checked_at": utc_now_iso(),
        "bot_risk": bot_risk,
        "locale": locale,
        "timezone": timezone,
        "ip_stack": ip_stack,
        "bind_ip": bind_ip,
        "profile_dir": str(profile_dir),
        "duration_seconds": round(time.time() - started_at, 2),
        "visited": visited,
    }
    append_log(log_path, payload)
    print(json.dumps(payload, ensure_ascii=False))
    return 0 if not bot_risk else 1


if __name__ == "__main__":
    raise SystemExit(main())
