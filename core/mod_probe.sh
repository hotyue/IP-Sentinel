#!/bin/bash

CONFIG_FILE="/opt/ip_sentinel/config.conf"

emit_probe_failure() {
    jq -n \
        --arg error_message "$1" \
        '{
            ok: false,
            score: 0,
            state_hint: "UNKNOWN",
            warnings: [],
            errors: [$error_message]
        }'
}

if [ ! -f "$CONFIG_FILE" ]; then
    emit_probe_failure "Missing config file: ${CONFIG_FILE}"
    exit 0
fi

source "$CONFIG_FILE"

INSTALL_DIR="${INSTALL_DIR:-/opt/ip_sentinel}"
STATE_DIR="${INSTALL_DIR}/state"
LOG_DIR="${INSTALL_DIR}/logs"
PROBE_LOG="${LOG_DIR}/probe.log"
PREFLIGHT_STATE_FILE="${STATE_DIR}/preflight-last.json"
BOT_RISK_FILE="${STATE_DIR}/bot_risk.json"
GEO_SCORE_HISTORY_FILE="${STATE_DIR}/geo_score_history.jsonl"
PREFLIGHT_SCRIPT="${INSTALL_DIR}/core/preflight.sh"

mkdir -p "$STATE_DIR" "$LOG_DIR"

WARNINGS=()
ERRORS=()

add_warning() {
    WARNINGS+=("$1")
}

add_error() {
    ERRORS+=("$1")
}

utc_now_iso() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

log_probe() {
    printf '[%s] %s\n' "$(utc_now_iso)" "$1" >> "$PROBE_LOG"
}

strip_brackets() {
    printf '%s' "$1" | tr -d '[]'
}

normalize_country_code() {
    case "$1" in
        UK) printf 'GB' ;;
        *) printf '%s' "$1" ;;
    esac
}

array_to_json() {
    if [ "$#" -eq 0 ]; then
        printf '[]'
    else
        printf '%s\n' "$@" | jq -R . | jq -s .
    fi
}

write_bot_risk_file() {
    local reason=$1
    local http_status=${2:-""}
    local target_url=${3:-""}
    local detected_at expires_at_epoch expires_at
    detected_at=$(utc_now_iso)
    expires_at_epoch=$(( $(date -u +%s) + 72 * 3600 ))
    expires_at=$(date -u -d "@${expires_at_epoch}" '+%Y-%m-%dT%H:%M:%SZ')

    jq -n \
        --arg reason "$reason" \
        --arg http_status "$http_status" \
        --arg target_url "$target_url" \
        --arg detected_at "$detected_at" \
        --arg expires_at "$expires_at" \
        --argjson expires_at_epoch "$expires_at_epoch" \
        '{
            active: true,
            reason: $reason,
            http_status: $http_status,
            target_url: $target_url,
            detected_at: $detected_at,
            expires_at: $expires_at,
            expires_at_epoch: $expires_at_epoch,
            cooldown_hours: 72
        }' > "$BOT_RISK_FILE"
}

response_triggers_bot_risk() {
    local http_code=$1
    local response_file=$2
    local target_url=$3

    if [ "$http_code" = "403" ] || [ "$http_code" = "429" ]; then
        write_bot_risk_file "http_${http_code}" "$http_code" "$target_url"
        return 0
    fi

    if [ -f "$response_file" ] && grep -Eiq 'captcha|recaptcha|unusual traffic|sorry/index|verify you are not a robot|our systems have detected unusual traffic' "$response_file"; then
        write_bot_risk_file "captcha_or_unusual_traffic" "$http_code" "$target_url"
        return 0
    fi

    return 1
}

