#!/bin/sh

PERCCLI_DIR="/opt/lsi/perccli"
PERCCLI="$PERCCLI_DIR/perccli"

cd $PERCCLI_DIR || { echo "No se puede acceder a $PERCCLI_DIR"; exit 1; }

echo "STATUS     ID       LIFE%  HOURS      CRC    REALLOC PENDING UNCORR SERIAL               SLOT       MODEL"
echo "------------------------------------------------------------------------------------------------------------------------------------"

TMPRAW="/tmp/diskraw.txt"
TMPCRIT="/tmp/crit.txt"

# Ejecutamos perccli desde su directorio
$PERCCLI /c0 /eall /sall show all > $TMPRAW 2>/dev/null

id=0
slot=""
model=""
sn=""
hours=0
crc=0
realloc=0
life=100

while read line; do
    echo "$line" | grep -q "EID:Slt" && slot=$(echo $line | awk '{print $1}')
    echo "$line" | grep -q "Model =" && model=$(echo $line | awk -F'= ' '{print $2}')
    echo "$line" | grep -q "SN =" && sn=$(echo $line | awk -F'= ' '{print $2}')
    echo "$line" | grep -q "Power On Hours =" && hours=$(echo $line | awk -F'= ' '{print $2}')
    echo "$line" | grep -q "Media Error Count =" && crc=$(echo $line | awk -F'= ' '{print $2}')
    echo "$line" | grep -q "Predictive Failure Count =" && realloc=$(echo $line | awk -F'= ' '{print $2}')
done < $TMPRAW

echo ""
echo "--- CRITICAL DISKS (REQUIRES IMMEDIATE REPLACEMENT) ---"
echo "⚠️ Nota: PERC H730P no expone LIFE% de SSD bajo RAID"
echo "Sólo se muestran errores predictivos y media errors"

# Mostrar estado básico de errores
awk -v id=0 -v tmp="$TMPRAW" '
/EID:Slt/ {slot=$1}
/SN =/ {sn=$3}
/Model =/ {model=$3}
/Media Error Count =/ {crc=$5}
/Predictive Failure Count =/ {realloc=$5}
END {
    printf "ID:%d SLOT:%s MODEL:%s SN:%s CRC:%s PREDICTIVE:%s\n", id, slot, model, sn, crc, realloc
}
' $TMPRAW

rm -f $TMPRAW
