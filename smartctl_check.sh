#!/bin/bash
set -o pipefail

bad=0

smartctl --scan | awk '
/megaraid/ {
  for (i=1;i<=NF;i++) {
    if ($i=="-d") print $1, $(i+1)
  }
}' | while read -r dev mr; do
    idx=${mr#megaraid,}

    out=$(smartctl -a -d megaraid,"$idx" "$dev" 2>/dev/null) || continue

    # Validar que sea un disco real detrás del RAID
    echo "$out" | grep -q "START OF INFORMATION SECTION" || continue

    status="OK"

    # MegaRAID puede reportar distinto
    echo "$out" | grep -Eq \
        "SMART overall-health.*PASSED|SMART Health Status: OK" \
        || status="BAD"

    for attr in \
        Reallocated_Sector_Ct \
        Current_Pending_Sector \
        Offline_Uncorrectable \
        Media_Wearout_Indicator \
        Percent_Lifetime_Remain
    do
        val=$(echo "$out" | awk -v a="$attr" '$2==a {print $NF}')
        [[ "$val" =~ ^[0-9]+$ && "$val" -gt 0 ]] && status="BAD"
    done

    echo "[$status] $dev megaraid,$idx"

    [[ "$status" == "BAD" ]] && bad=1
done

exit $bad
