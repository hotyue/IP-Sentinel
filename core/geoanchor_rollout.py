#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

from mod_state import load_state, parse_config, resolve_paths, save_state, set_cooldown, utc_now_iso


ROLLOUT_HISTORY_FILE = "geoanchor_rollout_daily.jsonl"


def load_json_file(path: Path) -> dict[str, Any] | None:
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return None


def parse_iso_datetime(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def append_jsonl(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    needs_newline = path.exists() and path.stat().st_size > 0 and not path.read_text(encoding="utf-8").endswith("\n")
    with path.open("a", encoding="utf-8") as handle:
        if needs_newline:
            handle.write("\n")
        handle.write(json.dumps(payload, ensure_ascii=False) + "\n")


def set_config_value(config_path: Path, key: str, value: str) -> None:
    lines: list[str] = []
    found = False
    if config_path.exists():
        lines = config_path.read_text(encoding="utf-8").splitlines()
    for index, line in enumerate(lines):
        if line.startswith(f"{key}="):
            lines[index] = f'{key}="{value}"'
            found = True
            break
    if not found:
        lines.append(f'{key}="{value}"')
    config_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def read_rollout_history(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    history: list[dict[str, Any]] = []
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line:
            continue
        try:
            history.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return history


def last_three_snapshots(history: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return history[-3:] if len(history) >= 3 else history


def build_snapshot(install_dir: Path, state: dict[str, Any], config: dict[str, str]) -> dict[str, Any]:
    preflight = load_json_file(install_dir / "state" / "preflight-last.json") or {}
    probe = state.get("last_probe") or {}
    rollout_mode = config.get("GEOANCHOR_ROLLOUT_MODE", "normal")
    last_bot_risk_at = parse_iso_datetime(state.get("last_bot_risk_at"))
    now = datetime.now(timezone.utc)
    bot_risk_count = 1 if last_bot_risk_at and now - last_bot_risk_at <= timedelta(days=1) else 0

    return {
        "date": now.date().isoformat(),
        "captured_at": utc_now_iso(),
        "rollout_mode": rollout_mode,
        "current_state": state.get("current_state", "UNKNOWN"),
        "score": int(state.get("last_score", 0) or 0),
        "jump_country": probe.get("jump_country") or probe.get("signals", {}).get("jump", {}).get("country") or "",
        "yt_premium_country": probe.get("yt_premium_country") or probe.get("signals", {}).get("youtube_premium", {}).get("country") or "",
        "yt_music_country": probe.get("yt_music_country") or probe.get("signals", {}).get("youtube_music", {}).get("country") or "",
        "dns_country": probe.get("dns_country") or probe.get("signals", {}).get("dns", {}).get("country") or preflight.get("dns", {}).get("resolver_country") or "",
        "ipv4_status": preflight.get("ip", {}).get("ipv4") or "",
        "ipv6_status": preflight.get("ip", {}).get("ipv6") or "",
        "active_stack_ip": probe.get("signals", {}).get("active_stack", {}).get("ip") or "",
        "active_stack_country": probe.get("active_stack_country") or probe.get("signals", {}).get("active_stack", {}).get("country") or "",
        "bot_risk_count": bot_risk_count,
    }


def maybe_apply_cooldown(state: dict[str, Any], state_path: Path, snapshot: dict[str, Any]) -> bool:
    if int(snapshot.get("bot_risk_count", 0) or 0) <= 0:
        return False
    if state.get("cooldown_until"):
        return False
    set_cooldown(state, 72, "rollout_bot_risk")
    state["last_reason"] = "rollout_bot_risk"
    save_state(state_path, state)
    return True


def evaluate_rollout(history: list[dict[str, Any]], config_path: Path, config: dict[str, str]) -> tuple[str, bool]:
    latest_three = last_three_snapshots(history)
    if len(latest_three) < 3:
        return config.get("GEOANCHOR_ROLLOUT_MODE", "normal"), False

    first_score = int(latest_three[0].get("score", 0) or 0)
    latest_score = int(latest_three[-1].get("score", 0) or 0)
    improved = latest_score > first_score
    if improved:
        if config.get("GEOANCHOR_ROLLOUT_MODE", "normal") != "normal":
            set_config_value(config_path, "GEOANCHOR_ROLLOUT_MODE", "normal")
            return "normal", True
        return "normal", False

    if config.get("GEOANCHOR_ROLLOUT_MODE", "normal") != "conservative":
        set_config_value(config_path, "GEOANCHOR_ROLLOUT_MODE", "conservative")
        return "conservative", True
    return "conservative", False


def cmd_snapshot(_: argparse.Namespace) -> int:
    config_path, install_dir = resolve_paths()
    state, config, state_path = load_state(config_path, install_dir)
    history_path = install_dir / "state" / ROLLOUT_HISTORY_FILE

    snapshot = build_snapshot(install_dir, state, config)
    append_jsonl(history_path, snapshot)

    cooldown_applied = maybe_apply_cooldown(state, state_path, snapshot)
    history = read_rollout_history(history_path)
    rollout_mode, rollout_changed = evaluate_rollout(history, config_path, parse_config(config_path))

    result = {
        "ok": True,
        "snapshot": snapshot,
        "history_file": str(history_path),
        "cooldown_applied": cooldown_applied,
        "rollout_mode": rollout_mode,
        "rollout_changed": rollout_changed,
        "recommendation": (
            "No improvement in the last 3 daily snapshots; switched to conservative mode and recommend the official correction path."
            if rollout_mode == "conservative" and len(last_three_snapshots(history)) >= 3
            else "Continue canary rollout observation."
        ),
    }
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="GeoAnchor rollout recorder")
    subparsers = parser.add_subparsers(dest="command", required=True)

    snapshot = subparsers.add_parser("snapshot")
    snapshot.set_defaults(func=cmd_snapshot)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
