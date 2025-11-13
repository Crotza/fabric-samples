#!/usr/bin/env bash
# run_snapshot_bench.sh
# All-in-one: Fabric snapshot + validation + benchmark (SHA-256 vs PH128)
# Requirements: jq, sed, awk, sha256sum, Go (bench-ph with bench_snapshot.go), Docker
# Usage:
#   ./run_snapshot_bench.sh [-c mychannel] [-w] [-n 5] [-L 256] [--cust ""] [--out out.csv]
#     -c   Channel (default: mychannel)
#     -w   Run generate_workload.sh before the snapshot
#     -n   Repetitions per measurement (median) for the bench (default: 5)
#     -L   PH output bits (default: 256)
#     --cust  PH customization string (default: "")
#     --out   Output CSV name (default: snapshot_bench.csv)

set -euo pipefail

# ---------- Args ----------
CHANNEL="mychannel"
DO_WORKLOAD=0
NREPS=5
LBITS=256
CUST=""
OUTCSV="snapshot_bench.csv"
BENCH_ARGS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -c)
      CHANNEL="$2"; shift 2 ;;
    -w)
      DO_WORKLOAD=1; shift ;;
    -n)
      NREPS="$2"; shift 2 ;;
    -L)
      LBITS="$2"; shift 2 ;;
    --cust)
      CUST="$2"; shift 2 ;;
    --out)
      OUTCSV="$2"; shift 2 ;;
        --bench-args)
      BENCH_ARGS="$2"; shift 2 ;;
    *)
      echo "Unknown arg: $1"; exit 2 ;;
  esac
done

# ---------- Paths & sanity ----------
ROOT="$(pwd)"
  if [[ ! -d "./organizations" || ! -f "./network.sh" ]]; then
  echo "Run this from fabric-samples/test-network/"
  exit 1
fi

# Expected environment vars (adjust if necessary)
export PATH="${PWD}/../bin:$PATH"
export CORE_PEER_TLS_ENABLED=true
export CORE_PEER_LOCALMSPID="Org1MSP"
export CORE_PEER_TLS_ROOTCERT_FILE="${PWD}/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt"
export CORE_PEER_MSPCONFIGPATH="${PWD}/organizations/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp"
export CORE_PEER_ADDRESS="localhost:7051"
export FABRIC_CFG_PATH="${PWD}/compose/docker/peercfg"
: "${IMAGE_TAG:=latest}" && export IMAGE_TAG

# Bench tool
BENCH_DIR="./bench-ph"
BENCH_PROG="${BENCH_DIR}/bench_snapshot.go"
  if [[ ! -f "${BENCH_PROG}" ]]; then
  echo "ERROR: could not find ${BENCH_PROG}. Place the bench at: bench-ph/bench_snapshot.go"
  exit 1
fi

# ---------- (optional) Generate workload ----------
if [[ "${DO_WORKLOAD}" -eq 1 ]]; then
  if [[ ! -f "./generate_workload.sh" ]]; then
    echo "ERROR: generate_workload.sh not found."
    exit 1
  fi
  echo "[1/6] Generating workload..."
  ./generate_workload.sh
else
  echo "[1/6] Skipping workload generation (use -w to enable)."
fi

# ---------- Discover ledger height and request snapshot at H-1 ----------
echo "[2/6] Discovering ledger height and requesting snapshot..."
INFO_JSON=$(peer channel getinfo -c "${CHANNEL}")
H=$(echo "${INFO_JSON}" | sed -n 's/.*"height":\([0-9]\+\).*/\1/p')
if [[ -z "${H}" ]]; then
  echo "ERROR: could not extract height from peer channel getinfo."
  echo "${INFO_JSON}"
  exit 1
fi
TARGET=$((H-1))
echo "Current height: ${H} → requesting snapshot at TARGET=${TARGET}"

peer snapshot submitrequest -c "${CHANNEL}" -b "${TARGET}" \
  --tlsRootCertFile "${CORE_PEER_TLS_ROOTCERT_FILE}" >/dev/null

echo "Pending:"
peer snapshot listpending -c "${CHANNEL}" \
  --tlsRootCertFile "${CORE_PEER_TLS_ROOTCERT_FILE}"

# ---------- Wait for snapshot completion ----------
echo "[3/6] Waiting for snapshot generation (up to ~5 min)..."
ATTEMPTS=300
while (( ATTEMPTS-- > 0 )); do
  if docker exec peer0.org1.example.com bash -lc "test -d /var/hyperledger/production/snapshots/completed/${CHANNEL}/${TARGET}"; then
    break
  fi
  sleep 1