country_from_jump_location() {
    local jump_loc=$1
    local jump_gl=""

    if [ -z "$jump_loc" ]; then
        jump_gl="US"
    elif [[ "$jump_loc" == *".google.cn"* ]] || [[ "$jump_loc" == *"gl=CN"* ]]; then
        jump_gl="CN"
    elif [[ "$jump_loc" == *"gl="* ]]; then
        jump_gl=$(printf '%s' "$jump_loc" | grep -o 'gl=[A-Za-z]\{2\}' | head -n 1 | cut -d'=' -f2 | tr '[:lower:]' '[:upper:]')
    else
        local jump_domain last_ext
        jump_domain=$(printf '%s' "$jump_loc" | grep -o 'google\.[a-z\.]*' | head -n 1 | sed 's/google\.//')
        case "$jump_domain" in
            com) jump_gl="US" ;;
            com.hk) jump_gl="HK" ;;
            com.tw) jump_gl="TW" ;;
            co.jp) jump_gl="JP" ;;
            co.uk) jump_gl="GB" ;;
            co.kr) jump_gl="KR" ;;
            co.in) jump_gl="IN" ;;
            co.id) jump_gl="ID" ;;
            co.th) jump_gl="TH" ;;
            com.sg) jump_gl="SG" ;;
            com.my) jump_gl="MY" ;;
            com.au) jump_gl="AU" ;;
            com.br) jump_gl="BR" ;;
            com.mx) jump_gl="MX" ;;
            com.ar) jump_gl="AR" ;;
            co.za) jump_gl="ZA" ;;
            cn) jump_gl="CN" ;;
            "")
                jump_gl=""
                ;;
            *)
                last_ext=$(printf '%s' "$jump_domain" | awk -F'.' '{print $NF}' | tr '[:lower:]' '[:upper:]')
                if [ ${#last_ext} -eq 2 ]; then
                    jump_gl="$last_ext"
                else
                    jump_gl="US"
                fi
                ;;
        esac
    fi

    printf '%s' "$jump_gl"
}

detect_state_hint() {
    local detected_country=$1
    local score=$2
    local bot_risk=$3
    local target_country=$4

    if [ "$bot_risk" = "true" ]; then
        printf 'BOT_RISK'
    elif [ "$detected_country" = "CN" ]; then
        printf 'CN_LOCKED'
    elif [ "$detected_country" = "HK" ]; then
        printf 'HK_DRIFT'
    elif [ -z "$detected_country" ]; then
        printf 'UNKNOWN'
    elif [ "$detected_country" != "$target_country" ]; then
        printf 'OTHER_DRIFT'
    elif [ "$score" -ge 81 ]; then
        printf 'TARGET'
    elif [ "$score" -ge 61 ]; then
        printf 'PARTIAL'
    else
        printf 'UNKNOWN'
    fi
}

pick_detected_country() {
    local target_country=$1
    shift

    local first_country=""
    local value
    for value in "$@"; do
        [ -n "$value" ] || continue
        [ -z "$first_country" ] && first_country="$value"
        if [ "$value" = "CN" ] || [ "$value" = "HK" ]; then
            printf '%s' "$value"
            return
        fi
        if [ "$value" != "$target_country" ]; then
            printf '%s' "$value"
            return
        fi
    done

    printf '%s' "$first_country"
}

LIGHT_MODE="false"
IP_STACK=""
BIND_IP_OVERRIDE=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --light)
            LIGHT_MODE="true"
            shift
            ;;
        --json)
            shift
            ;;
        --ip-stack)
            IP_STACK="$2"
            shift 2
            ;;
        --bind-ip)
            BIND_IP_OVERRIDE="$2"
            shift 2
            ;;
        *)
            add_warning "Ignoring unknown argument: $1"
            shift
            ;;
    esac
done

if [ -z "$IP_STACK" ]; then
    if [ "${IP_PREF:-4}" = "6" ]; then
        IP_STACK="ipv6"
    else
        IP_STACK="ipv4"
    fi
fi

STACK_CURL_OPT="-4"
STACK_COUNTRY_KEY="ipv4_country"
STACK_IP_KEY="ipv4"
ACTIVE_BIND_IP=$(strip_brackets "${BIND_IP_OVERRIDE:-${BIND_IP:-}}")

if [ "$IP_STACK" = "ipv6" ]; then
    STACK_CURL_OPT="-6"
    STACK_COUNTRY_KEY="ipv6_country"
    STACK_IP_KEY="ipv6"
    if [ -z "$ACTIVE_BIND_IP" ] || [[ "$ACTIVE_BIND_IP" != *":"* ]]; then
        ACTIVE_BIND_IP=$(strip_brackets "${PUBLIC_IP:-}")
    fi
elif [ -n "$ACTIVE_BIND_IP" ] && [[ "$ACTIVE_BIND_IP" == *":"* ]]; then
    ACTIVE_BIND_IP=""
fi

CURL_BIND_ARGS=()
if [ -n "$ACTIVE_BIND_IP" ]; then
    CURL_BIND_ARGS=(--interface "$ACTIVE_BIND_IP")
fi

TARGET_COUNTRY_CODE=$(normalize_country_code "${TARGET_COUNTRY:-${REGION_CODE%%-*}}")
SESSION_UA=$(grep -v '^$' "${INSTALL_DIR}/data/user_agents.txt" 2>/dev/null | head -n 1)
[ -n "$SESSION_UA" ] || SESSION_UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

