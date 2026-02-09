#!/bin/bash
set -o pipefail

bad=0

while read -r dev mr; do
    idx=${mr#megaraid,}

    out=$(smartctl -a -d megaraid,"$idx" "$dev" 2>/dev/null) || continue

    echo "$out" | grep -q "Device Model" || continue

    status="OK"

    echo "$out" | grep -q "SMART overall-health.*PASSED" || status="BAD"

    for attr in \
        Reallocated_Sector_Ct \
        Runtime_Bad_Block \
        Used_Rsvd_Blk_Cnt_Tot \
        Uncorrectable_Error_Cnt
    do
        val=$(echo "$out" | awk -v a="$attr" '$2==a {print $10}')
        [[ "$val" =~ ^[0-9]+$ && "$val" -gt 0 ]] && status="BAD"
    done

    echo "[$status] $dev megaraid,$idx"

    [[ "$status" == "BAD" ]] && bad=1
done < <(sudo smartctl --scan | awk '/megaraid/ {print $1, $NF}')

exit $bad
