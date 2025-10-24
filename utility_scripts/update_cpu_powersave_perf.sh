#!/usr/bin/env bash
# Purpose: Ensure tuned.service is in After= line on disable-hyperthreading_ubuntu.service
# Supports: single host | --hostlist | --hosts
set -euo pipefail

FILE="/etc/systemd/system/disable-hyperthreading_ubuntu.service"

usage(){
  echo "Usage:"
  echo "  $0 <hostname>                       # single host"
  echo "  $0 --hostlist 'h100-dd01-03-[38,97,112]'"
  echo "  $0 --hosts hosts.txt"
  exit 1
}

# --- Input parsing ---
[[ $# -ge 1 ]] || usage
HOSTS=()

if [[ "$1" == "--hostlist" ]]; then
  [[ $# -eq 2 ]] || usage
  HL="$2"
  if command -v scontrol >/dev/null 2>&1; then
    echo "Expanding SLURM hostlist..."
    mapfile -t HOSTS < <(scontrol show hostnames -e "$HL")
  else
    echo "Error: scontrol not found for hostlist expansion"
    exit 2
  fi
elif [[ "$1" == "--hosts" ]]; then
  [[ $# -eq 2 ]] || usage
  HOSTFILE="$2"
  [[ -f "$HOSTFILE" ]] || { echo "File not found: $HOSTFILE"; exit 2; }
  mapfile -t HOSTS < "$HOSTFILE"
else
  # Treat first argument as single host
  HOSTS=("$1")
fi

# --- Main logic ---
for HOST in "${HOSTS[@]}"; do
  [[ -n "$HOST" ]] || continue
  echo "=== $HOST ==="
  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$HOST" bash -s -- "$FILE" <<'EOF'
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
