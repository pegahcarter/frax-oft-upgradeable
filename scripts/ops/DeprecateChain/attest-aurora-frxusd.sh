#!/usr/bin/env bash
set -euo pipefail

mode=${1:?expected hash, replay, or simulate}
attest=${2:?expected path to forge-attest checkout}
cd "$(git rev-parse --show-toplevel)"

producer=f51dd3cee19ffdf03a8d34981d12007471996777
batch=scripts/ops/DeprecateChain/txs/deprecate-1313161554/Deprecate-252-1313161554-FRXUSD.json
safe=0x5f25218ed9474b721d6a38c115107428e832fa2e
multisend=0xa1dabef33b3b82c7814b6d82a79e50f4ac44102b
expected=0x172efcdc827b2736ce406e11292f9f760ce3aea6b09316a3e58e6ac105d84a07
rpc=${FRAXTAL_ARCHIVE_RPC_URL:-https://rpc.frax.com}
local_rpc=http://127.0.0.1:18545
tmp=$(mktemp -d)
anvil_pid=
cleanup() {
  if [[ -n "$anvil_pid" ]]; then kill "$anvil_pid" 2>/dev/null || true; fi
  rm -rf "$tmp"
}
trap cleanup EXIT

verify_batch() {
  bash "$attest/lib/normalize.sh" --input "$1" --format tx-builder --chain-id 252 \
    --safe "$safe" --nonce 555 --safe-version 1.3.0 --multisend "$multisend" > "$tmp/canonical.json"
  local result
  result=$(bash "$attest/lib/derive.sh" "$tmp/canonical.json")
  if [[ "${result##*SAFE_TX_HASH=}" != "$expected" ]]; then
    printf 'Expected %s\n%s\n' "$expected" "$result" >&2
    return 1
  fi
  printf 'Verified %s\n' "$expected"
}

start_fork() {
  local block=$1 hash=$2
  anvil --host 127.0.0.1 --port 18545 --fork-url "$rpc" --fork-block-number "$block" \
    > "$tmp/anvil.log" 2>&1 &
  anvil_pid=$!
  for _ in {1..30}; do
    kill -0 "$anvil_pid" 2>/dev/null || break
    if [[ $(cast block "$block" --field hash --rpc-url "$local_rpc" 2>/dev/null) == "$hash" ]]; then
      [[ $(cast chain-id --rpc-url "$local_rpc") == 252 ]]
      return
    fi
    sleep 1
  done
  cat "$tmp/anvil.log" >&2
  echo "Could not start Fraxtal fork at block $block ($hash)" >&2
  return 1
}

case "$mode" in
  hash)
    verify_batch "$batch"
    ;;
  replay)
    # The Builder createdAt timestamp identifies this historical Fraxtal block.
    start_fork 41874116 0xb743dcc0ebc3ab7430eb8ca2e5a118001d50bf203f3fdbff9f84523931e16534
    git archive "$producer" | tar -x -C "$tmp"
    ln -s "$PWD/node_modules" "$tmp/node_modules"
    cd "$tmp"
    # Route the producer's internal fork through the pinned local fork.
    jq --arg rpc "$local_rpc" '(.Proxy[] | select(.chainid == 252) | .RPC) = $rpc' \
      scripts/L0Config.json > config.tmp
    mv config.tmp scripts/L0Config.json
    rm -f "$batch"
    FOUNDRY_SRC=scripts/ops/DeprecateChain BYPASS_CHAIN_CALLS=false \
      DEPRECATE_CHAIN_ID=1313161554 TARGET_CHAIN_ID=252 SKIP_DEPRECATE_CHAIN_SIM=true \
      forge script scripts/ops/DeprecateChain/DeprecateChain.s.sol:DeprecateChain --ffi
    verify_batch "$batch"
    ;;
  simulate)
    verify_batch "$batch"
    # Block before the confirmed execution, which included nonces 552 through 555.
    start_fork 41908563 0xf871c002051fc1596ac5c5c078c3434d3e6a9ecea37384dbbe08afeffa310463
    bash scripts/ops/DeprecateChain/simulate-aurora-frxusd.sh "$local_rpc" "$tmp/canonical.json"
    ;;
  *)
    echo "Unknown check: $mode" >&2
    exit 2
    ;;
esac