done
if (( ATTEMPTS <= 0 )); then
  echo "ERROR: snapshot ${TARGET} did not appear within 300s."
  exit 1
fi
echo "Snapshot ready: /var/hyperledger/production/snapshots/completed/${CHANNEL}/${TARGET}"

# ---------- Copy snapshot and validate SHA-256 ----------
echo "[4/6] Copying snapshot and validating hashes..."
mkdir -p "./snapshots/${TARGET}"
docker cp "peer0.org1.example.com:/var/hyperledger/production/snapshots/completed/${CHANNEL}/${TARGET}/." "./snapshots/${TARGET}/" >/dev/null

SNAPDIR="./snapshots/${TARGET}"
META="${SNAPDIR}/_snapshot_signable_metadata.json"
if [[ ! -f "${META}" ]]; then
  echo "ERROR: metadata not found at ${META}"
  exit 1
fi

REAL_PUB=$(sha256sum "${SNAPDIR}/public_state.data" | awk '{print $1}')
REAL_PRIV=$(sha256sum "${SNAPDIR}/private_state_hashes.data" | awk '{print $1}')
REAL_TX=$(sha256sum "${SNAPDIR}/txids.data" | awk '{print $1}')

EXP_PUB=$(jq -r '.snapshot_files_raw_hashes["public_state.data"]' "${META}")
EXP_PRIV=$(jq -r '.snapshot_files_raw_hashes["private_state_hashes.data"]' "${META}")
EXP_TX=$(jq -r '.snapshot_files_raw_hashes["txids.data"]' "${META}")

echo "SHA-256 validation:"
printf "  public_state.data         exp=%s\n" "${EXP_PUB}"
printf "  public_state.data         real=%s\n" "${REAL_PUB}"
printf "  private_state_hashes.data exp=%s\n" "${EXP_PRIV}"
printf "  private_state_hashes.data real=%s\n" "${REAL_PRIV}"
printf "  txids.data                exp=%s\n" "${EXP_TX}"
printf "  txids.data                real=%s\n" "${REAL_TX}"

if [[ "${REAL_PUB}" != "${EXP_PUB}" || "${REAL_PRIV}" != "${EXP_PRIV}" || "${REAL_TX}" != "${EXP_TX}" ]]; then
  echo "WARNING: some SHA-256 did not match the metadata!"
fi

# ---------- Benchmark ----------
echo "[5/6] Running benchmark (SHA-256 vs PH128)…"
pushd "${BENCH_DIR}" >/dev/null
export GOMAXPROCS=$(nproc)
go run bench_snapshot.go \
  -n "${NREPS}" -L "${LBITS}" -cust "${CUST}" -out "${OUTCSV}" \
  ${BENCH_ARGS} \
  "../snapshots/${TARGET}/public_state.data" \
  "../snapshots/${TARGET}/private_state_hashes.data" \
  "../snapshots/${TARGET}/txids.data"

popd >/dev/null

echo "CSV result: ${BENCH_DIR}/${OUTCSV}"
column -s, -t < "${BENCH_DIR}/${OUTCSV}" | sed -n '1,999p'

# ---------- dump.json ----------
echo "[6/6] Generating dump.json…"
DUMP="./snapshots/${TARGET}/dump.json"
jq -n \
  --arg channel "${CHANNEL}" \
  --argjson height "${H}" \
  --argjson target "${TARGET}" \
  --arg sha_pub_exp "${EXP_PUB}" \
  --arg sha_priv_exp "${EXP_PRIV}" \
  --arg sha_tx_exp "${EXP_TX}" \
  --arg sha_pub_real "${REAL_PUB}" \
  --arg sha_priv_real "${REAL_PRIV}" \
  --arg sha_tx_real "${REAL_TX}" \
  --arg bench_csv "${BENCH_DIR}/${OUTCSV}" \
  --arg bench_table "$(column -s, -t < "${BENCH_DIR}/${OUTCSV}" | sed 's/"/\\"/g')" \
  '{
     channel: $channel,
     ledger_height_at_request: $height,
     snapshot_target_block: $target,
     files: {
       "public_state.data": {sha256_expected: $sha_pub_exp, sha256_real: $sha_pub_real},
       "private_state_hashes.data": {sha256_expected: $sha_priv_exp, sha256_real: $sha_priv_real},
       "txids.data": {sha256_expected: $sha_tx_exp, sha256_real: $sha_tx_real}
     },
     bench: { csv_path: $bench_csv, table_pretty: $bench_table },
     timestamp: now
   }' > "${DUMP}"

echo "OK! dump.json saved at ${DUMP}"
echo "Done ✅"
