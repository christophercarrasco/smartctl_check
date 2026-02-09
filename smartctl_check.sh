#!/bin/bash

bad_count=0
total_disks=0
summary=""

# Obtener dispositivos
devices=$(smartctl --scan | awk '/megaraid/ {for (i=1;i<=NF;i++) if ($i=="-d") print $1, $(i+1)}')

echo "--- INICIANDO ESCANEO DE DISCOS ---"

while read -r dev mr; do
    idx=${mr#megaraid,}
    ((total_disks++))
    
    out=$(smartctl -a -d megaraid," $idx" "$dev" 2>/dev/null)
    [[ -z "$out" ]] && continue

    model=$(echo "$out" | grep -Ei "Device Model|Model Number|Vendor:" | head -1 | awk -F: '{print $2}' | sed 's/^[ \t]*//')
    
    status="OK"
    reasons=""

    # 1. Chequeo de Salud General
    if ! echo "$out" | grep -q "SMART overall-health.*PASSED"; then
        status="BAD"
        reasons+="[Salud General Fallida] "
    fi

    # 2. Chequeo de Atributos Críticos
    # Definimos los IDs y Nombres que Micron usa para fallos
    for attr in "Reallocated_Sector_Ct" "Reported_Uncorrect" "Command_Timeout" "Runtime_Bad_Block"; do
        val=$(echo "$out" | grep "$attr" | awk '{print $10}')
        if [[ "$val" =~ ^[0-9]+$ && "$val" -gt 0 ]]; then
            status="BAD"
            reasons+="[$attr: $val] "
        fi
    done

    # Imprimir resultado inmediato
    if [ "$status" == "BAD" ]; then
        echo -e "[\e[31mBAD\e[0m] $dev ID:$idx - $model"
        echo -e "      \e[33mMotivo:\e[0m $reasons"
        ((bad_count++))
        summary+=" - Disco ID $idx ($model): $reasons\n"
    else
        echo -e "[\e[32mOK \e[0m] $dev ID:$idx - $model"
    fi

done <<< "$devices"

# --- RESUMEN FINAL ---
echo -e "\n-------------------------------------------"
echo "RESUMEN DE ESTADO DE HARDWARE"
echo "-------------------------------------------"
echo "Discos Totales: $total_disks"
echo "Discos Sanos:   $((total_disks - bad_count))"
echo "Discos Críticos: $bad_count"

if [ "$bad_count" -gt 0 ]; then
    echo -e "\nDETALLE DE FALLOS:"
    echo -e "$summary"
    echo "ACCION RECOMENDADA: Revisar logs de la controladora MegaRAID y planificar reemplazo."
else
    echo -e "\nTodo parece estar en orden."
fi

exit $bad_count
