#!/bin/bash
# Enhanced smartctl check script with StorCLI integration for slot identification

# =========================
# CONFIGURATION
# =========================
LIFE_THRESHOLD=10
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

# Check for JSON flag
SHOW_JSON=false
if [[ "${1:-}" == "--json" ]]; then
    SHOW_JSON=true
fi

# ... (rest of the script)

# =========================
# Detectamos todos los dispositivos megaraid
# =========================
devices=$(smartctl --scan | awk '/megaraid/ {for (i=1;i<=NF;i++) if ($i=="-d") print $1, $(i+1)}')

if [[ "$SHOW_JSON" != "true" ]]; then
    echo "--- STORAGE HEALTH SYSTEM AUDIT (STRICT MODE) ---"
    printf "%-10s %-8s %-6s %-10s %-6s %-7s %-6s %-6s %-20s %-10s %-25s\n" \
    "STATUS" "ID" "LIFE%" "HOURS" "CRC" "REALLOC" "PWR" "TEMP" "SERIAL" "SLOT" "MODEL"
    echo "----------------------------------------------------------------------------------------------------------------------------"
fi

while read -r dev mr; do
    # ... (loop content)

    # Output humano (ONLY if not JSON mode)
    if [[ "$SHOW_JSON" != "true" ]]; then
        printf "${color}%-10s\033[0m %-8s %-6s %-10s %-6s %-7s %-6s %-6s %-20s %-10s %-25s\n" \
            "[$status]" "ID:$idx" "${life}%" "$hours" "$crc_err" "$realloc" "$unsafe_pwr" "${temp}C" "$serial" "$slot" "$model"
    fi

    # JSON machine-readable (now includes slot)
    report_data+="{\"id\":$idx,\"model\":\"$model\",\"serial\":\"$serial\",\"status\":\"$status\",\"life\":$life,\
\"hours\":$hours,\"crc\":$crc_err,\"realloc\":$realloc,\
\"media_err\":$media_err,\"unsafe_pwr\":$unsafe_pwr,\
\"temp\":$temp,\"tbw_tb\":$tbw_tb,\"slot\":\"$slot\"},"

done <<< "$devices"

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
    # AUDIT SCORE (Always show in human mode)
    # =========================
    echo -e "\nAUDIT_SCORE: $((total_disks - bad_count))/$total_disks HEALTHY"
    echo -e "WARNINGS: $warn_count"

    # =========================
    # MACHINE READABLE SUMMARY (Optional JSON in human mode)
    # =========================
    echo -e "\n--- MACHINE READABLE SUMMARY ---"
    echo -e "JSON_DATA: [${report_data%,}]"
fi
