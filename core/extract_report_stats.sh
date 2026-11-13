#!/usr/bin/env bash
# Extract report statistics from normalized sentinel log text on stdin.
# Usage: extract_report_stats.sh [YYYY-MM-DD]
# When a UTC date is supplied, records outside that UTC day are ignored.
# Output: google_total google_ended google_success google_failed google_warn google_abort \
#         trust_total trust_ended trust_success trust_failed
set -euo pipefail

UTC_DATE="${1:-}"
if [[ -n "$UTC_DATE" && ! "$UTC_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    echo "invalid report date: $UTC_DATE" >&2
    exit 2
fi

awk -v utc_date="$UTC_DATE" '
    {
        # BWKN awk fails to compare a field ending with "]" to a dynamically
        # built bracketed string, so compare the bracket-wrapped date parts.
        if (utc_date != "" && \
            (substr($1, 1, 1) != "[" || \
             substr($1, 2, length(utc_date)) != utc_date)) next
    }
    function canonical(value) {
        gsub(/[[:space:]\[\]]/, "", value)
        return value
    }
    $5 == "[START]" {
        module = canonical($6)
        if (module != "Google" && module != "Trust") next
        total[module]++
    }
    $5 == "[SCORE]" {
        module = canonical($6)
        if (module != "Google" && module != "Trust") next
        # A SCORE event is the authoritative end-of-round marker. Counting it
        # directly avoids matching start/score timestamps and incomplete rounds.
        ended[module]++
        if (index($0, "✅")) success[module]++
        if (index($0, "❌")) failed[module]++
        if (index($0, "⚠️")) warned[module]++
        if (index($0, "🚨")) aborted[module]++
    }
    END {
        print total["Google"] + 0, ended["Google"] + 0, \
              success["Google"] + 0, failed["Google"] + 0, \
              warned["Google"] + 0, aborted["Google"] + 0, \
              total["Trust"] + 0, ended["Trust"] + 0, \
              success["Trust"] + 0, failed["Trust"] + 0
    }
'
