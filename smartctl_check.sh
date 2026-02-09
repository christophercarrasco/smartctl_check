#!/bin/bash

# =========================
# STORAGE HEALTH AUDIT
# SAP / HANA STRICT MODE
# =========================

LIFE_THRESHOLD=10
WARN_CRC_THRESHOLD=1

bad_count=0
warn_count=0
total_disks=0
report_data=""

# Detectamos todos los dispositivos megaraid
devices=$(smartctl --scan | awk '/megaraid/ {for (i=1;i<=NF;i++) if ($i=="-d") print $1, $(i+1)}')

echo "--- STORAGE HEALTH SYSTEM AUDIT (STRICT MODE) ---"
printf "%-10s %-8s %-6s %-10s %-6s %-7s %-6s %-6s %-15s\n" \
"STATUS" "ID" "LIFE%" "HOURS" "CRC" "REALLOC" "PWR" "TEMP" "MODEL"
echo "---------------------------------------------------------------------------------------------"

while read -r dev mr; do
    idx=${mr#megaraid,}
    ((total_disks++))

    out=$(smartctl -a -d megaraid,"$idx" "$dev" 2>/dev/null)
    [[ -z "$out" ]] && continue

    model=$(echo "$out" | grep -Ei "Device Model|Model Number" | awk -F: '{print $2}' | xargs)

    # Horas encendido (ID 9)
    hours=$(echo "$out" | grep -E "^\s*9\s+" | awk '{print $10}')

    # Vida útil
    if [[ "$model" == *"SAMSUNG"* ]]; then
        raw_life=$(echo "$out" | grep -E "^\s*177\s+" | awk '{print $4}')
    else
        raw_life=$(echo "$out" | grep -E "^\s*202\s+" | awk '{print $10}')
    fi
    life=$(echo "$raw_life" | sed 's/^0*//')
    [[ -z "$life" ]] && life=100

    # Errores básicos
    crc_err=$(echo "$out" | grep -E "^\s*199\s+" | awk '{print $10}')
    realloc=$(echo "$out" | grep -E "^\s*5\s+" | awk '{print $10}')

    # Media / Data integrity
    media_err=$(echo "$out" | grep -Ei "Media and Data Integrity Errors" | awk '{print $NF}')

    # Unsafe shutdowns
    unsafe_pwr=$(echo "$out" | grep -Ei "Unsafe_Shutdowns|Unsafe Shutdowns" | awk '{print $NF}')

    # Temperatura
    temp=$(echo "$out" | grep -Ei "Temperature_Celsius" | awk '{print $10}')

    # Total Writes / TBW
    tbw_raw=$(echo "$out" | grep -Ei "Total_LBAs_Written|Host_Writes|Data_Units_Written" | awk '{print $10}' | head -n1)

    # TBW específico Micron 5200 (atributo 246)
    if [[ "$model" == *"Micron"* ]]; then
        tbw_raw=$(echo "$out" | grep -E "^\s*246\s+" | awk '{print $10}')
    fi

    # Sanitización
    [[ ! "$hours" =~ ^[0-9]+$ ]] && hours=0
    [[ ! "$crc_err" =~ ^[0-9]+$ ]] && crc_err=0
    [[ ! "$realloc" =~ ^[0-9]+$ ]] && realloc=0
    [[ ! "$media_err" =~ ^[0-9]+$ ]] && media_err=0
    [[ ! "$unsafe_pwr" =~ ^[0-9]+$ ]] && unsafe_pwr=0
    [[ ! "$temp" =~ ^[0-9]+$ ]] && temp=0
    [[ ! "$tbw_raw" =~ ^[0-9]+$ ]] && tbw_raw=0

    # Conversión aproximada a TB (suponiendo 512B por unidad)
    tbw_tb=$(( tbw_raw * 512 / 1024 / 1024 / 1024 / 1024 ))

    # =========================
    # LÓGICA DE ESTADO
    # =========================

    status="OK"
    flags=""

    if (( 10#$life <= LIFE_THRESHOLD )); then
        status="FAIL"; flags+="LOW_LIFE "
    fi

    if (( realloc > 0 )); then
        status="FAIL"; flags+="REALLOC "
    fi

    if (( media_err > 0 )); then
        status="FAIL"; flags+="MEDIA_ERR "
    fi

    if (( unsafe_pwr > 0 )) && [ "$status" == "OK" ]; then
        status="WARN"; flags+="UNSAFE_PWR "
    fi

    if (( crc_err >= WARN_CRC_THRESHOLD )) && [ "$status" == "OK" ]; then
        status="WARN"; flags+="CRC_WARN "
    fi

    # Contadores
    if [ "$status" == "FAIL" ]; then
        ((bad_count++))
    elif [ "$status" == "WARN" ]; then
        ((warn_count++))
    fi

    # Colores
    case "$status" in
        OK)   color="\033[0;32m" ;;
        WARN) color="\033[0;33m" ;;
        FAIL) color="\033[0;31m" ;;
    esac

    # Output humano
    printf "${color}%-10s\033[0m %-8s %-6s %-10s %-6s %-7s %-6s %-6s %-15s\n" \
        "[$status]" "ID:$idx" "${life}%" "$hours" "$crc_err" "$realloc" "$unsafe_pwr" "${temp}C" "$model"

    # JSON machine-readable
    report_data+="{\"id\":$idx,\"model\":\"$model\",\"status\":\"$status\",\"life\":$life,\
\"hours\":$hours,\"crc\":$crc_err,\"realloc\":$realloc,\
\"media_err\":$media_err,\"unsafe_pwr\":$unsafe_pwr,\
\"temp\":$temp,\"tbw_tb\":$tbw_tb},"

done <<< "$devices"

echo -e "\n--- MACHINE READABLE SUMMARY ---"
echo -e "JSON_DATA: [${report_data%,}]"
echo -e "AUDIT_SCORE: $((total_disks - bad_count))/$total_disks HEALTHY"
echo -e "WARNINGS: $warn_count"
