#!/bin/bash
# monitor_stats.sh

# This script monitors a given Docker container and logs its CPU, Memory, and PID count to a CSV file.

# Check for correct number of arguments
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <container_name> <output_csv_file>"
    exit 1
fi

CONTAINER_NAME=$1
OUTPUT_FILE=$2

# Write the CSV header to the output file
echo "timestamp,cpu_percent,mem_usage,pids" > "$OUTPUT_FILE"

echo "Starting monitoring for container '$CONTAINER_NAME'. Press [Ctrl+C] to stop."

# Loop indefinitely until the script is stopped
while true; do
    # Check if the container is still running
    if [ ! "$(docker ps -q -f name=$CONTAINER_NAME)" ]; then
        echo "Container '$CONTAINER_NAME' is no longer running. Exiting monitor."
        break
    fi

    # Get the current timestamp
    TIMESTAMP=$(date --iso-8601=seconds)

    # Get the stats using a custom format, remove the "%" sign from CPU
    STATS=$(docker stats --no-stream --format "{{.CPUPerc}},{{.MemUsage}},{{.PIDs}}" "$CONTAINER_NAME" | sed 's/%//g')

    # Write the data to the CSV file
    echo "$TIMESTAMP,$STATS" >> "$OUTPUT_FILE"

    # Wait for 1 second before the next poll
    sleep 1
done