#!/bin/bash
# run_benchmark.sh

# This script automates the snapshot benchmark process.
# It takes one argument: the name of the algorithm to test (e.g., "SHA256" or "ParallelHash256")

# --- Configuration ---
PEER_CONTAINER="peer0.org1.example.com"
CHANNEL_NAME="mychannel"
# ---

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <AlgorithmName>"
    echo "Example: $0 SHA256"
    exit 1
fi

ALGO_NAME=$1
OUTPUT_FILE="results_${ALGO_NAME,,}.csv" # Converts name to lowercase for the filename

echo "--- Starting benchmark for [$ALGO_NAME] ---"

# 1. Start the monitoring script in the background
echo "Starting resource monitor..."
./monitor_stats.sh "$PEER_CONTAINER" "$OUTPUT_FILE" &
MONITOR_PID=$!
echo "Monitor started in the background with PID: $MONITOR_PID"

# Give the monitor a second to start up
sleep 2

# 2. Trigger the snapshot
echo "Submitting snapshot request to the peer..."
peer snapshot submitrequest --channelID "$CHANNEL_NAME" --tlsRootCertFile "${PWD}/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt"
if [ $? -ne 0 ]; then
    echo "Error: Failed to submit snapshot request. Stopping monitor."
    kill $MONITOR_PID
    exit 1
fi
echo "Snapshot request submitted successfully."

# 3. Wait for the snapshot to complete by polling the peer's logs
echo "Waiting for snapshot generation to complete... (This may take a while)"
while true; do
    # Grep for the completion message in the peer's logs. The "2>&1" ensures we check both output and error streams.
    if docker logs "$PEER_CONTAINER" 2>&1 | grep -q "Generated snapshot"; then
        echo "SUCCESS: Snapshot generation complete!"
        break
    fi
    # Print a dot to show we are still waiting
    echo -n "."
    sleep 5 # Wait for 5 seconds before checking the logs again
done

# 4. Stop the monitoring script
echo "Stopping resource monitor..."
kill $MONITOR_PID
echo "Monitoring stopped."

echo "--- Benchmark for [$ALGO_NAME] is complete. Data saved to [$OUTPUT_FILE] ---"