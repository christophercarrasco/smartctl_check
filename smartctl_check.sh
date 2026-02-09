#!/bin/bash

# =========================
# STORAGE HEALTH AUDIT
# SAP / HANA STRICT MODE
# =========================

LIFE_THRESHOLD=10
WARN_CRC_THRESHOLD=1

bad_count=0
warn_count=0
critical_disks=()
total_disks=0
report_data=""

# Detectamos todos los dispositivos megaraid
devices=$(smartctl --scan | awk '/megaraid/ {for (i=1;i<=NF;i++) if ($i=="-d") print $1, $(i+1)}')

echo "--- STORAGE HEALTH SYSTEM AUDIT (STRICT MODE) ---"
printf "%-10s %-8s %-6s %-10s %-6s %-7s %-6s %-6s %-20s %-25s\n" \
"STATUS" "ID" "LIFE%" "HOURS" "CRC" "REALLOC" "PWR" "TEMP" "MODEL" "SERIAL"
echo "----------------------------------------------------------------------------------------------------"

while read -r dev mr; do
    idx=${mr#megaraid,}
    ((total_disks++))

    out=$(smartctl -a -d megaraid,"$idx" "$dev" 2>/dev/null)
    [[ -z "$out" ]] && continue

    model=$(echo "$out" | grep -Ei "Device Model|Model Number" | awk -F: '{print $2}' | xargs)
    serial=$(echo "$out" | grep -Ei "Serial Number|Serial No." | awk -F: '{print $2}' | xargs)
    [[ -z "$serial" ]] && serial="UNKNOWN"

    # Horas encendido (ID 9)
    hours=$(echo "$out" | grep -E "^\s*9\s+" | awk '{print $10}')

    # =========================================
    # Lógica Específica por Fabricante (Vida y TBW)
    # =========================================
    if [[ "$model" == *"SAMSUNG"* ]]; then
        raw_life=$(echo "$out" | grep -E "^\s*177\s+" | awk '{print $4}')
        tbw_raw=$(echo "$out" | grep -E "^\s*241\s+" | awk '{print $10}')
    elif [[ "$model" == *"TOSHIBA"* || "$model" == *"KHK61"* ]]; then
        raw_life=$(echo "$out" | grep -E "^\s*233\s+" | awk '{print $4}')
        tbw_raw=$(echo "$out" | grep -E "^\s*241\s+" | awk '{print $10}')
    else
        raw_life=$(echo "$out" | grep -E "^\s*202\s+" | awk '{print $10}')
        tbw_raw=$(echo "$out" | grep -E "^\s*246\s+" | awk '{print $10}')
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

    # Nivel crítico: LIFE bajo o REALLOC > 0
    if (( 10#$life <= LIFE_THRESHOLD )) || (( realloc > 0 )); then
        status="CRITICAL"
        flags+="LOW_LIFE/REALLOC "
        critical_disks+=("ID:$idx ($model $serial)")
    elif (( media_err > 0 )); then
        status="FAIL"
        flags+="MEDIA_ERR "
    elif (( unsafe_pwr > 0 )); then
        status="WARN"
        flags+="UNSAFE_PWR "
    elif (( crc_err >= WARN_CRC_THRESHOLD )); then
        status="WARN"
        flags+="CRC_WARN "
    fi

    # Contadores
    case "$status" in
        CRITICAL|FAIL) ((bad_count++)) ;;
        WARN) ((warn_count++)) ;;
    esac

    # Colores
    case "$status" in
        OK) color="\033[0;32m" ;;
        WARN) color="\033[0;33m" ;;
        FAIL) color="\033[0;31m" ;;
        CRITICAL) color="\033[1;41m" ;; # rojo con fondo para resaltar
    esac

    # Output humano
    printf "${color}%-10s\033[0m %-8s %-6s %-10s %-6s %-7s %-6s %-6s %-20s %-25s\n" \
        "[$status]" "ID:$idx" "${life}%" "$hours" "$crc_err" "$realloc" "$unsafe_pwr" "${temp}C" "$model" "$serial"

    # JSON machine-readable
    report_data+="{\"id\":$idx,\"model\":\"$model\",\"serial\":\"$serial\",\"status\":\"$status\",\"life\":$life,\
\"hours\":$hours,\"crc\":$crc_err,\"realloc\":$realloc,\
\"media_err\":$media_err,\"unsafe_pwr\":$unsafe_pwr,\
\"temp\":$temp,\"tbw_tb\":$tbw_tb},"

done <<< "$devices"

echo -e "\n--- MACHINE READABLE SUMMARY ---"
echo -e "JSON_DATA: [${report_data%,}]"
echo -e "AUDIT_SCORE: $((total_disks - bad_count))/$total_disks HEALTHY"
echo -e "WARNINGS: $warn_count"

# =========================
# Resumen de discos críticos
# =========================
if [ ${#critical_disks[@]} -gt 0 ]; then
    echo -e "\n--- CRITICAL DISKS (REQUIRES IMMEDIATE REPLACEMENT) ---"
    for d in "${critical_disks[@]}"; do
        echo "- $d"
    done
fi
