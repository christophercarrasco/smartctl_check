smartctl --scan | awk '
/-d megaraid,[0-9]+/ {
  for (i=1;i<=NF;i++) {
    if ($i=="-d") dev=$(i-1)
    if ($i ~ /^megaraid,[0-9]+$/) mr=$i
  }
  print dev, mr
}' | while read dev mr; do
    idx=${mr#megaraid,}

    out=$(smartctl -a -d megaraid,$idx "$dev" 2>/dev/null) || continue

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
done
