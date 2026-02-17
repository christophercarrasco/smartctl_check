#!/bin/sh

PERCCLI_DIR="/opt/lsi/perccli"
PERCCLI="$PERCCLI_DIR/perccli"

export LD_LIBRARY_PATH=$PERCCLI_DIR:$LD_LIBRARY_PATH

TMPRAW="/tmp/diskraw.txt"
TMPCRIT="/tmp/crit.txt"

echo "STATUS     ID       LIFE%  HOURS      CRC    REALLOC PENDING UNCORR SERIAL               SLOT       MODEL"
echo "------------------------------------------------------------------------------------------------------------------------------------"

# Generar salida parseable
$PERCCLI /c0 /eall /sall show all J 2>/dev/null | \
grep -E '"EID:Slt"|\"Model\"|\"SN\"|\"Media Error Count\"|\"Predictive Failure Count\"|\"Power On Hours\"|\"Percent Life Remaining\"' \
> $TMPRAW

id=0

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

printf "%-10s ID:%-5d %-6s %-10s %-6s %-7s %-7s %-6s %-20s %-10s %s\n",
status, id, life"%", hours, crc, realloc, 0, 0, sn, slot, model

if (status=="[CRITICAL]") {
    printf "- ID:%d [SLOT:%s] (%s %s) - FLAGS: %s\n", id, slot, model, sn, flags >> "'$TMPCRIT'"
}

id++
}
' $TMPRAW

echo ""
echo "--- CRITICAL DISKS (REQUIRES IMMEDIATE REPLACEMENT) ---"

if [ -f $TMPCRIT ]; then
    cat $TMPCRIT
    rm -f $TMPCRIT
else
    echo "None"
fi

rm -f $TMPRAW
