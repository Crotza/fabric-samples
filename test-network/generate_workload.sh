#!/bin/bash
# generate_workload.sh

# Generate a 10KB random-looking payload to make each asset's value larger.
# We generate this once and reuse it to make transaction generation faster.
echo "Generating 10KB data payload..."
# The "-w 0" flag tells base64 to disable line wrapping, creating a single line of text.
PAYLOAD=$(head -c 10240 /dev/urandom | base64 -w 0)
echo "Payload generated."

echo "Generating 150000 transactions with large values..."
for i in {1..150000}
do
  # Safely construct the JSON string using printf to avoid shell interpretation issues
  CTOR_JSON=$(printf '{"function":"CreateAsset","Args":["asset%s","blue","20","%s","750"]}' "$i" "$PAYLOAD")

  # We replace the small "owner" field ("Tom") with our large payload.
  peer chaincode invoke -o localhost:7050 --ordererTLSHostnameOverride orderer.example.com --tls --cafile "${PWD}/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/msp/tlscacerts/tlsca.example.com-cert.pem" -C mychannel -n basic --peerAddresses localhost:7051 --tlsRootCertFiles "${PWD}/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt" --peerAddresses localhost:9051 --tlsRootCertFiles "${PWD}/organizations/peerOrganizations/org2.example.com/peers/peer0.org2.example.com/tls/ca.crt" -c "$CTOR_JSON" > /dev/null
  
  # Print a progress dot every 100 transactions to keep the output clean
  if (( $i % 100 == 0 )); then
    echo -n "."
  fi
done
echo
echo "Transaction generation complete."