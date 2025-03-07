#!/bin/sh

router=10.1.1.1 # IP Router

# Netify Log File Location
FILE=/var/log/netify/netify.log
# Maximum log file size (256 MiB = 268435456 bytes)
MAXSIZE=268435456  
# How many seconds before file is deemed "older"
OLDTIME=30
# Get current and file times
CURTIME=$(date +%s)
FILETIME=$(stat -c %Y "$FILE")
TIMEDIFF=$(expr "$CURTIME" - "$FILETIME")

##########--Create Netify Folder and File---########
if [ ! -f "$FILE" ]; then
  mkdir -p /var/log/netify
  touch "$FILE"
fi

# Check file size and truncate if necessary
if [ -f "$FILE" ] && [ $(stat -c%s "$FILE") -ge $MAXSIZE ]; then
    echo "Log file exceeded $MAXSIZE bytes, truncating..." >> /var/log/crontab.netify.txt
    truncate -s 0 "$FILE"
fi

# Check if file is older
if [ "$TIMEDIFF" -gt "$OLDTIME" ]; then
  echo "File is older, restarting Netify.log"

  ##########################--Kill any existing NetCat--#########################
  PIDS=$(ps -eaf | grep "$router" | grep -v grep | awk '{print $2}')
  echo "Netify Netcat Was Found, PID: $PIDS"
  for PID in $PIDS; do
    echo "Killing Process $PID"
    kill -9 "$PID" 1>&2
  done

  #########################--Start NetCat--#####################################
  PIDS=$(ps -eaf | grep "$router" | grep -v grep | awk '{print $2}')
  if [ -z "$PIDS" ]; then
    echo "Netify Netcat Process is Not Running." 1>&2
    echo "Starting Netify Netcat Process"
    sleep 1000 | nc "$router" 7150 | grep established | sed 's/"established":false,//g; s/"flow":{//g; s/0}/0/g' | (sed '
        s/0.0.0.0/START/g;
        s/0.0.0.1/END/g') >> "$FILE" &

    PIDS=$(ps -eaf | grep "$router" | grep -v grep | awk '{print $2}')
    echo "New Netify Netcat PID $PIDS"
    exit 1
  else
    for PID in $PIDS; do
      echo "Netify is running, PID is $PID"
    done
  fi
else
  PIDS=$(ps -eaf | grep "$router" | grep -v grep | awk '{print $2}')
  echo "Netify PID: $PIDS"
  for PID in $PIDS; do
    echo "Netify Process $PID"
  done
  echo "Netify.log is current $FILETIME"
fi
