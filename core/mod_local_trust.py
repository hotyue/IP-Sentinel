#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import random
import time
from pathlib import Path
from typing import Any

from mod_anchor_browser import (
    append_log,
    detect_risk_from_text,
    infer_timezone,
    is_allowed_public_url,
    load_json_file,
    load_playwright,
    locale_from_lang_params,
    maybe_reexec_into_venv,
    normalize_country_code,
    parse_config,
    resolve_region_path,
    resolve_trust_profile_path,
    safe_profile_segment,
    state_command,
    utc_now_iso,
)


LOCAL_TRUST_RISK_PATTERNS = (
    "access denied",
    "forbidden",
    "request blocked",
    "attention required",
    "temporarily unavailable",
    "blocked",
)


def choose_local_trust_targets(
    trust_profile: dict[str, Any],
    region: dict[str, Any],
    session_size: int,
) -> list[dict[str, str]]:
    requested_count = max(2, min(session_size, 4))
    rng = random.SystemRandom()
    extra_blocked_patterns = tuple(
        str(pattern) for pattern in trust_profile.get("blocked_patterns", []) if isinstance(pattern, str)
    )

    tiers = trust_profile.get("tiers", {})
    selected: list[dict[str, str]] = []
    seen: set[str] = set()

    if isinstance(tiers, dict) and tiers:
        tier_pool: list[dict[str, Any]] = []
        for tier_name, tier_data in tiers.items():
            urls = [
                url
                for url in tier_data.get("urls", [])
                if isinstance(url, str) and is_allowed_public_url(url, extra_blocked_patterns)
            ]
            if not urls:
                continue
            weight = int(tier_data.get("weight", 1) or 1)
            tier_pool.append({"name": tier_name, "weight": max(weight, 1), "urls": urls})

        while len(selected) < requested_count and tier_pool:
            choice_index = rng.choices(
                range(len(tier_pool)),
                weights=[tier["weight"] for tier in tier_pool],
                k=1,
            )[0]
            tier = tier_pool[choice_index]
            available_urls = [url for url in tier["urls"] if url not in seen]
            if not available_urls:
                tier_pool.pop(choice_index)
                continue
            url = rng.choice(available_urls)
            seen.add(url)
            selected.append({"tier": tier["name"], "url": url})
        if selected:
            return selected

    fallback_urls = []
    trust_module = region.get("trust_module", {})
    for key in ("static_urls", "white_urls"):
        for url in trust_module.get(key, []):
            if isinstance(url, str) and is_allowed_public_url(url, extra_blocked_patterns) and url not in fallback_urls:
                fallback_urls.append(url)

    rng.shuffle(fallback_urls)
    for url in fallback_urls[:requested_count]:
        selected.append({"tier": "fallback", "url": url})
    return selected


def should_skip_local_trust(install_dir: Path) -> tuple[bool, dict[str, Any]]:
    state_script = install_dir / "core" / "mod_state.py"
    if not state_script.exists():
        return False, {}

    code, next_action_raw = state_command(state_script, "next-action", "--json")
    if code != 0:
        return False, {}

    next_action = json.loads(next_action_raw)
    if next_action.get("action") != "local_trust":
        return True, {
            "ok": True,
            "skipped": True,
            "reason": next_action.get("reason", "state_machine_blocked"),
            "next_action": next_action,
        }

    code, can_run = state_command(state_script, "can-run", "trust")
    if code == 0 and can_run.strip() != "true":
        return True, {
            "ok": True,
            "skipped": True,
            "reason": "trust_quota_exhausted",
            "next_action": next_action,
        }
    return False, next_action


def consume_trust_budget(install_dir: Path) -> None:
    state_script = install_dir / "core" / "mod_state.py"
    if state_script.exists():
        state_command(state_script, "consume", "trust")


def trust_page_is_risky(content: str) -> bool:
    lower = content.lower()
    return detect_risk_from_text(content) or any(pattern in lower for pattern in LOCAL_TRUST_RISK_PATTERNS)


