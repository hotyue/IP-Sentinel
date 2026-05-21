#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any


STATE_NAMES = {
    "UNKNOWN",
    "CN_LOCKED",
    "HK_DRIFT",
    "OTHER_DRIFT",
    "PARTIAL",
    "TARGET",
    "STABLE",
    "BOT_RISK",
    "DNS_RISK",
    "DISABLED",
}

POLICIES = {
    "UNKNOWN": {"anchor": 0, "search": 0, "trust": 0},
    "CN_LOCKED": {"anchor": 6, "search": 2, "trust": 2},
    "HK_DRIFT": {"anchor": 4, "search": 1, "trust": 2},
    "OTHER_DRIFT": {"anchor": 3, "search": 1, "trust": 1},
    "PARTIAL": {"anchor": 2, "search": 0, "trust": 0},
    "TARGET": {"anchor": 1, "search": 0, "trust": 1},
    "STABLE": {"anchor": 1, "search": 0, "trust": 0},
    "BOT_RISK": {"anchor": 0, "search": 0, "trust": 0},
    "DNS_RISK": {"anchor": 0, "search": 0, "trust": 0},
    "DISABLED": {"anchor": 0, "search": 0, "trust": 0},
}


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def utc_now_iso() -> str:
    return utc_now().replace(microsecond=0).isoformat().replace("+00:00", "Z")


def today_iso() -> str:
    return utc_now().date().isoformat()


def normalize_country_code(value: str | None) -> str:
    if not value:
        return ""
    return "GB" if value.upper() == "UK" else value.upper()


def parse_config(config_path: Path) -> dict[str, str]:
    config: dict[str, str] = {}
    if not config_path.exists():
        return config

    for raw_line in config_path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        value = value.strip().strip('"').strip("'")
        config[key.strip()] = value
    return config


def resolve_paths() -> tuple[Path, Path]:
    config_path = Path(os.environ.get("IP_SENTINEL_CONFIG", "/opt/ip_sentinel/config.conf"))
    install_dir_env = os.environ.get("IP_SENTINEL_INSTALL_DIR")
    if install_dir_env:
        install_dir = Path(install_dir_env)
    else:
        config = parse_config(config_path)
        install_dir = Path(config.get("INSTALL_DIR", "/opt/ip_sentinel"))
    return config_path, install_dir


def state_file_path(install_dir: Path) -> Path:
    return install_dir / "state" / "geo_state.json"


def default_state(config: dict[str, str]) -> dict[str, Any]:
    target_country = normalize_country_code(config.get("TARGET_COUNTRY") or config.get("REGION_CODE"))
    target_state = config.get("TARGET_STATE", "")
    target_city = config.get("TARGET_CITY", "")
    target_region = target_country if not target_state else f"{target_country}-{target_state}"
    return {
        "current_state": "UNKNOWN",
        "target_country": target_country,
        "target_region": target_region,
        "target_city": target_city,
        "last_score": 0,
        "last_detected_country": None,
        "last_probe_at": None,
        "last_bot_risk_at": None,
        "last_dns_risk_at": None,
        "stable_days": 0,
        "cooldown_until": None,
        "cooldown_reason": None,
        "updated_at": utc_now_iso(),
        "action_counters": {},
        "last_probe": None,
        "last_reason": None,
    }


def load_state(config_path: Path, install_dir: Path) -> tuple[dict[str, Any], dict[str, str], Path]:
    config = parse_config(config_path)
    state_path = state_file_path(install_dir)
    state_path.parent.mkdir(parents=True, exist_ok=True)
    if state_path.exists():
        state = json.loads(state_path.read_text(encoding="utf-8"))
    else:
        state = default_state(config)
    state.setdefault("action_counters", {})
    return state, config, state_path


def save_state(state_path: Path, state: dict[str, Any]) -> None:
    state["updated_at"] = utc_now_iso()
    state_path.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def ensure_counter_window(state: dict[str, Any], action: str) -> dict[str, Any]:
    counters = state.setdefault("action_counters", {})
    counter = counters.setdefault(action, {"date": today_iso(), "used": 0})
    if counter.get("date") != today_iso():
        counter["date"] = today_iso()
        counter["used"] = 0
    return counter