if [ ! -f "$PREFLIGHT_STATE_FILE" ] && [ -x "$PREFLIGHT_SCRIPT" ]; then
    bash "$PREFLIGHT_SCRIPT" > "$PREFLIGHT_STATE_FILE"
fi

if [ ! -f "$PREFLIGHT_STATE_FILE" ]; then
    add_error "Missing preflight state. Run core/preflight.sh first."
fi

if [ "${#ERRORS[@]}" -gt 0 ]; then
    WARNINGS_JSON=$(array_to_json "${WARNINGS[@]}")
    ERRORS_JSON=$(array_to_json "${ERRORS[@]}")
    RESULT_JSON=$(jq -n \
        --argjson warnings "$WARNINGS_JSON" \
        --argjson errors "$ERRORS_JSON" \
        '{ok: false, score: 0, state_hint: "UNKNOWN", warnings: $warnings, errors: $errors}')
    printf '%s\n' "$RESULT_JSON"
    exit 0
fi

PREFLIGHT_JSON=$(cat "$PREFLIGHT_STATE_FILE")
PREFLIGHT_OK=$(printf '%s' "$PREFLIGHT_JSON" | jq -r '.ok // false' 2>/dev/null)
ACTIVE_STACK_COUNTRY=$(printf '%s' "$PREFLIGHT_JSON" | jq -r ".ip.${STACK_COUNTRY_KEY} // empty" 2>/dev/null)
ACTIVE_STACK_IP=$(printf '%s' "$PREFLIGHT_JSON" | jq -r ".ip.${STACK_IP_KEY} // empty" 2>/dev/null)
DNS_COUNTRY=$(printf '%s' "$PREFLIGHT_JSON" | jq -r '.dns.resolver_country // empty' 2>/dev/null)
STACK_MATCH=$(printf '%s' "$PREFLIGHT_JSON" | jq -r '.ip.stack_match // null' 2>/dev/null)
PUBLIC_MATCH=$(printf '%s' "$PREFLIGHT_JSON" | jq -r '.ip.public_ip_match // null' 2>/dev/null)
GOOGLE_RESOLVED=$(printf '%s' "$PREFLIGHT_JSON" | jq -r '.dns.google_resolved // false' 2>/dev/null)
YOUTUBE_RESOLVED=$(printf '%s' "$PREFLIGHT_JSON" | jq -r '.dns.youtube_resolved // false' 2>/dev/null)
GSTATIC_RESOLVED=$(printf '%s' "$PREFLIGHT_JSON" | jq -r '.dns.gstatic_resolved // false' 2>/dev/null)

JUMP_GL=""
YT_PR_GL=""
YT_MU_GL=""
BOT_RISK="false"

JUMP_HEADERS=$(mktemp)
JUMP_CODE=$(curl "${CURL_BIND_ARGS[@]}" "$STACK_CURL_OPT" -m 10 -sI -D "$JUMP_HEADERS" -o /dev/null -w "%{http_code}" -A "$SESSION_UA" "http://www.google.com/" 2>/dev/null || printf '000')
if response_triggers_bot_risk "$JUMP_CODE" "$JUMP_HEADERS" "http://www.google.com/"; then
    BOT_RISK="true"
else
    JUMP_LOC=$(grep -i '^location:' "$JUMP_HEADERS" | tr -d '\r\n')
    JUMP_GL=$(country_from_jump_location "$JUMP_LOC")
fi
rm -f "$JUMP_HEADERS"

