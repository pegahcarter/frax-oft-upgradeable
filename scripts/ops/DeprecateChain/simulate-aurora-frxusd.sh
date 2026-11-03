#!/usr/bin/env bash
set -euo pipefail

rpc=${1:?expected loopback Anvil RPC}
[[ "$rpc" == http://127.0.0.1:18545 ]]
canonical=${2:?expected verified canonical Safe transaction}

safe=$(jq -er .safe "$canonical")
to=$(jq -er .to "$canonical")
data=$(jq -er .data "$canonical")
oft=0x96a394058e2b84a89bac9667b19661ed003cf5d4
endpoint=0x1a44076050125825900e736c501f859c50fe728c
blocked=0x1ccbf0db9c192d969de57e25b3ff09a25bb1d862
eid=30211
zero=0x0000000000000000000000000000000000000000
zero_peer=$(cast abi-encode 'f(uint256)' 0)

call() { cast call --rpc-url "$rpc" "$@"; }
local_send() {
  local sender=$1
  shift
  cast rpc --rpc-url "$rpc" anvil_impersonateAccount "$sender" >/dev/null
  cast rpc --rpc-url "$rpc" anvil_setBalance "$sender" 0x56bc75e2d63100000 >/dev/null
  cast send --rpc-url "$rpc" --unlocked --from "$sender" --json "$@" |
    jq -e '(.data // .).status == "0x1"' >/dev/null
}

# Use the original envelope. Local approvals use the fork's current nonce.
args=("$to" 0 "$data" 1 0 0 0 "$zero" "$zero")
nonce=$(call "$safe" 'nonce()(uint256)')
digest=$(call "$safe" \
  'getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)(bytes32)' \
  "${args[@]}" "$nonce")
threshold=$(call "$safe" 'getThreshold()(uint256)')
mapfile -t owners < <(call "$safe" 'getOwners()(address[])' |
  tr '[:upper:]' '[:lower:]' | tr -d '[] ' | tr ',' '\n' | sort)
(( threshold >= 1 && threshold <= ${#owners[@]} ))

peer_before=$(call "$oft" 'peers(uint32)(bytes32)' "$eid")
[[ "$peer_before" != "$zero_peer" ]]
signatures=0x
for ((i=0; i<threshold; i++)); do
  owner=${owners[i]}
  if (( i + 1 < threshold )); then
    local_send "$owner" "$safe" 'approveHash(bytes32)' "$digest"
  fi
  signatures+="000000000000000000000000${owner#0x}${zero_peer#0x}01"
done
local_send "$owner" "$safe" \
  'execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)' \
  "${args[@]}" "$signatures"

[[ $(call "$oft" 'peers(uint32)(bytes32)' "$eid") == "$zero_peer" ]]
send_lib=$(call "$endpoint" 'getSendLibrary(address,uint32)(address)' "$oft" "$eid")
[[ "${send_lib,,}" == "$blocked" ]]
receive_lib=$(call "$endpoint" 'getReceiveLibrary(address,uint32)(address,bool)' "$oft" "$eid")
[[ ${receive_lib##*$'\n'} == true ]]
for message_type in 1 2; do
  [[ $(call "$oft" 'enforcedOptions(uint32,uint16)(bytes)' "$eid" "$message_type") == 0x0003 ]]
done
for library in 0x377530cda84dfb2673bf4d145dcf0c4d7fdcb5b6 0x8bc1e36f015b9902b54b1387a4d733cebc2f5a4e; do
  raw=$(call "$library" 'getAppUlnConfig(address,uint32)' "$oft" "$eid")
  empty=$(cast abi-encode 'f((uint64,uint8,uint8,uint8,address[],address[]))' '(0,0,0,0,[],[])')
  [[ "$raw" == "$empty" ]]
done
echo "Verified peer removal, blocked sends, default receive library, cleared options and ULN overrides."
