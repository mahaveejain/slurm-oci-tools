#!/usr/bin/env bash
set -euo pipefail

usage(){ echo "Usage: $0 <user@host>|--hosts hosts.txt"; exit 1; }
[[ $# -ge 1 ]] || usage

FILE="/etc/systemd/system/disable-hyperthreading_ubuntu.service"

if [[ "$1" == "--hosts" ]]; then
  [[ $# -eq 2 ]] || usage
  mapfile -t HOSTS < "$2"
else
  HOSTS=("$1")
fi

for HOST in "${HOSTS[@]}"; do
  [[ -n "$HOST" ]] || continue
  echo "=== $HOST ==="
  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$HOST" bash -s <<'EOF' "$FILE"
set -euo pipefail
F="$1"
if [[ ! -f "$F" ]]; then echo "SKIP: $F not found"; exit 0; fi
if grep -Eq "^After=.*tuned\.service" "$F"; then echo "OK: tuned.service already present"; exit 0; fi
if grep -Eq "^After=.*irqbalance\.service" "$F"; then
  sudo cp -a "$F" "$F.bak.$(date +%F-%H%M%S)"
  sudo sed -i '/^After=.*irqbalance\.service/ { /tuned\.service/! s/$/ tuned.service/ }' "$F"
  sudo systemctl daemon-reload || true
  echo "UPDATED"
else
  echo "SKIP: No After= line with irqbalance.service"
fi
EOF
done
