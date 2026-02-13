#!/bin/bash
# Enhanced smartctl check script with StorCLI integration for slot identification

# =========================
# CONFIGURATION
# =========================
LIFE_THRESHOLD=10 # Legacy fallback
LIFE_CRITICAL=30
LIFE_WARN=60
REALLOC_CRITICAL=5
REALLOC_WARN=1
WARN_CRC_THRESHOLD=1
STORCLI_URL="https://download.lenovo.com/servers/mig/2025/03/26/62030/lnvgy_utl_raid_mr3.storcli-007.3007.0000.0000-2_linux_x86-64-cfc.tgz"
STORCLI_BIN="/opt/MegaRAID/storcli/storcli64"

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
    # Check if already installed
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

for arg in "$@"; do
    case "$arg" in
        --json) SHOW_JSON=true ;;
        --include-json-summary) INCLUDE_SUMMARY=true ;;
    esac
done

# =========================
# Detectamos todos los dispositivos megaraid
# =========================
devices=$(smartctl --scan | awk '/megaraid/ {for (i=1;i<=NF;i++) if ($i=="-d") print $1","$(i+1)}')

if [[ "$SHOW_JSON" != "true" ]]; then
    echo "--- STORAGE HEALTH SYSTEM AUDIT (STRICT MODE - HYBRID LOGIC) ---"
    printf "%-10s %-8s %-6s %-10s %-6s %-7s %-7s %-6s %-20s %-10s %-25s\n" \
    "STATUS" "ID" "LIFE%" "HOURS" "CRC" "REALLOC" "PENDING" "UNCORR" "SERIAL" "SLOT" "MODEL"
    echo "------------------------------------------------------------------------------------------------------------------------------------"
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

    out=$(smartctl -a -d megaraid,"$idx" "$dev" 2>/dev/null)
    # Check if out is empty or smartctl failed
    if [[ -z "$out" ]]; then
        continue
    fi

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

    # Attributes Extraction
    crc_err=$(echo "$out" | grep -E "^\s*199\s+" | awk '{print $10}')
    realloc=$(echo "$out" | grep -E "^\s*5\s+" | awk '{print $10}')
    pending=$(echo "$out" | grep -E "^\s*197\s+" | awk '{print $10}')
    uncorrectable=$(echo "$out" | grep -E "^\s*198\s+" | awk '{print $10}')
    
    # Media / Data integrity (NVMe specific mostly, but check anyway)
    media_err=$(echo "$out" | grep -Ei "Media and Data Integrity Errors" | awk '{print $NF}')

    # Unsafe shutdowns
    unsafe_pwr=$(echo "$out" | grep -Ei "Unsafe_Shutdowns|Unsafe Shutdowns" | awk '{print $NF}')

    # Temperatura
    temp=$(echo "$out" | grep -Ei "Temperature_Celsius" | awk '{print $10}')

    # Sanitización de variables (default a 0 si no son números)
    [[ ! "$hours" =~ ^[0-9]+$ ]] && hours=0
    [[ ! "$crc_err" =~ ^[0-9]+$ ]] && crc_err=0
    [[ ! "$realloc" =~ ^[0-9]+$ ]] && realloc=0
    [[ ! "$pending" =~ ^[0-9]+$ ]] && pending=0
    [[ ! "$uncorrectable" =~ ^[0-9]+$ ]] && uncorrectable=0
    [[ ! "$media_err" =~ ^[0-9]+$ ]] && media_err=0
    [[ ! "$unsafe_pwr" =~ ^[0-9]+$ ]] && unsafe_pwr=0
    [[ ! "$temp" =~ ^[0-9]+$ ]] && temp=0
    [[ ! "$tbw_raw" =~ ^[0-9]+$ ]] && tbw_raw=0

    # Conversión aproximada a TB (suponiendo 512B por unidad)
    tbw_tb=$(( tbw_raw * 512 / 1024 / 1024 / 1024 / 1024 ))

    # =========================
    # GET DISK SLOT
    # =========================
    slot=$(get_disk_slot "$serial")

    # =========================
    # LÓGICA DE ESTADO (Híbrida / HANA inspired)
    # =========================
    status="OK"
    flags=""

    # --- CRITICAL CONDITIONS ---
    # 1. Life < 30%
    # 2. Realloc > 5 (High realloc count)
    # 3. Pending > 0 (Unstable sectors)
    # 4. Uncorrectable > 0 (Data corruption)
    if (( 10#$life < LIFE_CRITICAL )); then
        status="CRITICAL"
        flags+="LOW_LIFE "
    elif (( realloc > REALLOC_CRITICAL )); then
        status="CRITICAL"
        flags+="HIGH_REALLOC "
    elif (( pending > 0 )); then
        status="CRITICAL"
        flags+="PENDING_SECTORS "
    elif (( uncorrectable > 0 )); then
        status="CRITICAL"
        flags+="UNCORR_ERRORS "
    elif (( media_err > 0 )); then
        status="FAIL" # NVMe critical failure
        flags+="MEDIA_ERR "
        
    # --- WARNING CONDITIONS ---
    # 1. Life between 30% and 60%
    # 2. Realloc between 1 and 5
    # 3. CRC Errors > 0
    # 4. Unsafe Shutdowns > 0
    elif (( 10#$life < LIFE_WARN )); then
        status="WARN"
        flags+="LIFE_WARN "
    elif (( realloc >= REALLOC_WARN )); then
        status="WARN"
        flags+="REALLOC_WARN "
    elif (( crc_err >= WARN_CRC_THRESHOLD )); then
        status="WARN"
        flags+="CRC_WARN "
    elif (( unsafe_pwr > 0 )); then
        status="WARN"
        flags+="UNSAFE_PWR "
    fi

    # Update global counters and lists
    if [[ "$status" == "CRITICAL" ]] || [[ "$status" == "FAIL" ]]; then
        ((bad_count++))
        critical_disks+=("ID:$idx [SLOT:$slot] ($model $serial) - FLAGS: $flags")
    elif [[ "$status" == "WARN" ]]; then
        ((warn_count++))
    fi

    # Colores
    case "$status" in
        OK) color="\033[0;32m" ;;
        WARN) color="\033[0;33m" ;;
        FAIL) color="\033[0;31m" ;;
        CRITICAL) color="\033[1;41m" ;; # rojo con fondo para resaltar
    esac

    # Output humano (ONLY if not JSON mode)
    if [[ "$SHOW_JSON" != "true" ]]; then
        printf "${color}%-10s\033[0m %-8s %-6s %-10s %-6s %-7s %-7s %-6s %-20s %-10s %-25s\n" \
            "[$status]" "ID:$idx" "${life}%" "$hours" "$crc_err" "$realloc" "$pending" "$uncorrectable" "$serial" "$slot" "$model"
    fi

    # JSON machine-readable
    report_data+="{\"id\":$idx,\"model\":\"$model\",\"serial\":\"$serial\",\"status\":\"$status\",\"life\":$life,\
\"hours\":$hours,\"crc\":$crc_err,\"realloc\":$realloc,\"pending\":$pending,\"uncorrectable\":$uncorrectable,\
\"media_err\":$media_err,\"unsafe_pwr\":$unsafe_pwr,\
\"temp\":$temp,\"tbw_tb\":$tbw_tb,\"slot\":\"$slot\",\"flags\":\"$flags\"},"

done
unset IFS

# Output Logic
if [[ "$SHOW_JSON" == "true" ]]; then
    # Print ONLY JSON data array
    echo "[${report_data%,}]"
else
    # =========================
    # CRITICAL DISKS (Always show in human mode)
    # =========================
    if [ ${#critical_disks[@]} -gt 0 ]; then
        echo -e "\n--- CRITICAL DISKS (REQUIRES IMMEDIATE REPLACEMENT) ---"
        for d in "${critical_disks[@]}"; do
            echo "- $d"
        done
    fi

    # =========================
    # AUDIT SCORE (Optional Summary)
    # =========================
    if [[ "$INCLUDE_SUMMARY" == "true" ]]; then
        echo -e "\nAUDIT_SCORE: $((total_disks - bad_count))/$total_disks HEALTHY"
        echo -e "WARNINGS: $warn_count"
    
        # =========================
        # MACHINE READABLE SUMMARY (Optional JSON in human mode)
        # =========================
        echo -e "\n--- MACHINE READABLE SUMMARY ---"
        echo -e "JSON_DATA: [${report_data%,}]"
    fi
fi
