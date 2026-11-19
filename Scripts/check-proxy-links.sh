#!/bin/bash
# Compiles the VPN client's link parsers on their own and runs their self-check.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
echo 'ProxyLinks.selfCheck()' > "$OUT/main.swift"
swiftc -O Sources/MacTools/Tools/Network/ProxyLinks.swift "$OUT/main.swift" -o "$OUT/check"
"$OUT/check"
