#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

from mod_state import (
    can_run_action,
    is_cooldown_active,
    load_state,
    next_action_payload,
    parse_config,
    resolve_paths,
    save_state,
    set_cooldown,
    utc_now_iso,
)


MANUAL_LOG_FILE = "manual_actions.jsonl"

REASON_MESSAGES = {
    "cooldown_active": "当前仍在冷却期。",
    "bot_risk_active": "当前处于 BOT_RISK，仍在风控冷却。",
    "dns_risk_active": "当前处于 DNS_RISK，请先修复 DNS / IPv6 / 出口一致性。",
    "state_disabled": "当前状态为 DISABLED，已被人工关闭。",
    "anchor_quota_exhausted": "今日 Browser Anchor 配额已用尽。",
    "trust_quota_exhausted": "今日 Local Trust 配额已用尽。",
    "probe_only": "当前状态仅允许 probe。",
    "unknown_state_anchor_blocked": "当前状态仍未知，请先执行 /probe 或 /preflight。",
    "manual_action_not_allowed": "当前状态不允许该手动动作。",
}


def load_json_file(path: Path) -> dict[str, Any] | None:
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return None


def append_jsonl(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(payload, ensure_ascii=False) + "\n")


def append_sentinel_log(install_dir: Path, message: str) -> None:
    log_path = install_dir / "logs" / "sentinel.log"
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("a", encoding="utf-8") as handle:
        handle.write(f"[{utc_now_iso()}] [INFO ] [GeoCtrl ] {message}\n")


def write_manual_log(install_dir: Path, action: str, ok: bool, message: str, extra: dict[str, Any] | None = None) -> None:
    payload: dict[str, Any] = {
        "checked_at": utc_now_iso(),
        "action": action,
        "ok": ok,
        "message": message,
    }
    if extra:
        payload["extra"] = extra
    append_jsonl(install_dir / "logs" / MANUAL_LOG_FILE, payload)
    append_sentinel_log(install_dir, f"manual action={action} ok={str(ok).lower()} message={message}")


def python_bin(config: dict[str, str]) -> str:
    venv_root = config.get("GEOANCHOR_VENV", "")
    if venv_root:
        candidate = Path(venv_root) / "bin" / "python"
        if candidate.exists():
            return str(candidate)
    return sys.executable


def run_command(command: list[str], timeout: int = 120) -> tuple[int, str]:
    try:
        completed = subprocess.run(command, capture_output=True, text=True, check=False, timeout=timeout)
    except subprocess.TimeoutExpired:
        return 1, f"Command timed out after {timeout} seconds."
    output = completed.stdout.strip() or completed.stderr.strip()
    return completed.returncode, output


def run_json_command(command: list[str], timeout: int = 120) -> tuple[int, dict[str, Any]]:
    code, output = run_command(command, timeout=timeout)
    if not output:
        return code, {}
    try:
        return code, json.loads(output)
    except json.JSONDecodeError:
        return code, {"ok": False, "error": output}