def limit_for_action(state_name: str, action: str) -> int:
    return POLICIES.get(state_name, POLICIES["UNKNOWN"]).get(action, 0)


def can_run_action(state: dict[str, Any], action: str) -> bool:
    counter = ensure_counter_window(state, action)
    return counter.get("used", 0) < limit_for_action(state.get("current_state", "UNKNOWN"), action)


def consume_action(state: dict[str, Any], action: str, count: int = 1) -> dict[str, Any]:
    counter = ensure_counter_window(state, action)
    counter["used"] = int(counter.get("used", 0)) + count
    return counter


def is_cooldown_active(state: dict[str, Any]) -> bool:
    cooldown_until = state.get("cooldown_until")
    if not cooldown_until:
        return False
    try:
        return datetime.fromisoformat(cooldown_until.replace("Z", "+00:00")) > utc_now()
    except ValueError:
        return False


def set_cooldown(state: dict[str, Any], hours: int, reason: str) -> None:
    if hours <= 0:
        state["cooldown_until"] = None
        state["cooldown_reason"] = None
        return
    state["cooldown_until"] = (utc_now() + timedelta(hours=hours)).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    state["cooldown_reason"] = reason


def derive_state_from_probe(state: dict[str, Any], probe: dict[str, Any]) -> str:
    target_country = normalize_country_code(probe.get("target_country") or state.get("target_country"))
    detected_country = normalize_country_code(probe.get("detected_country"))
    score = int(probe.get("score", 0) or 0)

    if probe.get("bot_risk") is True:
        state["last_bot_risk_at"] = probe.get("checked_at") or utc_now_iso()
        set_cooldown(state, 72, "bot_risk")
        return "BOT_RISK"

    if probe.get("preflight_state") == "DNS_RISK":
        state["last_dns_risk_at"] = probe.get("checked_at") or utc_now_iso()
        set_cooldown(state, 0, "")
        return "DNS_RISK"

    if detected_country == "CN":
        set_cooldown(state, 0, "")
        return "CN_LOCKED"
    if detected_country == "HK":
        set_cooldown(state, 0, "")
        return "HK_DRIFT"
    if detected_country and target_country and detected_country != target_country:
        set_cooldown(state, 0, "")
        return "OTHER_DRIFT"

    if detected_country == target_country and score >= 81:
        state["stable_days"] = int(state.get("stable_days", 0)) + 1
        set_cooldown(state, 0, "")
        if score >= 96 and state["stable_days"] >= 7:
            return "STABLE"
        return "TARGET"

    state["stable_days"] = 0
    set_cooldown(state, 0, "")
    if score >= 61:
        return "PARTIAL"
    return "UNKNOWN"


def update_from_probe(state: dict[str, Any], probe: dict[str, Any]) -> dict[str, Any]:
    state["target_country"] = normalize_country_code(probe.get("target_country") or state.get("target_country"))
    state["last_score"] = int(probe.get("score", 0) or 0)
    state["last_detected_country"] = normalize_country_code(probe.get("detected_country"))
    state["last_probe_at"] = probe.get("checked_at") or utc_now_iso()
    state["last_probe"] = probe
    state["current_state"] = derive_state_from_probe(state, probe)
    return state


def next_action_payload(state: dict[str, Any]) -> dict[str, Any]:
    current_state = state.get("current_state", "UNKNOWN")
    if current_state == "DISABLED":
        return {"action": "idle", "reason": "state_disabled"}
    if is_cooldown_active(state) or current_state == "BOT_RISK":
        return {"action": "cooldown", "reason": state.get("cooldown_reason") or "cooldown_active"}
    if current_state in {"DNS_RISK", "UNKNOWN"}:
        return {"action": "probe_only", "reason": "preflight_or_probe_insufficient"}

    if current_state in {"CN_LOCKED", "HK_DRIFT", "OTHER_DRIFT"}:
        if can_run_action(state, "anchor"):
            return {"action": "anchor_browser", "reason": "recovery_anchor_budget_available"}
        if can_run_action(state, "trust"):
            return {"action": "local_trust", "reason": "fallback_trust_budget_available"}
        return {"action": "probe_only", "reason": "recovery_budget_exhausted"}

    if current_state == "PARTIAL":
        if can_run_action(state, "anchor"):
            return {"action": "anchor_browser", "reason": "partial_recovery_anchor_budget_available"}
        return {"action": "probe_only", "reason": "partial_recovery_probe_only"}

    if current_state == "TARGET":
        if can_run_action(state, "anchor"):
            return {"action": "anchor_browser", "reason": "maintenance_anchor_budget_available"}
        return {"action": "probe_only", "reason": "target_monitoring"}

    if current_state == "STABLE":
        return {"action": "probe_only", "reason": "stable_monitoring"}

    return {"action": "probe_only", "reason": "default_probe_only"}


