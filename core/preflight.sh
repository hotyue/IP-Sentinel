#!/bin/bash

CONFIG_FILE="/opt/ip_sentinel/config.conf"

emit_bootstrap_failure() {
    jq -n \
        --arg error_message "$1" \
        '{
            ok: false,
            state_hint: "UNKNOWN",
            warnings: [],
            errors: [$error_message],
            target: {},
            ip: {},
            dns: {},
            system: {},
            profiles: {}
        }'
}

if [ ! -f "$CONFIG_FILE" ]; then
    emit_bootstrap_failure "Missing config file: ${CONFIG_FILE}"
    exit 0
fi

source "$CONFIG_FILE"

INSTALL_DIR="${INSTALL_DIR:-/opt/ip_sentinel}"
STATE_DIR="${INSTALL_DIR}/state"
LOG_DIR="${INSTALL_DIR}/logs"
PREFLIGHT_LOG="${LOG_DIR}/preflight.log"
PREFLIGHT_STATE_FILE="${STATE_DIR}/preflight-last.json"
PROFILES_DIR="${INSTALL_DIR}/profiles"

mkdir -p "$STATE_DIR" "$LOG_DIR" "$PROFILES_DIR"

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

log_preflight() {
    printf '[%s] %s\n' "$(utc_now_iso)" "$1" >> "$PREFLIGHT_LOG"
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

fetch_public_ip() {
    local family=$1
    local ip_value=""

    if [ "$family" = "ipv4" ]; then
        ip_value=$(curl -4 -fsS -m 5 "https://api.ip.sb/ip" 2>/dev/null || curl -4 -fsS -m 5 "https://api.ipify.org" 2>/dev/null || true)
    else
        ip_value=$(curl -6 -fsS -m 5 "https://api64.ipify.org" 2>/dev/null || curl -6 -fsS -m 5 "https://api6.ipify.org" 2>/dev/null || true)
    fi

    printf '%s' "$ip_value" | tr -d '[:space:]'
}

lookup_country_for_ip() {
    local raw_ip
    raw_ip=$(strip_brackets "$1")
    [ -n "$raw_ip" ] || return 0

    local country
    country=$(curl -fsS -m 5 "https://api.ip.sb/geoip/${raw_ip}" 2>/dev/null | jq -r '.country_code // .country // empty' 2>/dev/null | tr '[:lower:]' '[:upper:]')
    if [ -z "$country" ]; then
        country=$(curl -fsS -m 5 "https://ipinfo.io/${raw_ip}/country" 2>/dev/null | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
    fi

    printf '%s' "$country"
}

resolve_host_ip() {
    local hostname=$1

    if command -v getent >/dev/null 2>&1; then
        getent ahosts "$hostname" 2>/dev/null | awk 'NR == 1 { print $1; exit }'
        return 0
    fi

    if command -v host >/dev/null 2>&1; then
        host "$hostname" 2>/dev/null | awk '/has address|has IPv6 address/ { print $NF; exit }'
        return 0
    fi

    if command -v nslookup >/dev/null 2>&1; then
        nslookup "$hostname" 2>/dev/null | awk '/^Address: / { print $2; exit }'
    fi
}

expected_timezone_pattern() {
    case "$1" in
        US|CA|MX) printf '^America/' ;;
        GB|IE|DE|FR|NL|ES) printf '^Europe/' ;;
        AU) printf '^Australia/' ;;
        TR) printf '^(Europe|Asia)/' ;;
        HK|MO|TW|SG|JP|KR|TH|MY|VN|PH|KH|LA|MM|NP|BD|IN|AE|SA) printf '^Asia/' ;;
        *) printf '' ;;
    esac
}

array_to_json() {
    if [ "$#" -eq 0 ]; then
        printf '[]'
    else
        printf '%s\n' "$@" | jq -R . | jq -s .
    fi
}

TARGET_COUNTRY_CODE=$(normalize_country_code "${TARGET_COUNTRY:-${REGION_CODE%%-*}}")
TARGET_STATE_CODE="${TARGET_STATE:-}"
TARGET_CITY_CODE="${TARGET_CITY:-}"
EXPECTED_PUBLIC_IP=$(strip_brackets "${PUBLIC_IP:-}")
RAW_BIND_IP=$(strip_brackets "${BIND_IP:-}")
TARGET_TIMEZONE_PATTERN=$(expected_timezone_pattern "$TARGET_COUNTRY_CODE")

