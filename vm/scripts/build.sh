#!/bin/bash
# Builds magent-vm and signs it with the virtualization entitlement.
# Without the entitlement, Virtualization.framework refuses to create a VM.
# Don't use `swift run`: it relinks the binary and drops the signature.
set -euo pipefail
cd "$(dirname "$0")/.."

config="${1:-release}"
arch -arm64 swift build -c "$config"
bin="$(arch -arm64 swift build -c "$config" --show-bin-path)/magent-vm"
codesign --force --sign - --entitlements magent-vm.entitlements "$bin"
echo "$bin"