def main() -> int:
    parser = argparse.ArgumentParser(description="GeoAnchor local trust session")
    parser.add_argument("--mode", default="auto", choices=["auto", "manual"])
    parser.add_argument("--region")
    parser.add_argument("--trust-profile")
    parser.add_argument("--ip-stack", choices=["ipv4", "ipv6"])
    parser.add_argument("--bind-ip")
    parser.add_argument("--locale")
    parser.add_argument("--timezone")
    parser.add_argument("--headless", default="true", choices=["true", "false"])
    parser.add_argument("--session-size", type=int, default=3)
    args = parser.parse_args()

    config_path = Path(__import__("os").environ.get("IP_SENTINEL_CONFIG", "/opt/ip_sentinel/config.conf"))
    config = parse_config(config_path)
    if not config:
        print(json.dumps({"ok": False, "error": f"Missing config file: {config_path}"}))
        return 1

    maybe_reexec_into_venv(config)

    install_dir = Path(config.get("INSTALL_DIR", "/opt/ip_sentinel"))
    log_path = install_dir / "logs" / "local_trust.log"
    region_path = resolve_region_path(args, install_dir, config)
    trust_profile_path = resolve_trust_profile_path(args.trust_profile, install_dir, config)
    region = load_json_file(region_path)
    trust_profile = load_json_file(trust_profile_path)

    target_country = normalize_country_code(config.get("TARGET_COUNTRY") or config.get("REGION_CODE"))
    target_state = config.get("TARGET_STATE", "Default")
    target_city = config.get("TARGET_CITY", "")
    ip_stack = args.ip_stack or ("ipv6" if config.get("IP_PREF") == "6" else "ipv4")
    bind_ip = (args.bind_ip or config.get("BIND_IP") or config.get("PUBLIC_IP") or "").strip()
    profile_dir = install_dir / "profiles" / ip_stack / safe_profile_segment(bind_ip or target_city or "default") / "chromium-profile"
    profile_dir.mkdir(parents=True, exist_ok=True)

    locale = args.locale or trust_profile.get("locale") or locale_from_lang_params(config.get("LANG_PARAMS", ""), target_country)
    timezone = args.timezone or infer_timezone(target_country, target_state, config, trust_profile or region)
    accept_language = f"{locale},{locale.split('-')[0]};q=0.9"

    skip, skip_payload = should_skip_local_trust(install_dir)
    if skip:
        payload = {
            "checked_at": utc_now_iso(),
            "profile_dir": str(profile_dir),
            **skip_payload,
        }
        append_log(log_path, payload)
        print(json.dumps(payload, ensure_ascii=False))
        return 0

    selected_targets = choose_local_trust_targets(trust_profile, region, args.session_size)
    if not selected_targets:
        payload = {
            "ok": False,
            "checked_at": utc_now_iso(),
            "error": "No eligible local trust URLs found.",
            "profile_dir": str(profile_dir),
        }
        append_log(log_path, payload)
        print(json.dumps(payload, ensure_ascii=False))
        return 1

    visited: list[dict[str, Any]] = []
    started_at = time.time()
    successful_visits = 0

    try:
        sync_playwright = load_playwright()
        with sync_playwright() as playwright:
            launch_kwargs: dict[str, Any] = {
                "user_data_dir": str(profile_dir),
                "headless": args.headless == "true",
                "locale": locale,
                "timezone_id": timezone,
                "viewport": {"width": 1365, "height": 768},
                "extra_http_headers": {"Accept-Language": accept_language},
                "ignore_https_errors": False,
            }
            if config.get("PLAYWRIGHT_BROWSER_PATH"):
                launch_kwargs["executable_path"] = config["PLAYWRIGHT_BROWSER_PATH"]
            elif config.get("PLAYWRIGHT_BROWSERS_PATH"):
                __import__("os").environ["PLAYWRIGHT_BROWSERS_PATH"] = config["PLAYWRIGHT_BROWSERS_PATH"]

            context = playwright.chromium.launch_persistent_context(**launch_kwargs)
            try:
                page = context.new_page()
                for target in selected_targets:
                    response = page.goto(target["url"], wait_until="domcontentloaded", timeout=30000)
                    page.wait_for_timeout(1200)
                    content = page.content()
                    status = response.status if response is not None else 0
                    risk = status in {403, 429} or trust_page_is_risky(content)
                    visited.append(
                        {
                            "url": target["url"],
                            "tier": target["tier"],
                            "status": status,
                            "risk": risk,
                            "skipped": risk,
                        }
                    )
                    if not risk:
                        successful_visits += 1
            finally:
                context.close()
    except Exception as exc:  # pragma: no cover
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

    if successful_visits > 0:
        consume_trust_budget(install_dir)

    payload = {
        "ok": successful_visits > 0,
        "checked_at": utc_now_iso(),
        "locale": locale,
        "timezone": timezone,
        "ip_stack": ip_stack,
        "bind_ip": bind_ip,
        "profile_dir": str(profile_dir),
        "duration_seconds": round(time.time() - started_at, 2),
        "visited": visited,
        "successful_visits": successful_visits,
    }
    append_log(log_path, payload)
    print(json.dumps(payload, ensure_ascii=False))
    return 0 if successful_visits > 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
