#!/bin/sh
logread | grep "received args: add" > /tmp/newd.tmp

while read -r line; do
    day=$(echo "$line" | awk '{print $1}')
    m=$(echo "$line" | awk '{print $2}')
    d=$(echo "$line" | awk '{print $3}')
    t=$(echo "$line" | awk '{print $4}')
    mac=$(echo "$line" | awk '{print $11}')
    ip=$(echo "$line" | awk '{print $12}')
    name=$(echo "$line" | awk '{print $13}')
    
    echo "date=$day-$m-$d-$t device=$name mac=$mac ip=$ip"
done < /tmp/newd.tmp > /tmp/new_device.out
