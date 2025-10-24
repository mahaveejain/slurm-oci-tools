# update_cpu_powersave_perf.sh

This script ensures all CPU cores on GPU nodes (e.g., OCI H100) are set to **performance** mode instead of **powersave**.  
It helps improve GPU job stability and avoid low CPU frequency throttling warnings.

---

## ⚠️ Common Warning

If you see logs like below:

2025-10-23 22:46:31,379 - WARNING - CPU 0: Profile is 'powersave', expected 'performance'.
2025-10-23 22:46:31,379 - WARNING - CPU 1: Profile is 'powersave', expected 'performance'.
2025-10-23 22:46:31,379 - WARNING - CPU 2: Profile is 'powersave', expected 'performance'.


That means your system is currently using the **powersave** governor.  
You need to switch it to **performance** mode.

---
