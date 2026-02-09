#!/bin/bash
set -o pipefail

bad=0

while read dev mr; do
    idx=${mr#megaraid,}

    out=$(sudo smartctl -a -d megaraid,$idx "$dev" 2>/dev/null) || continue

    echo "$out" | grep -Eq "Device Model|Model Number" || continue

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
done < <(
    smartctl --scan | awk '
    /megaraid/ {
      for (i=1;i<=NF;i++) {
        if ($i=="-d") print $1, $(i+1)
      }
    }'
)

exit $bad
