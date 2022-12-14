#!/bin/sh

IFS=$IFS
while read mac ip name; do
    ping -c1 "$ip" &>/dev/null && echo device=$name mac=$mac ip=$ip status=online || echo device=$name mac=$mac ip=$ip status=offline
done < /etc/config/knownmac.txt > /tmp/device-status.out
