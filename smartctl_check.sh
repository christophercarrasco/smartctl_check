#!/bin/bash

set -o pipefail

smartctl --scan | awk '/megaraid/ {print $1, $NF}' | while read dev mr; do
    idx=${mr#megaraid,}

    out=$(smartctl -a -d megaraid,$idx "$dev" 2>/dev/null)

    status="OK"

    echo "$out" | grep -q "SMART overall-health self-assessment test result: PASSED" || status="BAD"

    for attr in \
        Reallocated_Sector_Ct \
        Runtime_Bad_Block \
        Used_Rsvd_Blk_Cnt_Tot \
        Uncorrectable_Error_Cnt
    do
        val=$(echo "$out" | awk -v a="$attr" '$2==a {print $10}')
        [[ -n "$val" && "$val" -gt 0 ]] && status="BAD"
    done

    echo "[$status] $dev megaraid,$idx"
done
