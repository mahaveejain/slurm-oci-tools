#!/usr/bin/env bash
# This script identifies the firmware version on OCI H100 Mellanox cards
# and determines whether a firmware upgrade is required as on May, 2026
# Author: Mahaveer Jain
# Update History:
# 5/13/2026 Anand Manian 
#   - Updated minimum version numbers for  based on more recent information from HoPS team
#   - Added version details for ConnectX-6 Lx
#   - Switched out flint (NVIDIA proprietary) with mstflint (Open source OFED) same as in original update script

set -u

if ! command -v lspci >/dev/null 2>&1; then
  echo "Error: lspci command not found." >&2
  exit 1
fi

if ! command -v mstflint >/dev/null 2>&1; then
  echo "Error: mstflint command not found." >&2
  exit 1
fi

pci_devices=()
while IFS= read -r pci; do
  [ -n "$pci" ] && pci_devices+=("$pci")
done < <(lspci | awk '/[Mm]ellanox/ {print $1}')

if [ "${#pci_devices[@]}" -eq 0 ]; then
  echo "No Mellanox PCI devices found." >&2
  exit 1
fi

version_ge() {
  awk -v left="$1" -v right="$2" '
    function cmp(a, b,   i, left_len, right_len, max_len, left_parts, right_parts, left_val, right_val) {
      left_len = split(a, left_parts, ".")
      right_len = split(b, right_parts, ".")
      max_len = (left_len > right_len) ? left_len : right_len

      for (i = 1; i <= max_len; i++) {
        left_val = (i <= left_len) ? left_parts[i] + 0 : 0
        right_val = (i <= right_len) ? right_parts[i] + 0 : 0

        if (left_val > right_val) {
          return 1
        }

        if (left_val < right_val) {
          return -1
        }
      }

      return 0
    }

    BEGIN {
      exit(cmp(left, right) >= 0 ? 0 : 1)
    }
  '
}

fw_upgrade_required() {
  local family="$1"
  local version="$2"
  local minimum_version=""

  case "$family" in
    "ConnectX-7")
      minimum_version="28.46.3048"
      ;;
    "ConnectX-6 Dx")
      minimum_version="22.46.3048"
      ;;
    "ConnectX-6 Lx")
      minimum_version="26.46.3048"
      ;;
    *)
      printf "N/A"
      return
      ;;
  esac

  if [ -z "$version" ] || [ "$version" = "N/A" ]; then
    printf "N/A"
  elif version_ge "$version" "$minimum_version"; then
    printf "False"
  else
    printf "True"
  fi
}

print_separator() {
  printf "+--------+--------------+---------------+------------------+------------------+---------------------+\n"
}

print_separator
printf "| %-6s | %-12s | %-13s | %-16s | %-16s | %-19s |\n" \
  "Sr No" "PCI Address" "Inet Family" "Version" "FW Release Date" "FW_upgrade_required"
print_separator

sr_no=1

for pci in "${pci_devices[@]}"; do
  flint_output="$(sudo mstflint -d "$pci" q 2>/dev/null || true)"
  family="$(lspci -s "$pci" | awk -F'[][]' 'NF >= 2 {print $(NF-1); exit}')"

  version="$(awk -F': *' '/^[[:space:]]*FW Version:/ {print $2; exit}' <<< "$flint_output")"
  fw_date="$(awk -F': *' '/^[[:space:]]*FW Release Date:/ {print $2; exit}' <<< "$flint_output")"
  upgrade_required="$(fw_upgrade_required "${family:-N/A}" "${version:-N/A}")"

  printf "| %-6s | %-12s | %-13s | %-16s | %-16s | %-19s |\n" \
    "$sr_no" \
    "$pci" \
    "${family:-N/A}" \
    "${version:-N/A}" \
    "${fw_date:-N/A}" \
    "$upgrade_required"

  sr_no=$((sr_no + 1))
done

print_separator
