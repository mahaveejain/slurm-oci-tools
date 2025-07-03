#!/bin/bash

# === CONFIG ===
INVENTORY_FILE="/tmp/gf_inventory"
PLAYBOOK_FILE=~/tmp/gather_facts.yml  #Copied from this repo
RAW_LOG="/tmp/raw.dat"
TMP_LOG="/tmp/ansible_tmp_output.log"
PARSED_OUTPUT="/tmp/final_raw.dat"
DIFF_OUTPUT="/tmp/problem_nodes.diff"
TIMEOUT_DURATION="1m"

# Step 0: Check if playbook exists
if [ ! -f "$PLAYBOOK_FILE" ]; then
    echo "Error: Playbook file '$PLAYBOOK_FILE' not found. Exiting."
    exit 1
fi

# Step 1: Generate inventory and store in /tmp
echo "Generating Slurm node inventory..."
sinfo -Neh -p compute | awk '{print $1}' | sort -t- -k 4 -n > "$INVENTORY_FILE"

# Step 2: Run ansible-playbook with timeout
echo "Running ansible-playbook with timeout..."
timeout "$TIMEOUT_DURATION" ansible-playbook "$PLAYBOOK_FILE" -i "$INVENTORY_FILE" | tee "$TMP_LOG"
ret_code=${PIPESTATUS[0]}

# Step 3: If it hangs, capture and parse the output
if [ "$ret_code" -eq 124 ]; then
    echo "Ansible command hung. Capturing output..."
    cp "$TMP_LOG" "$RAW_LOG"

    echo "Extracting node names from output..."
    awk -F[ '{print $2}' "$RAW_LOG" | awk -F] '{print $1}' | sort -t- -k 4 -n > "$PARSED_OUTPUT"
    echo "Processed output saved to $PARSED_OUTPUT"

    echo "Cleaning up raw.dat..."
    rm -f "$RAW_LOG"

    # Step 4: Compare inventory and responding nodes
    echo "Comparing inventory to responding nodes..."
    diff "$INVENTORY_FILE" "$PARSED_OUTPUT" > "$DIFF_OUTPUT"

    if [ -s "$DIFF_OUTPUT" ]; then
        echo "Problematic nodes detected. See $DIFF_OUTPUT:"
        cat "$DIFF_OUTPUT"
    else
        echo "All nodes responded. No issues found."
    fi
else
    echo "Ansible completed successfully. No need to process output."
fi

# Step 5: Cleanup
rm -f "$TMP_LOG"