IPV4_PUBLIC=$(fetch_public_ip "ipv4")
IPV6_PUBLIC=$(fetch_public_ip "ipv6")
IPV4_COUNTRY=$(lookup_country_for_ip "$IPV4_PUBLIC")
IPV6_COUNTRY=$(lookup_country_for_ip "$IPV6_PUBLIC")

BIND_MATCH_JSON="null"
PUBLIC_MATCH_JSON="null"
STACK_MATCH_JSON="null"

if [ -n "$RAW_BIND_IP" ] && command -v ip >/dev/null 2>&1 && ! ip addr show 2>/dev/null | grep -qw "$RAW_BIND_IP"; then
    add_error "Configured BIND_IP is not present on local interfaces: ${RAW_BIND_IP}"
fi

if [ -n "$RAW_BIND_IP" ]; then
    BIND_MATCH_JSON="false"
    if { [[ "$RAW_BIND_IP" == *":"* ]] && [ "$IPV6_PUBLIC" = "$RAW_BIND_IP" ]; } || { [[ "$RAW_BIND_IP" == *"."* ]] && [ "$IPV4_PUBLIC" = "$RAW_BIND_IP" ]; }; then
        BIND_MATCH_JSON="true"
    else
        add_error "Configured BIND_IP does not match detected public IP for its stack."
    fi
fi

if [ -n "$EXPECTED_PUBLIC_IP" ]; then
    PUBLIC_MATCH_JSON="false"
    if [ "$IPV4_PUBLIC" = "$EXPECTED_PUBLIC_IP" ] || [ "$IPV6_PUBLIC" = "$EXPECTED_PUBLIC_IP" ]; then
        PUBLIC_MATCH_JSON="true"
    else
        add_error "Configured PUBLIC_IP does not match detected public IP."
    fi
fi

if [ -n "$IPV4_COUNTRY" ] && [ -n "$IPV6_COUNTRY" ]; then
    if [ "$IPV4_COUNTRY" = "$IPV6_COUNTRY" ]; then
        STACK_MATCH_JSON="true"
    else
        STACK_MATCH_JSON="false"
        add_error "IPv4 and IPv6 exit countries are inconsistent: ${IPV4_COUNTRY} vs ${IPV6_COUNTRY}."
    fi
fi

if [ -z "$IPV4_PUBLIC" ] && [ -z "$IPV6_PUBLIC" ]; then
    add_error "Unable to detect any public IP address."
fi

DNS_RESOLVER_IP=$(awk '/^nameserver[[:space:]]+/ { print $2; exit }' /etc/resolv.conf 2>/dev/null | tr -d '[:space:]')
DNS_RESOLVER_COUNTRY=""
DNS_RISK_JSON="false"

if [ -z "$DNS_RESOLVER_IP" ]; then
    add_error "No nameserver entry found in /etc/resolv.conf."
    DNS_RISK_JSON="true"
else
    DNS_RESOLVER_COUNTRY=$(lookup_country_for_ip "$DNS_RESOLVER_IP")
    if [ -n "$DNS_RESOLVER_COUNTRY" ] && [ -n "$TARGET_COUNTRY_CODE" ] && [ "$DNS_RESOLVER_COUNTRY" != "$TARGET_COUNTRY_CODE" ]; then
        add_error "DNS resolver country drift detected: expected ${TARGET_COUNTRY_CODE}, got ${DNS_RESOLVER_COUNTRY}."
        DNS_RISK_JSON="true"
    fi
fi

GOOGLE_RESOLVED_IP=$(resolve_host_ip "www.google.com")
YOUTUBE_RESOLVED_IP=$(resolve_host_ip "www.youtube.com")
GSTATIC_RESOLVED_IP=$(resolve_host_ip "connectivitycheck.gstatic.com")

GOOGLE_RESOLVED_JSON="true"
YOUTUBE_RESOLVED_JSON="true"
GSTATIC_RESOLVED_JSON="true"

