#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXTRACT="$SCRIPT_DIR/../core/extract_report_stats.sh"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

mkdir -p "$TMP_ROOT/logs" "$TMP_ROOT/data"
cat > "$TMP_ROOT/config.conf" <<CONFIG
TG_TOKEN="test-token"
TG_API_URL="https://telegram.invalid"
CHAT_ID="test-chat"
NODE_ALIAS="report-test"
REGION_CODE="US"
REGION_NAME="Los Angeles"
ENABLE_GOOGLE="true"
ENABLE_TRUST="true"
ENABLE_OTA="false"
AGENT_VERSION="4.3.5"
INSTALL_DIR="$TMP_ROOT"
LOG_FILE="$TMP_ROOT/logs/sentinel.log"
IP_PREF="4"
PUBLIC_IP="192.0.2.10"
BIND_IP=""
COMM_IP="192.0.2.10"
NODE_NAME="report-node"
CONFIG

cat > "$TMP_ROOT/logs/sentinel.log" <<LOG
[2026-10-13 20:00:00 UTC] [v4.3.5] [START] [Google] [US] yesterday-start
[2026-10-13 20:05:00 UTC] [v4.3.5] [SCORE] [Google] [US] 自检结论: ✅ yesterday
[2026-10-14 13:00:00 UTC] [v4.3.5] [INFO ] [Updater] [US] ✅ UA pool updated
[2026-10-14 13:00:01 UTC] [v4.3.5] [WARN ] [Updater] [US] ❌ keyword update failed
[2026-10-14 13:30:00 UTC] [v4.3.5] [SCORE] [Google] [US] 自检结论: ❌ 严重高危
[2026-10-14 14:00:00 UTC] [v4.3.5] [START] [Google] [US] start one
[2026-10-14 14:00:01 UTC] [v4.3.5] [WARN ] [Google] [US] action warning
[2026-10-14 14:15:00 UTC] [v4.3.5] [SCORE] [Google] [US] 自检结论: ✅ | Prem: US | Music: US
[2026-10-14 15:00:00 UTC] [v4.3.5] [START] [Google] [US] start two
[2026-10-14 15:10:00 UTC] [v4.3.5] [SCORE] [Google] [US] 自检结论: ⚠️ 区域漂移
[2026-10-14 15:30:00 UTC] [v4.3.5] [START] [Google] [US] start probe failure
[2026-10-14 15:35:00 UTC] [v4.3.5] [SCORE] [Google] [US] 自检结论: 🚨 探针失效
[2026-10-14 16:00:00 UTC] [v4.3.5] [START] [Trust  ] [US] start three
[2026-10-14 16:05:00 UTC] [v4.3.5] [SCORE] [Trust  ] [US] 自检结论: ✅ 信用净化完成 (已成功注入 5 条无害流量)
[2026-10-14 17:00:00 UTC] [v4.3.5] [START] [Trust  ] [US] still running
[2026-10-15 00:00:00 UTC] [v4.3.5] [START] [Google] [US] tomorrow-start
[2026-10-15 00:05:00 UTC] [v4.3.5] [SCORE] [Google] [US] 自检结论: ✅ tomorrow
LOG

LOG_CONTENT=$(cat "$TMP_ROOT/logs/sentinel.log")
read -r G_TOTAL G_ENDED G_SUCCESS G_FAILED G_WARN G_ABORT T_TOTAL T_ENDED T_SUCCESS T_FAILED \
  < <(printf '%s\n' "$LOG_CONTENT" | "$EXTRACT" "2026-10-14")

g_rate="0.0"
t_rate="0.0"
[ "$G_ENDED" -gt 0 ] && g_rate=$(awk "BEGIN {printf \"%.1f\", ($G_SUCCESS/$G_ENDED)*100}")
[ "$T_ENDED" -gt 0 ] && t_rate=$(awk "BEGIN {printf \"%.1f\", ($T_SUCCESS/$T_ENDED)*100}")

actual="${G_TOTAL}:${G_ENDED}:${G_SUCCESS}:${G_FAILED}:${G_WARN}:${G_ABORT}:${g_rate}:${T_TOTAL}:${T_ENDED}:${T_SUCCESS}:${T_FAILED}:${t_rate}"
expected="3:4:1:1:1:1:25.0:2:1:1:0:100.0"
if [[ "$actual" != "$expected" ]]; then
  echo "regression: mismatch"
  echo "expected: $expected"
  echo "actual:   $actual"
  exit 1
fi

last_snapshot="$(printf '%s\n' "$LOG_CONTENT" | awk '$5 == "[SCORE]" && ($6 == "[Google]" || $6 == "[Trust  ]") {line = $0} END {print line}')"
[[ "$last_snapshot" == *"自检结论: ✅ 信用净化完成"* ]]

echo "report stats regression passed: $actual"
