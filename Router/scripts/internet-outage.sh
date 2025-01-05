#!/bin/sh

# Initialize variables
internet_working=1
start_time=0

# Set the path to the log file
log_file="/tmp/wan_monitor.log"

# Define the target for the ping
ping_target="8.8.8.8"

# Function to log outages
log_outage() {
    if [ $elapsed_time -ge 10 ]; then
        upmsg="$(date '+%Y-%m-%d-%H:%M:%S') up $elapsed_time"
        echo "$upmsg" >> $log_file
    fi
}

# Check and create the log file if it doesn't exist
if [ ! -f "$log_file" ]; then
    touch "$log_file"
    if [ $? -ne 0 ]; then
        echo "Error: Unable to create log file at $log_file. Check permissions." >&2
        exit 1
    fi
fi

# Main loop
while true; do
    # Perform the ping and suppress output
    if ping -q -c 1 -W 1 $ping_target >/dev/null 2>&1; then
        # Internet is working
        if [ $internet_working -eq 0 ]; then
            end_time=$(date +%s)
            elapsed_time=$((end_time - start_time))
            log_outage
            internet_working=1
        fi
    else
        # Internet is down
        if [ $internet_working -eq 1 ]; then
            start_time=$(date +%s)
            echo "$(date '+%Y-%m-%d-%H:%M:%S') down" >> $log_file
            internet_working=0
        fi
    fi
    
    # Sleep for 5 seconds to reduce CPU usage
    sleep 5
done