def cmd_get_state(args: argparse.Namespace) -> int:
    config_path, install_dir = resolve_paths()
    state, _, _ = load_state(config_path, install_dir)
    if args.json:
        print(json.dumps(state, ensure_ascii=False, indent=2))
    else:
        print(state.get("current_state", "UNKNOWN"))
    return 0


def cmd_set_state(args: argparse.Namespace) -> int:
    config_path, install_dir = resolve_paths()
    state, _, state_path = load_state(config_path, install_dir)
    state["current_state"] = args.state
    state["last_reason"] = args.reason
    if args.state == "BOT_RISK":
        state["last_bot_risk_at"] = utc_now_iso()
        set_cooldown(state, args.cooldown_hours or 72, args.reason or "manual_bot_risk")
    elif args.state == "DNS_RISK":
        state["last_dns_risk_at"] = utc_now_iso()
        set_cooldown(state, args.cooldown_hours or 0, args.reason or "manual_dns_risk")
    else:
        set_cooldown(state, args.cooldown_hours or 0, args.reason or "")
    save_state(state_path, state)
    print(json.dumps(state, ensure_ascii=False, indent=2))
    return 0


def cmd_update_from_probe(args: argparse.Namespace) -> int:
    config_path, install_dir = resolve_paths()
    state, _, state_path = load_state(config_path, install_dir)
    probe = json.loads(Path(args.probe_json).read_text(encoding="utf-8"))
    update_from_probe(state, probe)
    save_state(state_path, state)
    print(json.dumps(state, ensure_ascii=False, indent=2))
    return 0


def cmd_next_action(args: argparse.Namespace) -> int:
    config_path, install_dir = resolve_paths()
    state, _, _ = load_state(config_path, install_dir)
    payload = next_action_payload(state)
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(payload["action"])
    return 0


def cmd_can_run(args: argparse.Namespace) -> int:
    config_path, install_dir = resolve_paths()
    state, _, state_path = load_state(config_path, install_dir)
    allowed = can_run_action(state, args.action)
    save_state(state_path, state)
    print("true" if allowed else "false")
    return 0


def cmd_consume(args: argparse.Namespace) -> int:
    config_path, install_dir = resolve_paths()
    state, _, state_path = load_state(config_path, install_dir)
    counter = consume_action(state, args.action, args.count)
    save_state(state_path, state)
    print(json.dumps(counter, ensure_ascii=False, indent=2))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="IP-Sentinel GeoAnchor state machine")
    subparsers = parser.add_subparsers(dest="command", required=True)

    get_state = subparsers.add_parser("get-state")
    get_state.add_argument("--json", action="store_true")
    get_state.set_defaults(func=cmd_get_state)

    set_state = subparsers.add_parser("set-state")
    set_state.add_argument("state", choices=sorted(STATE_NAMES))
    set_state.add_argument("--reason")
    set_state.add_argument("--cooldown-hours", type=int, default=0)
    set_state.set_defaults(func=cmd_set_state)

    update_probe = subparsers.add_parser("update-from-probe")
    update_probe.add_argument("probe_json")
    update_probe.set_defaults(func=cmd_update_from_probe)

    next_action = subparsers.add_parser("next-action")
    next_action.add_argument("--json", action="store_true")
    next_action.set_defaults(func=cmd_next_action)

    can_run = subparsers.add_parser("can-run")
    can_run.add_argument("action", choices=["anchor", "search", "trust"])
    can_run.set_defaults(func=cmd_can_run)

    consume = subparsers.add_parser("consume")
    consume.add_argument("action", choices=["anchor", "search", "trust"])
    consume.add_argument("--count", type=int, default=1)
    consume.set_defaults(func=cmd_consume)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
