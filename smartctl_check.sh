#!/bin/bash

bad=0
# Obtenemos la lista de discos desde smartctl --scan
devices=$(smartctl --scan | awk '/megaraid/ {for (i=1;i<=NF;i++) if ($i=="-d") print $1, $(i+1)}')

if [ -z "$devices" ]; then
    echo "[ERROR] No se detectaron discos MegaRAID."
    exit 1
fi

while read -r dev mr; do
    idx=${mr#megaraid,}
    
    # Obtenemos la info del disco
    out=$(smartctl -a -d megaraid,"$idx" "$dev" 2>/dev/null)
    
    # Si la salida está vacía, saltamos
    [[ -z "$out" ]] && continue

    # Intentamos determinar el modelo (Micron 5200 en tu caso)
    model=$(echo "$out" | grep -Ei "Device Model|Model Number|Vendor:" | awk -F: '{print $2}' | sed 's/^[ \t]*//')
    [[ -z "$model" ]] && model="Unknown Model"

    status="OK"

    # 1. Verificación de salud general (PASSED)
    if ! echo "$out" | grep -q "SMART overall-health.*PASSED"; then
        status="BAD"
    fi

    # 2. Verificación de atributos críticos (ajustado para SSD Micron)
    # Nota: Micron usa ID 5 y ID 180/187 para errores
    for attr in \
        Reallocated_Sector_Ct \
        Runtime_Bad_Block \
        Uncorrectable_Error_Cnt \
        Reported_Uncorrect
    do
        val=$(echo "$out" | grep "$attr" | awk '{print $10}')
        if [[ "$val" =~ ^[0-9]+$ && "$val" -gt 0 ]]; then
            status="BAD"
        fi
    done

    # IMPRESIÓN DEL RESULTADO (Lo que te faltaba)
    printf "[%-3s] %-12s ID:%-2s - %s\n" "$status" "$dev" "$idx" "$model"

    [[ "$status" == "BAD" ]] && bad=1

done <<< "$devices"

exit $bad