if [ -z "$GOOGLE_RESOLVED_IP" ]; then
    GOOGLE_RESOLVED_JSON="false"
    DNS_RISK_JSON="true"
    add_error "Failed to resolve www.google.com."
fi

if [ -z "$YOUTUBE_RESOLVED_IP" ]; then
    YOUTUBE_RESOLVED_JSON="false"
    DNS_RISK_JSON="true"
    add_error "Failed to resolve www.youtube.com."
fi

if [ -z "$GSTATIC_RESOLVED_IP" ]; then
    GSTATIC_RESOLVED_JSON="false"
    DNS_RISK_JSON="true"
    add_error "Failed to resolve connectivitycheck.gstatic.com."
fi

CURRENT_TIMEZONE=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || readlink /etc/localtime 2>/dev/null | sed 's#^.*/zoneinfo/##')
TIMEZONE_MATCH_JSON="null"

if [ -n "$TARGET_TIMEZONE_PATTERN" ] && [ -n "$CURRENT_TIMEZONE" ]; then
    if printf '%s' "$CURRENT_TIMEZONE" | grep -Eq "$TARGET_TIMEZONE_PATTERN"; then
        TIMEZONE_MATCH_JSON="true"
    else
        TIMEZONE_MATCH_JSON="false"
        add_error "System timezone does not match target region pattern ${TARGET_TIMEZONE_PATTERN}: ${CURRENT_TIMEZONE}."
    fi
elif [ -z "$CURRENT_TIMEZONE" ]; then
    add_warning "Unable to determine current system timezone."
fi

TIME_SYNC_JSON="null"
if command -v timedatectl >/dev/null 2>&1; then
    NTP_SYNC=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)
    case "$NTP_SYNC" in
        yes)
            TIME_SYNC_JSON="true"
            ;;
        no)
            TIME_SYNC_JSON="false"
            add_error "System clock is not synchronized via NTP."
            ;;
        *)
            add_warning "Unable to verify NTP synchronization through timedatectl."
            ;;
    esac
elif command -v chronyc >/dev/null 2>&1; then
    if chronyc tracking 2>/dev/null | grep -qi 'Leap status.*Normal'; then
        TIME_SYNC_JSON="true"
    else
        TIME_SYNC_JSON="false"
        add_error "Chrony reports the system clock is not synchronized."
    fi
else
    add_warning "No supported NTP status command found."
fi

PROXY_DETECTED_JSON="false"
WARP_DETECTED_JSON="false"

if env | grep -Eiq '^(http|https|all|HTTP|HTTPS|ALL)_PROXY='; then
    PROXY_DETECTED_JSON="true"
    add_error "Proxy environment variables are set."
fi

if command -v ip >/dev/null 2>&1 && ip link show 2>/dev/null | grep -Eq '^[0-9]+: (tun|tap|wgcf|warp|wg)[^:]*:'; then
    PROXY_DETECTED_JSON="true"
    if ip link show 2>/dev/null | grep -Eq '^[0-9]+: (wgcf|warp)[^:]*:'; then
        WARP_DETECTED_JSON="true"
    fi
    add_error "Detected tun/wg style virtual interfaces that may alter egress routing."
fi

PROFILE_EXISTS_JSON="true"
PROFILE_WRITABLE_JSON="true"
if ! touch "${PROFILES_DIR}/.preflight-write-test" 2>/dev/null; then
    PROFILE_WRITABLE_JSON="false"
    add_error "Profile directory is not writable: ${PROFILES_DIR}"
else
    rm -f "${PROFILES_DIR}/.preflight-write-test"
fi

WARNINGS_JSON=$(array_to_json "${WARNINGS[@]}")
ERRORS_JSON=$(array_to_json "${ERRORS[@]}")

if [ "${#ERRORS[@]}" -gt 0 ]; then
    PREFLIGHT_OK_JSON="false"
    STATE_HINT="DNS_RISK"
else
    PREFLIGHT_OK_JSON="true"
    STATE_HINT="UNKNOWN"
fi

