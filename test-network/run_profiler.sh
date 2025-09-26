#!/bin/bash
set -euo pipefail

# ===================================================================================
# Capture Snapshot Profiles (CPU, Trace, Goroutines, etc.) from a running peer
# ===================================================================================

# --- Configuration you may tweak ---
PEER_CONTAINER="peer0.org1.example.com"
CHANNEL_NAME="mychannel"

# Durations (seconds)
CPU_PROFILE_SECONDS=60
TRACE_SECONDS=60

# pprof base URL exposed by the peer on the host (ensure peer started with pprof on 6060)
PPROF_BASE_URL="http://localhost:6060/debug/pprof"

# Output root (relative to current dir)
OUT_ROOT="./profiles"

# --- Fabric CLI Environment (same as your previous script) ---
export FABRIC_CFG_PATH="${PWD}/compose/docker/peercfg"
export CORE_PEER_TLS_ENABLED=true
export CORE_PEER_LOCALMSPID="Org1MSP"
export CORE_PEER_MSPCONFIGPATH="${PWD}/organizations/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp"
export CORE_PEER_TLS_ROOTCERT_FILE="${PWD}/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt"
export CORE_PEER_ADDRESS="localhost:7051"

# --- Helpers ---
fail() { echo "❌ $*" >&2; exit 1; }
ok()   { echo "✅ $*"; }
info() { echo "[i] $*"; }

timestamp() { date +"%Y%m%d_%H%M%S"; }

# Check prerequisites
command -v curl >/dev/null 2>&1 || fail "curl not found"
command -v peer >/dev/null 2>&1 || fail "'peer' CLI not found in PATH"

echo "--- Starting Snapshot & Profiling Capture ---"

# 1) Check peer container
info "Checking if Docker container '${PEER_CONTAINER}' is running…"
if [ -z "$(docker ps -q -f name=${PEER_CONTAINER})" ]; then
  fail "Container '${PEER_CONTAINER}' is not running. Start the network (./network.sh up) first."
fi
ok "Container is running."

# 2) Check pprof endpoint
info "Checking pprof endpoint at ${PPROF_BASE_URL}…"
if ! curl -s --connect-timeout 3 "${PPROF_BASE_URL}/" >/dev/null; then
  fail "pprof endpoint not reachable at ${PPROF_BASE_URL}. Make sure the peer exposes pprof on 6060."
fi
ok "pprof reachable."

# 3) Prepare output dir
RUN_TS="$(timestamp)"
OUT_DIR="${OUT_ROOT}/${RUN_TS}"
mkdir -p "${OUT_DIR}"

# Save environment snapshot
{
  echo "Run Timestamp: ${RUN_TS}"
  echo "Channel: ${CHANNEL_NAME}"
  echo "Peer container: ${PEER_CONTAINER}"
  echo "PPROF: ${PPROF_BASE_URL}"
  echo "CPU_PROFILE_SECONDS: ${CPU_PROFILE_SECONDS}"
  echo "TRACE_SECONDS: ${TRACE_SECONDS}"
} > "${OUT_DIR}/summary.txt"

# 4) Trigger snapshot in background
info "Submitting snapshot request for channel '${CHANNEL_NAME}'…"
peer snapshot submitrequest --channelID "${CHANNEL_NAME}" \
  --tlsRootCertFile "${CORE_PEER_TLS_ROOTCERT_FILE}" &
SNAP_PID=$!
ok "Snapshot request submitted (pid $SNAP_PID)."

# 5) Give the peer a moment to ramp CPU (must be < snapshot total time)
info "Waiting 1 second before starting profilers…"
sleep 1

# 6) Start captures
info "Capturing CPU profile (${CPU_PROFILE_SECONDS}s)…"
curl -s -o "${OUT_DIR}/cpu_profile.pb" \
  "${PPROF_BASE_URL}/profile?seconds=${CPU_PROFILE_SECONDS}" \
  && ok "CPU profile saved: ${OUT_DIR}/cpu_profile.pb"

info "Capturing execution TRACE (${TRACE_SECONDS}s)…"
curl -s -o "${OUT_DIR}/trace.out" \
  "${PPROF_BASE_URL}/trace?seconds=${TRACE_SECONDS}" \
  && ok "Trace saved: ${OUT_DIR}/trace.out"

# 7) Point-in-time profiles/dumps (best effort; may be empty if not enabled)
info "Capturing goroutine dump (human-readable)…"
curl -s -o "${OUT_DIR}/goroutines.txt" \
  "${PPROF_BASE_URL}/goroutine?debug=2" \
  && ok "Goroutines (text) saved: ${OUT_DIR}/goroutines.txt"

info "Capturing goroutine profile (binary)…"
curl -s -o "${OUT_DIR}/goroutine.pb" \
  "${PPROF_BASE_URL}/goroutine" \
  && ok "Goroutine (binary) saved: ${OUT_DIR}/goroutine.pb"

info "Capturing threadcreate profile…"
curl -s -o "${OUT_DIR}/threadcreate.pb" \
  "${PPROF_BASE_URL}/threadcreate" \
  && ok "Threadcreate saved: ${OUT_DIR}/threadcreate.pb"

info "Capturing heap profile…"
curl -s -o "${OUT_DIR}/heap.pb" \
  "${PPROF_BASE_URL}/heap" \
  && ok "Heap saved: ${OUT_DIR}/heap.pb"

info "Capturing block profile (may be empty unless enabled)…"
curl -s -o "${OUT_DIR}/block.pb" \
  "${PPROF_BASE_URL}/block" \
  && ok "Block profile saved: ${OUT_DIR}/block.pb"

info "Capturing mutex profile (may be empty unless enabled)…"
curl -s -o "${OUT_DIR}/mutex.pb" \
  "${PPROF_BASE_URL}/mutex" \
  && ok "Mutex profile saved: ${OUT_DIR}/mutex.pb"

# 8) Optional: check snapshot completion (non-blocking; logs info)
info "Snapshot capture finished. The snapshot job may still be running in the peer."
info "Artifacts stored in: ${OUT_DIR}"

cat <<EOF

Next steps (analysis):

1) CPU profile (interactive):
   go tool pprof -http=:8081 "${OUT_DIR}/cpu_profile.pb"

2) Execution trace timeline (to *prove* parallelism):
   /usr/local/go/bin/go tool trace ${OUT_DIR}/trace.out

3) Goroutines (quick view):
   less "${OUT_DIR}/goroutines.txt"

4) If you enabled GODEBUG=mutexprofilefraction=1,blockprofilerate=100 on the peer:
   go tool pprof -http=:8081 "${OUT_DIR}/mutex.pb"
   go tool pprof -http=:8081 "${OUT_DIR}/block.pb"

Pro tip: take screenshots:
- From pprof “flame graph” (CPU) highlighting I/O vs hashing
- From “go tool trace” showing overlapping goroutines across multiple threads
EOF

ok "All requested profiles captured."
