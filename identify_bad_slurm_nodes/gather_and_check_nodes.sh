#!/usr/bin/env bash
# gather_and_check_nodes.sh

set -euo pipefail

# === CONFIGURATION ===
INVENTORY_FILE="/tmp/gf_inventory"
PLAYBOOK_FILE="$HOME/mj/gather_facts.yml"
RAW_LOG="/tmp/raw.dat"
TMP_LOG="/tmp/ansible_tmp_output.log"
PARSED_OUTPUT="/tmp/final_raw.dat"
ALL_BRACKETS="/tmp/all_bracket_entries.txt"
CLEAN_INVENTORY="/tmp/full_node_list_cleaned.txt"
MISSING_NODES="/tmp/missing_nodes.txt"
TIMEOUT_DURATION="1m"
ANSIBLE_VERBOSITY=""

# === PRE-CHECKS ===
if [[ ! -f "$PLAYBOOK_FILE" ]]; then
  echo "Error: playbook file '$PLAYBOOK_FILE' not found."
  exit 1
fi

command -v sinfo >/dev/null || { echo "Missing: sinfo"; exit 1; }
command -v ansible-playbook >/dev/null || { echo "Missing: ansible-playbook"; exit 1; }

# === STEP 1: Build inventory ===
echo "Building Slurm inventory..."
{
  echo "[compute]"
  sinfo -Neh -p compute | awk '{print $1}' | sort -u
} > "$INVENTORY_FILE"

# Create sorted clean list (no headers) for comparison
grep -v '^\[' "$INVENTORY_FILE" | sort -u > "$CLEAN_INVENTORY"

# === STEP 2: Run Ansible ===
echo "Running Ansible playbook with timeout $TIMEOUT_DURATION..."
timeout "$TIMEOUT_DURATION" ansible-playbook $ANSIBLE_VERBOSITY -i "$INVENTORY_FILE" "$PLAYBOOK_FILE" | tee "$TMP_LOG"
ret_code=${PIPESTATUS[0]}
echo "ansible-playbook exited with code $ret_code"

# === STEP 3: Parse responding hostnames ===
cp "$TMP_LOG" "$RAW_LOG"
grep -oP '\[\K[^\]]+' "$RAW_LOG" | sort -u > "$ALL_BRACKETS"

# Keep only valid hostnames from inventory
comm -12 "$ALL_BRACKETS" "$CLEAN_INVENTORY" | sort -u > "$PARSED_OUTPUT"
echo "Parsed responding hosts → $PARSED_OUTPUT"

# === STEP 4: Find missing hosts ===
comm -23 "$CLEAN_INVENTORY" "$PARSED_OUTPUT" > "$MISSING_NODES"

# === STEP 5: Output results ===
total=$(wc -l < "$CLEAN_INVENTORY")
responded=$(wc -l < "$PARSED_OUTPUT")
missing=$(wc -l < "$MISSING_NODES")

echo
echo "Summary:"
echo "  Total nodes         : $total"
echo "  Responded to Ansible: $responded"
echo "  Missing nodes       : $missing"

if [[ "$missing" -eq 0 ]]; then
  echo "All nodes responded successfully."
else
  echo
  echo "Missing nodes:"
  cat "$MISSING_NODES"
fi

# === CLEANUP TEMP FILES ===
rm -f "$TMP_LOG" "$RAW_LOG" "$ALL_BRACKETS"
