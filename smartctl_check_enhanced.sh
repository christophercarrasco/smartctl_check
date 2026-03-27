#!/bin/bash
# Enhanced smartctl check script with StorCLI integration for slot identification

# =========================
# CONFIGURATION
# =========================
LIFE_THRESHOLD=10 # Legacy fallback
LIFE_CRITICAL=20
LIFE_WARN=60
REALLOC_CRITICAL=5
REALLOC_WARN=1
WARN_CRC_THRESHOLD=1
STORCLI_URL="https://download.lenovo.com/servers/mig/2025/03/26/62030/lnvgy_utl_raid_mr3.storcli-007.3007.0000.0000-2_linux_x86-64-cfc.tgz"
# Detect StorCLI binary location (check multiple paths)
if [[ -x "/opt/MegaRAID/storcli/storcli64" ]]; then
    STORCLI_BIN="/opt/MegaRAID/storcli/storcli64"
elif [[ -x "/usr/local/bin/storcli" ]]; then
    STORCLI_BIN="/usr/local/bin/storcli"
elif [[ -x "/usr/sbin/storcli" ]]; then
    STORCLI_BIN="/usr/sbin/storcli"
else
    STORCLI_BIN="/opt/MegaRAID/storcli/storcli64"  # default fallback
fi

bad_count=0
warn_count=0
critical_disks=()
total_disks=0
report_data=""

# =========================
# StorCLI Functions
# =========================

# Download and install StorCLI if not present
install_storcli() {
    # Check if already installed (STORCLI_BIN was resolved at startup)
    if [[ -x "$STORCLI_BIN" ]]; then
        return 0
    fi
    
    echo "[INFO] StorCLI not found, downloading and installing..." >&2
    
    local tmpdir="/tmp/storcli_install_$$"
    mkdir -p "$tmpdir"
    cd "$tmpdir" || return 1
    
    # Download
    if ! curl -fsSL "$STORCLI_URL" -o storcli.tgz 2>/dev/null; then
        echo "[WARN] Failed to download StorCLI, continuing without slot info" >&2
        rm -rf "$tmpdir"
        return 1
    fi
    
    # Extract
    tar -xzf storcli.tgz 2>/dev/null || { rm -rf "$tmpdir"; return 1; }
    
    # Find and install RPM
    local rpm_file=$(find . -name "*.rpm" -type f | head -1)
    if [[ -z "$rpm_file" ]]; then
        echo "[WARN] No RPM found in StorCLI package" >&2
        rm -rf "$tmpdir"
        return 1
    fi
    
    # Install RPM (suppress output)
    rpm -Uvh --force "$rpm_file" >/dev/null 2>&1
    
    # Cleanup
    cd /
    rm -rf "$tmpdir"
    
    if [[ -x "$STORCLI_BIN" ]]; then
        echo "[INFO] StorCLI installed successfully" >&2
        return 0
    else
        echo "[WARN] StorCLI installation failed" >&2
        return 1
    fi
}

# Get disk slot by serial number using StorCLI
get_disk_slot() {
    local serial="$1"
    
    # If StorCLI not available, return N/A
    if [[ ! -x "$STORCLI_BIN" ]]; then
        echo "N/A"
        return
    fi
    
    # Try to get slot information from StorCLI
    local storcli_output=$("$STORCLI_BIN" /c0 /eall /sall show all 2>/dev/null)
    
    if [[ -z "$storcli_output" ]]; then
        echo "N/A"
        return
    fi
    
    # Try multiple patterns to find the serial number and slot
    # Pattern 1: Look for "SN = <serial>" or "SN: <serial>"
    local slot=$(echo "$storcli_output" | grep -B10 -E "(SN =|SN:) $serial" | grep -oE "/c[0-9]+/e[0-9]+/s[0-9]+" | head -1)
    
    # Pattern 2: If not found, try looking for serial without prefix
    if [[ -z "$slot" ]]; then
        slot=$(echo "$storcli_output" | grep -B10 "$serial" | grep -oE "/c[0-9]+/e[0-9]+/s[0-9]+" | head -1)
    fi
    
    # Pattern 3: Try looking for Drive ID format (DID) with serial
    if [[ -z "$slot" ]]; then
        # Some StorCLI versions show: EID:Slt DID State ...
        # Find the line with serial, then look for EID:Slt pattern
        local eid_slt=$(echo "$storcli_output" | grep "$serial" | grep -oE "[0-9]+:[0-9]+" | head -1)
        if [[ -n "$eid_slt" ]]; then
            echo "$eid_slt"
            return
        fi
    fi
    
    if [[ -n "$slot" ]]; then
        # Simplify format: /c0/e252/s0 -> 252:0
        local enclosure=$(echo "$slot" | grep -oE "e[0-9]+" | sed 's/e//')
        local slot_num=$(echo "$slot" | grep -oE "s[0-9]+" | sed 's/s//')
        echo "${enclosure}:${slot_num}"
    else
        echo "N/A"
    fi
}