if [ "$LIGHT_MODE" != "true" ] && [ "$BOT_RISK" != "true" ]; then
    YT_PR_BODY=$(mktemp)
    YT_PR_CODE=$(curl "${CURL_BIND_ARGS[@]}" "$STACK_CURL_OPT" -m 10 -s -L -o "$YT_PR_BODY" -w "%{http_code}" -A "$SESSION_UA" "https://www.youtube.com/premium" 2>/dev/null || printf '000')
    if response_triggers_bot_risk "$YT_PR_CODE" "$YT_PR_BODY" "https://www.youtube.com/premium"; then
        BOT_RISK="true"
    elif grep -q 'www.google.cn' "$YT_PR_BODY"; then
        YT_PR_GL="CN"
    else
        YT_PR_GL=$(grep -o '"contentRegion":"[A-Za-z]\{2\}"' "$YT_PR_BODY" | head -n 1 | cut -d'"' -f4 | tr '[:lower:]' '[:upper:]')
        [ -n "$YT_PR_GL" ] || YT_PR_GL=$(grep -o '"countryCode":"[A-Za-z]\{2\}"' "$YT_PR_BODY" | head -n 1 | cut -d'"' -f4 | tr '[:lower:]' '[:upper:]')
        [ -n "$YT_PR_GL" ] || YT_PR_GL=$(grep -o '"INNERTUBE_CONTEXT_GL":"[A-Za-z]\{2\}"' "$YT_PR_BODY" | head -n 1 | cut -d'"' -f4 | tr '[:lower:]' '[:upper:]')
    fi
    rm -f "$YT_PR_BODY"

    YT_MU_BODY=$(mktemp)
    YT_MU_CODE=$(curl "${CURL_BIND_ARGS[@]}" "$STACK_CURL_OPT" -m 10 -s -L -o "$YT_MU_BODY" -w "%{http_code}" -A "$SESSION_UA" "https://music.youtube.com/" 2>/dev/null || printf '000')
    if response_triggers_bot_risk "$YT_MU_CODE" "$YT_MU_BODY" "https://music.youtube.com/"; then
        BOT_RISK="true"
    elif grep -q 'www.google.cn' "$YT_MU_BODY"; then
        YT_MU_GL="CN"
    else
        YT_MU_GL=$(grep -o '"INNERTUBE_CONTEXT_GL":"[A-Za-z]\{2\}"' "$YT_MU_BODY" | head -n 1 | cut -d'"' -f4 | tr '[:lower:]' '[:upper:]')
        [ -n "$YT_MU_GL" ] || YT_MU_GL=$(grep -o '"countryCode":"[A-Za-z]\{2\}"' "$YT_MU_BODY" | head -n 1 | cut -d'"' -f4 | tr '[:lower:]' '[:upper:]')
        [ -n "$YT_MU_GL" ] || YT_MU_GL=$(grep -o '"GL":"[A-Za-z]\{2\}"' "$YT_MU_BODY" | head -n 1 | cut -d'"' -f4 | tr '[:lower:]' '[:upper:]')
    fi
    rm -f "$YT_MU_BODY"
fi

SCORE=0
JUMP_MATCH_JSON="false"
YT_PR_MATCH_JSON="false"
YT_MU_MATCH_JSON="false"
DNS_MATCH_JSON="false"
STACK_COUNTRY_MATCH_JSON="false"
STACK_CONSISTENCY_JSON="false"
PUBLIC_MATCH_BOOL_JSON="false"
HOST_RESOLUTION_MATCH_JSON="false"

if [ "$JUMP_GL" = "$TARGET_COUNTRY_CODE" ]; then
    SCORE=$((SCORE + 15))
    JUMP_MATCH_JSON="true"
fi

if [ "$YT_PR_GL" = "$TARGET_COUNTRY_CODE" ]; then
    SCORE=$((SCORE + 15))
    YT_PR_MATCH_JSON="true"
fi

if [ "$YT_MU_GL" = "$TARGET_COUNTRY_CODE" ]; then
    SCORE=$((SCORE + 10))
    YT_MU_MATCH_JSON="true"
fi

if [ "$DNS_COUNTRY" = "$TARGET_COUNTRY_CODE" ]; then
    SCORE=$((SCORE + 10))
    DNS_MATCH_JSON="true"
fi

if [ "$ACTIVE_STACK_COUNTRY" = "$TARGET_COUNTRY_CODE" ]; then
    SCORE=$((SCORE + 20))
    STACK_COUNTRY_MATCH_JSON="true"
fi

if [ "$STACK_MATCH" = "true" ] || { [ "$IP_STACK" = "ipv4" ] && [ -z "$(printf '%s' "$PREFLIGHT_JSON" | jq -r '.ip.ipv6 // empty' 2>/dev/null)" ]; } || { [ "$IP_STACK" = "ipv6" ] && [ -z "$(printf '%s' "$PREFLIGHT_JSON" | jq -r '.ip.ipv4 // empty' 2>/dev/null)" ]; }; then
    SCORE=$((SCORE + 10))
    STACK_CONSISTENCY_JSON="true"
fi

if [ "$PUBLIC_MATCH" = "true" ]; then
    SCORE=$((SCORE + 10))
    PUBLIC_MATCH_BOOL_JSON="true"
fi

if [ "$GOOGLE_RESOLVED" = "true" ] && [ "$YOUTUBE_RESOLVED" = "true" ] && [ "$GSTATIC_RESOLVED" = "true" ]; then
    SCORE=$((SCORE + 10))
    HOST_RESOLUTION_MATCH_JSON="true"
fi