RESULT_JSON=$(jq -n \
    --argjson ok "$PREFLIGHT_OK_JSON" \
    --arg state_hint "$STATE_HINT" \
    --arg target_country "$TARGET_COUNTRY_CODE" \
    --arg target_state "$TARGET_STATE_CODE" \
    --arg target_city "$TARGET_CITY_CODE" \
    --arg region_name "${REGION_NAME:-}" \
    --arg expected_public_ip "$EXPECTED_PUBLIC_IP" \
    --arg bind_ip "$RAW_BIND_IP" \
    --arg ipv4 "$IPV4_PUBLIC" \
    --arg ipv6 "$IPV6_PUBLIC" \
    --arg ipv4_country "$IPV4_COUNTRY" \
    --arg ipv6_country "$IPV6_COUNTRY" \
    --argjson bind_ip_match "$BIND_MATCH_JSON" \
    --argjson public_ip_match "$PUBLIC_MATCH_JSON" \
    --argjson stack_match "$STACK_MATCH_JSON" \
    --arg resolver_ip "$DNS_RESOLVER_IP" \
    --arg resolver_country "$DNS_RESOLVER_COUNTRY" \
    --arg google_resolved_ip "$GOOGLE_RESOLVED_IP" \
    --arg youtube_resolved_ip "$YOUTUBE_RESOLVED_IP" \
    --arg gstatic_resolved_ip "$GSTATIC_RESOLVED_IP" \
    --argjson dns_risk "$DNS_RISK_JSON" \
    --argjson google_resolved "$GOOGLE_RESOLVED_JSON" \
    --argjson youtube_resolved "$YOUTUBE_RESOLVED_JSON" \
    --argjson gstatic_resolved "$GSTATIC_RESOLVED_JSON" \
    --arg timezone "$CURRENT_TIMEZONE" \
    --arg timezone_pattern "$TARGET_TIMEZONE_PATTERN" \
    --argjson timezone_match "$TIMEZONE_MATCH_JSON" \
    --argjson time_sync "$TIME_SYNC_JSON" \
    --argjson proxy_detected "$PROXY_DETECTED_JSON" \
    --argjson warp_detected "$WARP_DETECTED_JSON" \
    --arg profiles_dir "$PROFILES_DIR" \
    --argjson profiles_exists "$PROFILE_EXISTS_JSON" \
    --argjson profiles_writable "$PROFILE_WRITABLE_JSON" \
    --arg checked_at "$(utc_now_iso)" \
    --argjson warnings "$WARNINGS_JSON" \
    --argjson errors "$ERRORS_JSON" \
    '{
        ok: $ok,
        state_hint: $state_hint,
        checked_at: $checked_at,
        warnings: $warnings,
        errors: $errors,
        target: {
            country: $target_country,
            state: $target_state,
            city: $target_city,
            region_name: $region_name
        },
        ip: {
            expected_public_ip: $expected_public_ip,
            bind_ip: $bind_ip,
            ipv4: $ipv4,
            ipv6: $ipv6,
            ipv4_country: $ipv4_country,
            ipv6_country: $ipv6_country,
            bind_ip_match: $bind_ip_match,
            public_ip_match: $public_ip_match,
            stack_match: $stack_match
        },
        dns: {
            resolver_ip: $resolver_ip,
            resolver_country: $resolver_country,
            risk: $dns_risk,
            google_resolved: $google_resolved,
            google_resolved_ip: $google_resolved_ip,
            youtube_resolved: $youtube_resolved,
            youtube_resolved_ip: $youtube_resolved_ip,
            gstatic_resolved: $gstatic_resolved,
            gstatic_resolved_ip: $gstatic_resolved_ip
        },
        system: {
            timezone: $timezone,
            timezone_pattern: $timezone_pattern,
            timezone_match: $timezone_match,
            time_sync: $time_sync,
            proxy_detected: $proxy_detected,
            warp_detected: $warp_detected
        },
        profiles: {
            dir: $profiles_dir,
            exists: $profiles_exists,
            writable: $profiles_writable
        }
    }')

printf '%s\n' "$RESULT_JSON" > "$PREFLIGHT_STATE_FILE"
log_preflight "preflight ok=$(printf '%s' "$RESULT_JSON" | jq -r '.ok') state_hint=$(printf '%s' "$RESULT_JSON" | jq -r '.state_hint')"
printf '%s\n' "$RESULT_JSON"
