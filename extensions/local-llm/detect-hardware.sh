#!/usr/bin/env bash
# see ADR-001-local-llm-stack.md (WP404404)
# Mac hardware detection Mac → upper bound on local LLM size LLM. Read-only, no side effects.
# Used in Phase0 and reused by the FMT FMT-installer (Phase3) for hardware-aware selection.
set -euo pipefail

ram_gb=$(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 ))
chip=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "unknown")
macos=$(sw_vers -productVersion 2>/dev/null || echo "unknown")
disk_free_gb=$(df -g / | awk 'END {print $4}')   # END more robust against line wrapping df

# Model tier by RAM (ADR §2)
if [ "$ram_gb" -le 16 ]; then
  tier="one general ~7-8B (on-demand), no second model"
elif [ "$ram_gb" -le 32 ]; then
  tier="one general ~7-8B MVP; opt.. second lightweight 3-4B for PII"
else
  tier="general 7-8B + lightweight PII-model simultaneously; headroom for 14B+"
fi

echo "chip=$chip"
echo "ram_gb=$ram_gb"
echo "macos=$macos"
echo "disk_free_gb=$disk_free_gb"
echo "model_tier=$tier"