DETECTED_COUNTRY=$(pick_detected_country "$TARGET_COUNTRY_CODE" "$YT_PR_GL" "$YT_MU_GL" "$JUMP_GL" "$ACTIVE_STACK_COUNTRY" "$DNS_COUNTRY")
STATE_HINT=$(detect_state_hint "$DETECTED_COUNTRY" "$SCORE" "$BOT_RISK" "$TARGET_COUNTRY_CODE")

HISTORY_ENTRY=$(jq -cn \
    --arg ts "$(utc_now_iso)" \
    --arg ip_stack "$IP_STACK" \
    --arg bind_ip "$ACTIVE_BIND_IP" \
    --arg target_country "$TARGET_COUNTRY_CODE" \
    --arg detected_country "$DETECTED_COUNTRY" \
    --arg jump "$JUMP_GL" \
    --arg yt_premium "$YT_PR_GL" \
    --arg yt_music "$YT_MU_GL" \
    --arg dns "$DNS_COUNTRY" \
    --arg state "$STATE_HINT" \
    --argjson score "$SCORE" \
    '{ts:$ts,score:$score,state:$state,ip_stack:$ip_stack,bind_ip:$bind_ip,target_country:$target_country,detected_country:$detected_country,jump:$jump,yt_premium:$yt_premium,yt_music:$yt_music,dns:$dns}')
printf '%s\n' "$HISTORY_ENTRY" >> "$GEO_SCORE_HISTORY_FILE"

WARNINGS_JSON=$(array_to_json "${WARNINGS[@]}")
ERRORS_JSON=$(array_to_json "${ERRORS[@]}")

RESULT_JSON=$(jq -n \
    --argjson ok true \
    --arg checked_at "$(utc_now_iso)" \
    --arg ip_stack "$IP_STACK" \
    --arg bind_ip "$ACTIVE_BIND_IP" \
    --arg target_country "$TARGET_COUNTRY_CODE" \
    --arg detected_country "$DETECTED_COUNTRY" \
    --arg state_hint "$STATE_HINT" \
    --arg preflight_state "$(printf '%s' "$PREFLIGHT_JSON" | jq -r '.state_hint // "UNKNOWN"' 2>/dev/null)" \
    --arg jump_country "$JUMP_GL" \
    --arg yt_premium_country "$YT_PR_GL" \
    --arg yt_music_country "$YT_MU_GL" \
    --arg dns_country "$DNS_COUNTRY" \
    --arg active_stack_country "$ACTIVE_STACK_COUNTRY" \
    --arg active_stack_ip "$ACTIVE_STACK_IP" \
    --arg history_file "$GEO_SCORE_HISTORY_FILE" \
    --argjson score "$SCORE" \
    --argjson bot_risk "$BOT_RISK" \
    --argjson jump_match "$JUMP_MATCH_JSON" \
    --argjson yt_premium_match "$YT_PR_MATCH_JSON" \
    --argjson yt_music_match "$YT_MU_MATCH_JSON" \
    --argjson dns_match "$DNS_MATCH_JSON" \
    --argjson stack_country_match "$STACK_COUNTRY_MATCH_JSON" \
    --argjson stack_consistency "$STACK_CONSISTENCY_JSON" \
    --argjson public_ip_match "$PUBLIC_MATCH_BOOL_JSON" \
    --argjson host_resolution_match "$HOST_RESOLUTION_MATCH_JSON" \
    --argjson warnings "$WARNINGS_JSON" \
    --argjson errors "$ERRORS_JSON" \
    '{
        ok: $ok,
        checked_at: $checked_at,
        ip_stack: $ip_stack,
        bind_ip: $bind_ip,
        target_country: $target_country,
        detected_country: $detected_country,
        score: $score,
        state_hint: $state_hint,
        preflight_state: $preflight_state,
        bot_risk: $bot_risk,
        history_file: $history_file,
        warnings: $warnings,
        errors: $errors,
        signals: {
            jump: {country: $jump_country, match: $jump_match, weight: 15},
            youtube_premium: {country: $yt_premium_country, match: $yt_premium_match, weight: 15},
            youtube_music: {country: $yt_music_country, match: $yt_music_match, weight: 10},
            dns: {country: $dns_country, match: $dns_match, weight: 10},
            active_stack: {ip: $active_stack_ip, country: $active_stack_country, match: $stack_country_match, weight: 20},
            stack_consistency: {match: $stack_consistency, weight: 10},
            public_ip_match: {match: $public_ip_match, weight: 10},
            host_resolution: {match: $host_resolution_match, weight: 10}
        }
    }')

log_probe "probe ip_stack=${IP_STACK} score=${SCORE} state=${STATE_HINT} detected_country=${DETECTED_COUNTRY}"
printf '%s\n' "$RESULT_JSON"