def parse_iso_datetime(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def recent_geoscore_trend(history_path: Path) -> list[dict[str, Any]]:
    if not history_path.exists():
        return []

    cutoff = datetime.now(timezone.utc) - timedelta(days=7)
    per_day: dict[str, dict[str, Any]] = {}

    for raw_line in history_path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line:
            continue
        try:
            payload = json.loads(line)
        except json.JSONDecodeError:
            continue

        checked_at = payload.get("checked_at")
        checked_dt = parse_iso_datetime(checked_at)
        if checked_dt is None or checked_dt < cutoff:
            continue
        day_key = checked_dt.date().isoformat()
        existing = per_day.get(day_key)
        if existing is None or checked_dt > parse_iso_datetime(existing.get("checked_at")):
            per_day[day_key] = {
                "date": day_key,
                "checked_at": checked_at,
                "score": int(payload.get("score", 0) or 0),
                "detected_country": payload.get("detected_country") or "UNKNOWN",
                "state_hint": payload.get("state_hint") or "UNKNOWN",
            }

    return [per_day[key] for key in sorted(per_day.keys(), reverse=True)[:7]]


def reason_message(reason: str) -> str:
    return REASON_MESSAGES.get(reason, reason or "状态机拒绝执行。")


def format_status_text(state: dict[str, Any], preflight: dict[str, Any] | None) -> str:
    next_action = next_action_payload(state)
    lines = [
        "📍 *GeoAnchor 当前状态*",
        f"状态: {state.get('current_state', 'UNKNOWN')}",
        f"GeoScore: {int(state.get('last_score', 0) or 0)}",
        f"识别国家: {state.get('last_detected_country') or 'UNKNOWN'}",
        f"最近探针: {state.get('last_probe_at') or '暂无'}",
        f"下一动作: {next_action.get('action', 'probe_only')} ({next_action.get('reason', 'unknown')})",
    ]
    if state.get("cooldown_until"):
        lines.append(f"冷却截止: {state['cooldown_until']}")
    if preflight:
        lines.append(f"最近 Preflight: {'PASS' if preflight.get('ok') else 'FAIL'} / {preflight.get('state_hint', 'UNKNOWN')}")
    return "\n".join(lines)


def format_score_text(state: dict[str, Any], trend: list[dict[str, Any]]) -> str:
    lines = [
        "📈 *GeoScore 趋势（最近 7 天）*",
        f"当前状态: {state.get('current_state', 'UNKNOWN')}",
        f"当前分数: {int(state.get('last_score', 0) or 0)}",
        f"最近探针: {state.get('last_probe_at') or '暂无'}",
    ]
    if not trend:
        lines.append("暂无 7 天内的 GeoScore 历史。")
        return "\n".join(lines)

    lines.append("")
    for item in trend:
        lines.append(
            f"{item['date']}: {item['score']} / {item.get('detected_country', 'UNKNOWN')} / {item.get('state_hint', 'UNKNOWN')}"
        )
    return "\n".join(lines)


def gate_manual_action(state: dict[str, Any], action: str) -> tuple[bool, str]:
    current_state = state.get("current_state", "UNKNOWN")
    if current_state == "DISABLED":
        return False, "state_disabled"
    if is_cooldown_active(state):
        return False, "cooldown_active"
    if current_state == "BOT_RISK":
        return False, "bot_risk_active"
    if current_state == "DNS_RISK":
        return False, "dns_risk_active"
    if action == "anchor" and current_state == "UNKNOWN":
        return False, "unknown_state_anchor_blocked"
    if not can_run_action(state, action):
        return False, f"{action}_quota_exhausted"
    return True, "allowed"


def launch_background(command: list[str]) -> None:
    subprocess.Popen(
        command,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        stdin=subprocess.DEVNULL,
        start_new_session=True,
        close_fds=True,
    )


def cmd_status(_: argparse.Namespace) -> int:
    config_path, install_dir = resolve_paths()
    state, _, _ = load_state(config_path, install_dir)
    preflight = load_json_file(install_dir / "state" / "preflight-last.json")
    message = format_status_text(state, preflight)
    write_manual_log(install_dir, "status", True, "Queried GeoAnchor status.")
    print(message)
    return 0


def cmd_score(_: argparse.Namespace) -> int:
    config_path, install_dir = resolve_paths()
    state, _, _ = load_state(config_path, install_dir)
    trend = recent_geoscore_trend(install_dir / "state" / "geo_score_history.jsonl")
    message = format_score_text(state, trend)
    write_manual_log(install_dir, "score", True, "Queried GeoScore trend.")
    print(message)
    return 0


def cmd_preflight(_: argparse.Namespace) -> int:
    config_path, install_dir = resolve_paths()
    _, config, _ = load_state(config_path, install_dir)
    preflight_path = install_dir / "state" / "preflight-last.json"
    code, payload = run_json_command(["bash", str(install_dir / "core" / "preflight.sh")], timeout=90)
    if payload:
        preflight_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    ok = bool(payload.get("ok"))
    message_lines = [
        "✅ Preflight 通过。" if ok else "⚠️ Preflight 未通过。",
        f"状态提示: {payload.get('state_hint', 'UNKNOWN')}",
    ]
    errors = payload.get("errors") or []
    warnings = payload.get("warnings") or []
    if errors:
        message_lines.append(f"错误: {'; '.join(str(item) for item in errors[:3])}")
    if warnings:
        message_lines.append(f"警告: {'; '.join(str(item) for item in warnings[:3])}")
    message = "\n".join(message_lines)
    write_manual_log(install_dir, "preflight", code == 0 and ok, message, payload)
    print(message)
    return 0 if code == 0 else 1


def cmd_probe(_: argparse.Namespace) -> int:
    config_path, install_dir = resolve_paths()
    _, config, state_path = load_state(config_path, install_dir)
    probe_path = install_dir / "state" / "probe-manual.json"
    code, payload = run_json_command(["bash", str(install_dir / "core" / "mod_probe.sh"), "--light", "--json"], timeout=120)
    if payload:
        probe_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    state, _, _ = load_state(config_path, install_dir)
    if payload:
        update_code, updated_state = run_json_command([python_bin(config), str(install_dir / "core" / "mod_state.py"), "update-from-probe", str(probe_path)], timeout=30)
        if update_code == 0 and updated_state:
            state = updated_state
            save_state(state_path, state)
    message = "\n".join(
        [
            "🛰️ 轻量 Probe 已完成。" if code == 0 else "⚠️ 轻量 Probe 执行失败。",
            f"GeoScore: {int(payload.get('score', 0) or 0)}",
            f"识别国家: {payload.get('detected_country') or 'UNKNOWN'}",
            f"状态: {state.get('current_state', 'UNKNOWN')}",
            f"下一动作: {next_action_payload(state).get('action', 'probe_only')}",
        ]
    )
    write_manual_log(install_dir, "probe", code == 0, message, payload)
    print(message)
    return 0 if code == 0 else 1


def cmd_anchor(_: argparse.Namespace) -> int:
    config_path, install_dir = resolve_paths()
    state, config, _ = load_state(config_path, install_dir)
    if config.get("ENABLE_GEOANCHOR_BROWSER", "true").lower() != "true":
        message = "⛔ Browser Anchor 已拒绝：当前节点未启用 GeoAnchor Browser。"
        write_manual_log(install_dir, "anchor", False, message)
        print(message)
        return 0
    allowed, reason = gate_manual_action(state, "anchor")
    if not allowed:
        message = f"⛔ Browser Anchor 已拒绝：{reason_message(reason)}"
        write_manual_log(install_dir, "anchor", False, message, {"state": state.get("current_state"), "reason": reason})
        print(message)
        return 0

    launch_background([python_bin(config), str(install_dir / "core" / "mod_anchor_browser.py"), "--mode", "manual"])
    message = (
        f"✅ Browser Anchor 已受理并后台启动。\n"
        f"当前状态: {state.get('current_state', 'UNKNOWN')}\n"
        f"剩余动作将由模块自身继续记录到 logs/anchor_browser.log。"
    )
    write_manual_log(install_dir, "anchor", True, message, {"state": state.get("current_state")})
    print(message)
    return 0


def cmd_trust(_: argparse.Namespace) -> int:
    config_path, install_dir = resolve_paths()
    state, config, _ = load_state(config_path, install_dir)
    if config.get("ENABLE_TRUST", "true").lower() != "true":
        message = "⛔ Local Trust 已拒绝：当前节点未启用 Trust 模块。"
        write_manual_log(install_dir, "trust", False, message)
        print(message)
        return 0
    allowed, reason = gate_manual_action(state, "trust")
    if not allowed:
        message = f"⛔ Local Trust 已拒绝：{reason_message(reason)}"
        write_manual_log(install_dir, "trust", False, message, {"state": state.get("current_state"), "reason": reason})
        print(message)
        return 0

    launch_background([python_bin(config), str(install_dir / "core" / "mod_local_trust.py"), "--mode", "manual"])
    message = (
        f"✅ Local Trust 已受理并后台启动。\n"
        f"当前状态: {state.get('current_state', 'UNKNOWN')}\n"
        f"后续访问详情会写入 logs/local_trust.log。"
    )
    write_manual_log(install_dir, "trust", True, message, {"state": state.get("current_state")})
    print(message)
    return 0


def cmd_cooldown(args: argparse.Namespace) -> int:
    config_path, install_dir = resolve_paths()
    state, _, state_path = load_state(config_path, install_dir)
    set_cooldown(state, args.hours, "manual_cooldown")
    state["last_reason"] = "manual_cooldown"
    save_state(state_path, state)
    message = (
        f"🥶 已手动进入冷却。\n"
        f"当前状态: {state.get('current_state', 'UNKNOWN')}\n"
        f"冷却截止: {state.get('cooldown_until') or '已清除'}"
    )
    write_manual_log(install_dir, "cooldown", True, message, {"hours": args.hours})
    print(message)
    return 0


def cmd_resume(_: argparse.Namespace) -> int:
    config_path, install_dir = resolve_paths()
    state, _, state_path = load_state(config_path, install_dir)
    set_cooldown(state, 0, "")
    if state.get("current_state") in {"BOT_RISK", "DISABLED"}:
        state["current_state"] = "UNKNOWN"
    state["last_reason"] = "manual_resume"
    save_state(state_path, state)
    message = (
        "▶️ 已手动解除冷却。\n"
        f"当前状态: {state.get('current_state', 'UNKNOWN')}\n"
        "历史风险时间戳保留，不会被清空。"
    )
    write_manual_log(install_dir, "resume", True, message)
    print(message)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="GeoAnchor control-plane helpers")
    subparsers = parser.add_subparsers(dest="command", required=True)

    status = subparsers.add_parser("status")
    status.set_defaults(func=cmd_status)

    score = subparsers.add_parser("score")
    score.set_defaults(func=cmd_score)

    preflight = subparsers.add_parser("preflight")
    preflight.set_defaults(func=cmd_preflight)

    probe = subparsers.add_parser("probe")
    probe.set_defaults(func=cmd_probe)

    anchor = subparsers.add_parser("anchor")
    anchor.set_defaults(func=cmd_anchor)

    trust = subparsers.add_parser("trust")
    trust.set_defaults(func=cmd_trust)

    cooldown = subparsers.add_parser("cooldown")
    cooldown.add_argument("--hours", type=int, default=24)
    cooldown.set_defaults(func=cmd_cooldown)

    resume = subparsers.add_parser("resume")
    resume.set_defaults(func=cmd_resume)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