# =========================
# Install StorCLI before scanning disks
# =========================
install_storcli

# Check arguments
SHOW_JSON=false
INCLUDE_SUMMARY=false
ENDURANCE_WARN_THRESHOLD=20

for arg in "$@"; do
    case "$arg" in
        --json) SHOW_JSON=true ;;
        --include-json-summary) INCLUDE_SUMMARY=true ;;
        --endurance-warn=*) ENDURANCE_WARN_THRESHOLD="${arg#--endurance-warn=}" ;;
    esac
done

# =========================
# RAID group health (virtual drives + rebuild status)
# =========================
raid_groups_json="[]"
rebuilding_json="[]"

if [[ -x "$STORCLI_BIN" ]]; then
    _rg=""
    _rb=""

    # --- Virtual drives (RAID groups) ---
    # Try JSON first; columns: DG/VD TYPE State Size
    vd_out=$("$STORCLI_BIN" /c0/vAll show J 2>/dev/null)
    while IFS=$'\t' read -r _vd _type _state _size; do
        [[ -z "$_vd" ]] && continue
        case "$_state" in
            Optl)      _vd_status="OK"       ;;
            Pdgd)      _vd_status="WARN"     ;;
            Dgrd|Offl) _vd_status="CRITICAL" ;;
            *)         _vd_status="UNKNOWN"  ;;
        esac
        _vd="${_vd//\"/\\\"}"; _type="${_type//\"/\\\"}"; _size="${_size//\"/\\\"}"
        _rg+="{\"vd\":\"$_vd\",\"type\":\"$_type\",\"state\":\"$_state\",\"size\":\"$_size\",\"status\":\"$_vd_status\"},"
    done < <(echo "$vd_out" | jq -r '
        try (.Controllers[0]["Response Data"]["VD LIST"]
             // .Controllers[0]["Response Data"]["Virtual Drives"])[]? |
        [.["DG/VD"] // .["DG\/VD"], .TYPE, .State, .Size] | @tsv
    ' 2>/dev/null)

    # Text fallback if JSON yielded nothing
    # StorCLI text columns (fixed): $1=DG/VD $2=TYPE $3=State $4=Access $5=Consist
    #   $6=Cache $7=Cac $8=sCC $9=Size_num $10=Size_unit [$11=Name]
    if [[ -z "$_rg" ]]; then
        vd_text=$("$STORCLI_BIN" /c0/vAll show 2>/dev/null)
        while IFS= read -r line; do
            [[ "$line" =~ ^[[:space:]]*([0-9]+/[0-9]+)[[:space:]]+([A-Za-z0-9]+)[[:space:]]+([A-Za-z]+) ]] || continue
            _vd="${BASH_REMATCH[1]}" _type="${BASH_REMATCH[2]}" _state="${BASH_REMATCH[3]}"
            _size=$(echo "$line" | awk '{print $9" "$10}')
            case "$_state" in
                Optl)      _vd_status="OK"       ;;
                Pdgd)      _vd_status="WARN"     ;;
                Dgrd|Offl) _vd_status="CRITICAL" ;;
                *)         _vd_status="UNKNOWN"  ;;
            esac
            _vd="${_vd//\"/\\\"}"; _type="${_type//\"/\\\"}"; _size="${_size//\"/\\\"}"
            _rg+="{\"vd\":\"$_vd\",\"type\":\"$_type\",\"state\":\"$_state\",\"size\":\"$_size\",\"status\":\"$_vd_status\"},"
        done <<< "$vd_text"
    fi

    # --- Physical drives — detect rebuilding ---
    # Use /c0/eall/sall show rebuild (one call, all drives).
    # Format: /c0/e252/s3  25  In progress  1 Hours 26 Minutes
    pd_out=$("$STORCLI_BIN" /c0/eall/sall show J 2>/dev/null)
    _rbld_all=$("$STORCLI_BIN" /c0/eall/sall show rebuild 2>/dev/null)
    while IFS= read -r line; do
        # Match lines with a numeric Progress% (skip "-" = not rebuilding)
        [[ "$line" =~ ^/c[0-9]+/e([0-9]+)/s([0-9]+)[[:space:]]+([0-9]+)[[:space:]]+In[[:space:]]+progress ]] || continue
        _enc="${BASH_REMATCH[1]}"; _slt="${BASH_REMATCH[2]}"; _pct="${BASH_REMATCH[3]}"
        _slot="${_enc}:${_slt}"
        _eta=$(echo "$line" | awk '{for(i=5;i<=NF;i++) printf $i" "; print ""}' | xargs)
        # Get model and DG from PD JSON (already queried)
        _model=$(echo "$pd_out" | jq -r --arg s "$_slot" '
            try .Controllers[0]["Response Data"] | to_entries[] |
            select(.key | startswith("Drive")) |
            .value[] | select(.["EID:Slt"] == $s) | .Model // "-"
        ' 2>/dev/null | head -1)
        _dg=$(echo "$pd_out" | jq -r --arg s "$_slot" '
            try .Controllers[0]["Response Data"] | to_entries[] |
            select(.key | startswith("Drive")) |
            .value[] | select(.["EID:Slt"] == $s) | (.DG // "-" | tostring)
        ' 2>/dev/null | head -1)
        [[ -z "$_model" || "$_model" == "null" ]] && _model="-"
        [[ -z "$_dg"    || "$_dg"    == "null" ]] && _dg="-"
        _model="${_model//\"/\\\"}"; _dg="${_dg//\"/\\\"}"; _eta="${_eta//\"/\\\"}"
        _rb+="{\"slot\":\"$_slot\",\"model\":\"$_model\",\"dg\":\"$_dg\",\"pct\":\"${_pct}\",\"eta\":\"${_eta}\"},"
    done <<< "$_rbld_all"

    [[ -n "$_rg" ]] && raid_groups_json="[${_rg%,}]"
    [[ -n "$_rb" ]] && rebuilding_json="[${_rb%,}]"
fi

# =========================
# Detectamos todos los dispositivos megaraid
# =========================
devices=$(smartctl --scan | awk '/megaraid/ {for (i=1;i<=NF;i++) if ($i=="-d") print $1","$(i+1)}')

if [[ "$SHOW_JSON" != "true" ]]; then
    echo "--- STORAGE HEALTH AUDIT ---"
    printf "%-12s %-6s %-8s %-8s %-6s %-8s %-10s %-11s %-5s %-9s %-7s %-6s %-25s\n" \
        "STATUS" "ID" "SLOT" "HEALTH" "LIFE%" "HOURS" "CRC" "REP_UNCORR" "E2E" "PENDING" "UNCORR" "TEMP" "MODEL"
    echo "---------------------------------------------------------------------------------------------------------------------------------------"
fi

# Using for loop to avail subshell issue
IFS=$'\n'
for device_entry in $devices; do
    if [[ -z "$device_entry" ]]; then continue; fi
    
    # device_entry format: /dev/bus,megaraid,N
    dev=$(echo "$device_entry" | cut -d',' -f1)
    # The rest is the device type and ID
    mr_part=$(echo "$device_entry" | cut -d',' -f2,3)
    # mr variable expected by logic (megaraid,N)
    mr="$mr_part"
    
    idx=${mr#megaraid,}
    ((total_disks++))

    # Capture both stdout and stderr to detect read failures
    out=$(smartctl -a -d megaraid,"$idx" "$dev" 2>&1)
    exit_code=$?

    # Check if smartctl failed to read the device (empty output or INQUIRY failed)
    if [[ -z "$out" ]] || echo "$out" | grep -qiE "INQUIRY failed|open device.*failed|Unable to detect device type"; then
        # Report the unreadable disk instead of silently skipping it
        if [[ "$SHOW_JSON" != "true" ]]; then
            printf "\033[0;33m%-12s\033[0m %-8s %-8s %-6s %-8s %-10s %-11s %-5s %-9s %-7s %-6s %-22s %-25s\n" \
                "[UNREAD]" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "UNKNOWN" "UNREADABLE DEVICE"
        fi
        report_data+="{\"id\":$idx,\"model\":\"\",\"serial\":\"UNKNOWN\",\"status\":\"UNREADABLE\",\
\"health\":\"N/A\",\"life\":0,\"wear_worst\":0,\
\"hours\":0,\"crc\":0,\"realloc\":0,\"realloc_value\":0,\"realloc_thresh\":0,\
\"pending\":0,\"uncorrectable\":0,\"reported_uncorr\":0,\
\"e2e_err\":0,\"reservd_value\":0,\"reservd_thresh\":0,\
\"media_err\":0,\"unsafe_pwr\":0,\
\"temp\":0,\"tbw_tb\":0,\"slot\":\"N/A\",\"flags\":\"INQUIRY_FAILED\"},"
        continue
    fi

    model=$(echo "$out" | grep -Ei "Device Model|Model Number" | awk -F: '{print $2}' | xargs)
    serial=$(echo "$out" | grep -Ei "Serial Number|Serial No." | awk -F: '{print $2}' | xargs)
    [[ -z "$serial" ]] && serial="UNKNOWN"

    # Horas encendido (ID 9)
    hours=$(echo "$out" | grep -E "^\s*9\s+" | awk '{print $10}')

    # SMART overall health self-assessment (universal, más autoritativo)
    health=$(echo "$out" | grep -i "SMART overall-health self-assessment test result" | awk '{print $NF}')
    # Fallback para SAS/NVMe que usan distinta etiqueta
    [[ -z "$health" ]] && health=$(echo "$out" | grep -i "SMART Health Status" | awk '{print $NF}')

    # =========================================
    # Endurance: VALUE y THRESH — cadena de fallback por fabricante
    #   177 Wear_Leveling_Count  → Samsung, SK Hynix, WD
    #   233 Media_Wearout_Indicator → Intel, Toshiba, Micron (algunos)
    #   231 SSD_Life_Left        → Kingston, Corsair
    #   202 Percent_Lifetime_Rem → Micron MTFD*, Seagate Nytro
    #   173 Wear_Leveling_Count  → Kioxia/Toshiba enterprise
    # Si ninguno existe (HDD u otro): life=100, wear_thresh=0 → checks skipped
    # =========================================
    wear_value=$(echo "$out" | grep -E "^\s*177\s+" | awk '{print $4}')
    wear_thresh=$(echo "$out" | grep -E "^\s*177\s+" | awk '{print $6}')
    wear_worst=$(echo "$out" | grep -E "^\s*177\s+" | awk '{print $5}')
    if [[ -z "$wear_value" || "$wear_value" == "0" ]]; then
        wear_value=$(echo "$out" | grep -E "^\s*233\s+" | awk '{print $4}')
        wear_thresh=$(echo "$out" | grep -E "^\s*233\s+" | awk '{print $6}')
        wear_worst=$(echo "$out" | grep -E "^\s*233\s+" | awk '{print $5}')
    fi
    if [[ -z "$wear_value" || "$wear_value" == "0" ]]; then
        wear_value=$(echo "$out" | grep -E "^\s*231\s+" | awk '{print $4}')
        wear_thresh=$(echo "$out" | grep -E "^\s*231\s+" | awk '{print $6}')
        wear_worst=$(echo "$out" | grep -E "^\s*231\s+" | awk '{print $5}')
    fi
    if [[ -z "$wear_value" || "$wear_value" == "0" ]]; then
        wear_value=$(echo "$out" | grep -E "^\s*202\s+" | awk '{print $4}')
        wear_thresh=$(echo "$out" | grep -E "^\s*202\s+" | awk '{print $6}')
        wear_worst=$(echo "$out" | grep -E "^\s*202\s+" | awk '{print $5}')
    fi
    if [[ -z "$wear_value" || "$wear_value" == "0" ]]; then
        wear_value=$(echo "$out" | grep -E "^\s*173\s+" | awk '{print $4}')
        wear_thresh=$(echo "$out" | grep -E "^\s*173\s+" | awk '{print $6}')
        wear_worst=$(echo "$out" | grep -E "^\s*173\s+" | awk '{print $5}')
    fi
    # Último recurso NVMe: Percentage Used Endurance Indicator (invertir: usado→restante)
    if [[ -z "$wear_value" || "$wear_value" == "0" ]]; then
        local pct_used
        pct_used=$(echo "$out" | grep -i "Percentage Used Endurance Indicator" | awk '{print $NF}')
        [[ "$pct_used" =~ ^[0-9]+$ ]] && wear_value=$(( 100 - pct_used ))
        wear_thresh=""
        wear_worst=""
    fi
    raw_life="$wear_value"

    # TBW: attr 241 primero, fallback a 246
    tbw_raw=$(echo "$out" | grep -E "^\s*241\s+" | awk '{print $10}')
    if [[ -z "$tbw_raw" || "$tbw_raw" == "0" ]]; then
        tbw_raw=$(echo "$out" | grep -E "^\s*246\s+" | awk '{print $10}')
    fi

    life=$(echo "$raw_life" | sed 's/^0*//')
    [[ -z "$life" ]] && life=100

    # Attributes Extraction
    crc_err=$(echo "$out" | grep -E "^\s*199\s+" | awk '{print $10}')
    realloc=$(echo "$out" | grep -E "^\s*5\s+" | awk '{print $10}')        # RAW_VALUE (para display/JSON)
    realloc_value=$(echo "$out" | grep -E "^\s*5\s+" | awk '{print $4}')   # VALUE normalizado (0-100)
    realloc_thresh=$(echo "$out" | grep -E "^\s*5\s+" | awk '{print $6}')  # THRESH del fabricante
    pending=$(echo "$out" | grep -E "^\s*197\s+" | awk '{print $10}')
    uncorrectable=$(echo "$out" | grep -E "^\s*198\s+" | awk '{print $10}')

    # End-to-End Error (#184): errores en la ruta completa controlador→NAND
    e2e_err=$(echo "$out" | grep -E "^\s*184\s+" | awk '{print $10}')

    # Reported Uncorrectable Errors (#187): ECC no corregibles a nivel NAND (Samsung, Intel, Seagate)
    reported_uncorr=$(echo "$out" | grep -E "^\s*187\s+" | awk '{print $10}')

    # Available Reserved Space (#232): capacidad restante de reasignación de bloques
    reservd_value=$(echo "$out" | grep -E "^\s*232\s+" | awk '{print $4}')
    reservd_thresh=$(echo "$out" | grep -E "^\s*232\s+" | awk '{print $6}')

    # Media / Data integrity (NVMe specific mostly, but check anyway)
    media_err=$(echo "$out" | grep -Ei "Media and Data Integrity Errors" | awk '{print $NF}')

    # Unsafe shutdowns
    unsafe_pwr=$(echo "$out" | grep -Ei "Unsafe_Shutdowns|Unsafe Shutdowns" | awk '{print $NF}')

    # Temperatura: attr 194 (Temperature_Celsius), fallback a 190 (Airflow_Temperature_Cel)
    temp=$(echo "$out" | grep -E "^\s*194\s+" | awk '{print $10}')
    [[ -z "$temp" || "$temp" == "0" ]] && temp=$(echo "$out" | grep -E "^\s*190\s+" | awk '{print $10}')

    # Sanitización de variables (default a 0 si no son números)
    [[ ! "$hours" =~ ^[0-9]+$ ]] && hours=0
    [[ ! "$crc_err" =~ ^[0-9]+$ ]] && crc_err=0
    [[ ! "$realloc" =~ ^[0-9]+$ ]] && realloc=0
    [[ ! "$realloc_value" =~ ^[0-9]+$ ]] && realloc_value=100
    [[ ! "$realloc_thresh" =~ ^[0-9]+$ ]] && realloc_thresh=0
    [[ ! "$wear_thresh" =~ ^[0-9]+$ ]] && wear_thresh=0
    [[ ! "$wear_worst" =~ ^[0-9]+$ ]] && wear_worst=0
    [[ ! "$e2e_err" =~ ^[0-9]+$ ]] && e2e_err=0
    [[ ! "$reported_uncorr" =~ ^[0-9]+$ ]] && reported_uncorr=0
    [[ ! "$reservd_value" =~ ^[0-9]+$ ]] && reservd_value=100
    [[ ! "$reservd_thresh" =~ ^[0-9]+$ ]] && reservd_thresh=0
    [[ ! "$pending" =~ ^[0-9]+$ ]] && pending=0
    [[ ! "$uncorrectable" =~ ^[0-9]+$ ]] && uncorrectable=0
    [[ ! "$media_err" =~ ^[0-9]+$ ]] && media_err=0
    [[ ! "$unsafe_pwr" =~ ^[0-9]+$ ]] && unsafe_pwr=0
    [[ ! "$temp" =~ ^[0-9]+$ ]] && temp=0
    [[ ! "$tbw_raw" =~ ^[0-9]+$ ]] && tbw_raw=0

    # Normalizar escala 0-200 a porcentaje 0-100 (Toshiba THNSN, algunos enterprise)
    # VALUE del atributo arranca en 200 (nuevo) y el THRESH fabricante es típicamente < 10
    # Convertir a entero base-10 limpio para evitar error de octal en bash (ej: "093")
    life=$(( 10#$life + 0 ))
    wear_worst=$(( 10#$wear_worst + 0 ))
    wear_thresh=$(( 10#$wear_thresh + 0 ))
    if (( life > 100 )); then
        if (( wear_thresh > 0 && wear_thresh < 100 )); then
            life=$(( (life - wear_thresh) * 100 / (200 - wear_thresh) ))
        else
            life=$(( life / 2 ))
        fi
        (( life < 0 )) && life=0
        (( life > 100 )) && life=100
    fi
    if (( wear_worst > 100 )); then
        if (( wear_thresh > 0 && wear_thresh < 100 )); then
            wear_worst=$(( (wear_worst - wear_thresh) * 100 / (200 - wear_thresh) ))
        else
            wear_worst=$(( wear_worst / 2 ))
        fi
        (( wear_worst < 0 )) && wear_worst=0
        (( wear_worst > 100 )) && wear_worst=100
    fi

    # Conversión aproximada a TB (suponiendo 512B por LBA)
    tbw_tb=$(( tbw_raw * 512 / 1024 / 1024 / 1024 / 1024 ))

    # =========================
    # GET DISK SLOT
    # =========================
    slot=$(get_disk_slot "$serial")

    # =========================
    # LÓGICA DE ESTADO (basada en VALUE vs THRESH del fabricante)
    # Todas las condiciones son independientes: los flags se acumulan
    # y el status escala al nivel más grave detectado.
    # =========================
    status="OK"
    flags=""

    # Helper inline: escala status (OK < WARN < CRITICAL/FAIL)
    # Se usa como: _chk <nivel> <flag> <condición_bash>
    # (implementado con bloques if individuales abajo para compatibilidad bash)

    # --- CRITICAL: firmware self-assessment ---
    # El propio disco declara falla — máxima prioridad
    if [[ -n "$health" && "$health" != "PASSED" ]]; then
        status="CRITICAL"; flags+="HEALTH_FAIL($health) "
    fi

    # --- CRITICAL: endurance (attr 177/233/231/202/173) VALUE <= THRESH ---
    if (( wear_thresh > 0 && 10#$life <= 10#$wear_thresh )); then
        status="CRITICAL"; flags+="ENDURANCE_FAILED "
    fi

    # --- CRITICAL: realloc (attr 5) VALUE <= THRESH del fabricante ---
    if (( realloc_thresh > 0 && 10#$realloc_value <= 10#$realloc_thresh )); then
        status="CRITICAL"; flags+="REALLOC_FAILED "
    fi

    # --- CRITICAL: End-to-End errors (#184) — integridad del path de datos ---
    if (( e2e_err > 0 )); then
        status="CRITICAL"; flags+="E2E_ERROR(${e2e_err}) "
    fi

    # --- CRITICAL: Reported Uncorrectable (#187) — ECC NAND no corregibles ---
    if (( reported_uncorr > 0 )); then
        status="CRITICAL"; flags+="REPORTED_UNCORR(${reported_uncorr}) "
    fi

    # --- CRITICAL: sectores pendientes (#197) ---
    if (( pending > 0 )); then
        status="CRITICAL"; flags+="PENDING_SECTORS(${pending}) "
    fi

    # --- CRITICAL: sectores incorregibles offline (#198) ---
    if (( uncorrectable > 0 )); then
        status="CRITICAL"; flags+="UNCORR_ERRORS(${uncorrectable}) "
    fi

    # --- CRITICAL/FAIL: media errors NVMe ---
    if (( media_err > 0 )); then
        [[ "$status" != "CRITICAL" ]] && status="FAIL"
        flags+="MEDIA_ERR(${media_err}) "
    fi

    # --- CRITICAL: espacio de reserva agotado (#232) VALUE <= THRESH ---
    if (( reservd_thresh > 0 && 10#$reservd_value <= 10#$reservd_thresh )); then
        status="CRITICAL"; flags+="RESERVD_EXHAUSTED "
    fi

    # --- CRITICAL: temperatura fuera de spec operacional (>70°C) ---
    if (( temp > 70 )); then
        status="CRITICAL"; flags+="TEMP_CRITICAL(${temp}C) "
    fi

    # --- WARN: endurance VALUE <= 020 y por encima del THRESH (zona de alerta) ---
    if (( wear_thresh > 0 && 10#$life <= ENDURANCE_WARN_THRESHOLD && 10#$life > 10#$wear_thresh )); then
        [[ "$status" == "OK" ]] && status="WARN"; flags+="ENDURANCE_LOW "
    fi

    # --- WARN: realloc VALUE dentro de 20 puntos del THRESH (aproximándose) ---
    if (( realloc_thresh > 0 && 10#$realloc_value <= (10#$realloc_thresh + 20) && 10#$realloc_value > 10#$realloc_thresh )); then
        [[ "$status" == "OK" ]] && status="WARN"; flags+="REALLOC_WARN "
    fi

    # --- WARN: espacio de reserva bajo (#232) VALUE dentro de 20 puntos del THRESH ---
    if (( reservd_thresh > 0 && 10#$reservd_value <= (10#$reservd_thresh + 20) && 10#$reservd_value > 10#$reservd_thresh )); then
        [[ "$status" == "OK" ]] && status="WARN"; flags+="RESERVD_LOW "
    fi

    # --- WARN: temperatura elevada (>60°C, dentro de spec pero preocupante) ---
    if (( temp > 60 && temp <= 70 )); then
        [[ "$status" == "OK" ]] && status="WARN"; flags+="TEMP_WARN(${temp}C) "
    fi

    # --- WARN: errores CRC (#199) — detrás de MegaRAID indica problema de interfaz física
    # (cable, backplane, slot o expander), no necesariamente el disco.
    # Comparar con otros discos del mismo controlador para aislar el origen.
    if (( crc_err >= WARN_CRC_THRESHOLD )); then
        [[ "$status" == "OK" ]] && status="WARN"; flags+="CRC_LINK_WARN(${crc_err}) "
    fi

    # --- WARN: unsafe shutdowns ---
    if (( unsafe_pwr > 0 )); then
        [[ "$status" == "OK" ]] && status="WARN"; flags+="UNSAFE_PWR(${unsafe_pwr}) "
    fi

    # --- RAW_VALUE realloc: umbrales absolutos complementarios al VALUE vs THRESH ---
    # >500: escala a WARN aunque el VALUE esté sano (degradación significativa)
    # >100: INFO informativo para monitoreo preventivo
    if (( realloc > 500 )); then
        [[ "$status" == "OK" ]] && status="WARN"
        flags+="REALLOC_HIGH_RAW_WARN(${realloc}) "
    elif (( realloc > 100 )); then
        flags+="INFO_HIGH_REALLOC_RAW(${realloc}) "
    fi

    # --- INFO: WORST histórico de endurance significativamente menor que VALUE actual ---
    wear_worst=$(echo "$wear_worst" | sed 's/^0*//')
    [[ -z "$wear_worst" ]] && wear_worst=0
    if (( wear_worst > 0 && 10#$wear_worst < 10#$life && (10#$life - 10#$wear_worst) > 10 )); then
        flags+="INFO_WEAR_WORST(${wear_worst}) "
    fi

    # Update global counters and lists
    if [[ "$status" == "CRITICAL" ]] || [[ "$status" == "FAIL" ]]; then
        ((bad_count++))
        critical_disks+=("ID:$idx [SLOT:$slot] ($model $serial) - FLAGS: $flags")
    elif [[ "$status" == "WARN" ]]; then
        ((warn_count++))
    fi

    # Colors
    case "$status" in
        OK)       color="\033[0;32m"  ;;  # green
        WARN)     color="\033[1;33m"  ;;  # bold yellow / orange
        FAIL)     color="\033[0;31m"  ;;  # red
        CRITICAL) color="\033[1;31m"  ;;  # bold red
    esac

    # Output humano (ONLY if not JSON mode)
    if [[ "$SHOW_JSON" != "true" ]]; then
        printf "${color}%-12s\033[0m %-6s %-8s %-8s %-6s %-8s %-10s %-11s %-5s %-9s %-7s %-6s %-25s\n" \
            "[$status]" "ID:$idx" "$slot" "${health:-N/A}" "${life}%" "$hours" "$crc_err" \
            "$reported_uncorr" "$e2e_err" "$pending" "$uncorrectable" "${temp}C" "$model"
    fi

    # JSON machine-readable
    report_data+="{\"id\":$idx,\"model\":\"$model\",\"serial\":\"$serial\",\"status\":\"$status\",\
\"health\":\"${health:-N/A}\",\"life\":$life,\"wear_worst\":$wear_worst,\
\"hours\":$hours,\"crc\":$crc_err,\"realloc\":$realloc,\"realloc_value\":$realloc_value,\"realloc_thresh\":$realloc_thresh,\
\"pending\":$pending,\"uncorrectable\":$uncorrectable,\"reported_uncorr\":$reported_uncorr,\
\"e2e_err\":$e2e_err,\"reservd_value\":$reservd_value,\"reservd_thresh\":$reservd_thresh,\
\"media_err\":$media_err,\"unsafe_pwr\":$unsafe_pwr,\
\"temp\":$temp,\"tbw_tb\":$tbw_tb,\"slot\":\"$slot\",\"flags\":\"${flags% }\"},"

done
unset IFS

# Output Logic
if [[ "$SHOW_JSON" == "true" ]]; then
    echo "{\"disks\":[${report_data%,}],\"raid_groups\":${raid_groups_json},\"rebuilding\":${rebuilding_json}}"
else
    # RAID Group Health section
    echo ""
    echo "--- RAID GROUP HEALTH ---"
    if [[ "$raid_groups_json" == "[]" ]]; then
        echo "  StorCLI unavailable or no virtual drives found"
    else
        printf "  %-8s %-8s %-10s %-12s\n" "VD" "TYPE" "STATE" "SIZE"
        echo "  -----------------------------------------------"
        echo "$raid_groups_json" | jq -r '.[] | [.vd, .type, .state, .size, .status] | @tsv' | \
        awk -F'\t' '{
            color = "\033[0;32m"
            if ($5 == "CRITICAL") color = "\033[1;31m"
            else if ($5 == "WARN") color = "\033[1;33m"
            printf "  %-8s %-8s %s%-10s\033[0m %-12s\n", $1, $2, color, $3, $4
        }'
    fi
    if [[ "$rebuilding_json" != "[]" ]]; then
        echo ""
        echo "  REBUILDING:"
        echo "$rebuilding_json" | jq -r '.[] |
            "  -> Slot " + .slot + " (" + .model + ") DG:" + .dg +
            " — " + .pct + "% — ETA: " + (if .eta? and .eta != "" then .eta else "unknown" end)'
    fi

    # Critical disk summary
    if [ ${#critical_disks[@]} -gt 0 ]; then
        echo -e "\n--- CRITICAL DISKS (REQUIRES IMMEDIATE REPLACEMENT) ---"
        for d in "${critical_disks[@]}"; do
            echo "- $d"
        done
    fi
fi