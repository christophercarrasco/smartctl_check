#!/bin/bash

bad=0
DEV=/dev/sda     # wrapper MegaRAID
MAX=32           # ajusta si tienes más discos

for i in $(seq 0 $MAX); do
    out=$(smartctl -a -d megaraid,$i $DEV 2>/dev/null) || continue

    # validar que sea un disco real
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

    echo "[$status] $DEV megaraid,$i"

    [[ "$status" == "BAD" ]] && bad=1
done

exit $bad
