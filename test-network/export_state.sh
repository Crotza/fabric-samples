#!/usr/bin/env bash
set -euo pipefail
: "${COUCH:=http://admin:adminpw@localhost:5984}"
: "${DB:=mychannel_basic}"   # use <channel>_<chaincode>
OUT="${1:-dump.json}"

echo "[i] Exporting ${DB} from ${COUCH} -> ${OUT}"
curl -s "${COUCH}/${DB}/_all_docs?include_docs=true" > "${OUT}"
jq '.rows | length as $n | {count:$n}' "${OUT}"
echo "[ok] Dump saved in ${OUT}"