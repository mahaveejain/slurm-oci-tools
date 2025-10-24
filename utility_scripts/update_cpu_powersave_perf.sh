#!/usr/bin/env bash
set -euo pipefail

FILE="/etc/systemd/system/disable-hyperthreading_ubuntu.service"

usage() {
  echo "Usage:"
  echo "  $0 <hostname>"
  echo "  $0 --hosts hosts.txt"
  echo "  $0 --hostlist 'h100-xxx-03-[791,715]'"
  exit 1
}

# ---- helper to detect SLURM-style hostlist token ----
is_slurm_hostlist() {
  # Matches anything containing [ ... ] with numbers, commas, spaces, or dashes inside
  [[ "$1" =~ \[[0-9,\ \-]+\] ]]
}

[[ $# -ge 1 ]] || usage

# --- HARD FAIL if user provided hostlist syntax without --hostlist ---
if [[ "$1" != "--hostlist" && "$1" != "--hosts" ]] && is_slurm_hostlist "$1"; then
  echo "ERROR: Detected SLURM hostlist syntax: '$1'"
  echo "       Use the --hostlist flag, e.g.:"
  echo "       $0 --hostlist '$1'"
  exit 64   # EX_USAGE
fi

# ---- Parse inputs (three modes) ----
HOSTS=()
if [[ "$1" == "--hosts" ]]; then
  [[ $# -eq 2 ]] || usage
  mapfile -t HOSTS < "$2"

elif [[ "$1" == "--hostlist" ]]; then
  [[ $# -eq 2 ]] || usage
  HL="$2"

  # Expand with scontrol if available; fallback to local expander
  expand_hostlist() {
    local hl="$1"
    local -a hosts=()
    if command -v scontrol >/dev/null 2>&1; then
      if mapfile -t hosts < <(scontrol show hostnames "$hl" 2>/dev/null); then
        ((${#hosts[@]})) && printf '%s\n' "${hosts[@]}" && return 0
      fi
    fi
    # Minimal local expansion: prefix-[1,3,007-010]suffix
    if [[ "$hl" =~ ^(.*)\[([0-9,\ \-]+)\](.*)$ ]]; then
      local pre="${BASH_REMATCH[1]}" inner="${BASH_REMATCH[2]}" post="${BASH_REMATCH[3]}"
      IFS=',' read -ra TOKENS <<<"$inner"
      for t in "${TOKENS[@]}"; do
        t="${t// /}"
        if [[ "$t" =~ ^([0-9]+)-([0-9]+)$ ]]; then
          local a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[2]}"
          local width=${#a}; local ia=$((10#$a)); local ib=$((10#$b))
          local step=1; (( ib < ia )) && step=-1
          for ((i=ia;; i+=step)); do
            printf '%s%0*d%s\n' "$pre" "$width" "$i" "$post"
            (( i == ib )) && break
          done
        else
          printf '%s%s%s\n' "$pre" "$t" "$post"
        fi
      done
      return 0
    fi
    printf '%s\n' "$hl"
  }

  mapfile -t HOSTS < <(expand_hostlist "$HL")

else
  # Single hostname mode
  [[ $# -eq 1 ]] || usage
  HOSTS=("$1")
fi

# ---- Main loop (your existing remote logic) ----
for HOST in "${HOSTS[@]}"; do
  [[ -n "$HOST" ]] || continue
  echo "=== $HOST ==="
  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$HOST" bash -s -- "$FILE" <<'EOF'
set -euo pipefail
F="$1"

say(){ printf "%s\n" "$1"; }

if [[ ! -f "$F" ]]; then say "SKIP: $F not found"; exit 20; fi
if grep -Eq '^After=.*tuned\.service' "$F"; then say "OK: tuned.service already present"; exit 0; fi
if grep -Eq '^After=.*irqbalance\.service' "$F"; then
  sudo cp -a "$F" "$F.bak.$(date +%F-%H%M%S)"
  sudo sed -i '/^After=.*irqbalance\.service/ { /tuned\.service/! s/$/ tuned.service/ }' "$F"
  sudo systemctl daemon-reload || true
  say "UPDATED: appended tuned.service and reloaded daemon"
  exit 10
else
  say "SKIP: No After= line with irqbalance.service"
  exit 21
fi
EOF
done
