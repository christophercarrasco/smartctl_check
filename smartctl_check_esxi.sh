#!/bin/sh

STORCLI="/opt/lsi/storcli/storcli64"

echo "STATUS     ID       LIFE%  HOURS      CRC    REALLOC PENDING UNCORR SERIAL               SLOT       MODEL"
echo "------------------------------------------------------------------------------------------------------------------------------------"

critical_list=""

$STORCLI /c0 /eall /sall show all J | grep -E '"EID:Slt"|\"Model\"|\"SN\"|\"Media Error Count\"|\"Predictive Failure Count\"|\"Power On Hours\"|\"Percent Life Remaining\"' > /tmp/diskraw.txt

awk '
/"EID:Slt"/ {slot=$3}
/"Model"/ {model=$3}
/"SN"/ {sn=$3}
/"Power On Hours"/ {hours=$4}
/"Media Error Count"/ {crc=$4}
/"Predictive Failure Count"/ {realloc=$4}
/"Percent Life Remaining"/ {
life=$4
status="OK"
flags=""

if (life+0 < 20) {
    status="[CRITICAL]"
    flags="LOW_LIFE"
}

if (realloc+0 > 50) {
    status="[CRITICAL]"
    flags="HIGH_REALLOC"
}

printf "%-10s ID:%-5s %-6s %-10s %-6s %-7s %-7s %-6s %-20s %-10s %s\n",
status, id, life"%", hours, crc, realloc, 0, 0, sn, slot, model

if (status=="[CRITICAL]") {
    printf "- ID:%s [SLOT:%s] (%s %s) - FLAGS: %s\n", id, slot, model, sn, flags >> "/tmp/crit.txt"
}

id++
}
' /tmp/diskraw.txt

echo ""
echo "--- CRITICAL DISKS (REQUIRES IMMEDIATE REPLACEMENT) ---"

if [ -f /tmp/crit.txt ]; then
    cat /tmp/crit.txt
    rm /tmp/crit.txt
else
    echo "None"
fi

rm /tmp/diskraw.txt
