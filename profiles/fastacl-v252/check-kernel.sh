#!/bin/sh
set -eu
# Run against the actual generated Linux .config after kernel preparation.
file=${1:?Usage: check-kernel.sh path/to/linux/.config}
for key in BPF BPF_SYSCALL BPF_JIT CGROUPS KPROBES NET_INGRESS NET_EGRESS NET_CLS_ACT BPF_STREAM_PARSER DEBUG_INFO DEBUG_INFO_BTF KPROBE_EVENTS BPF_EVENTS; do
  grep -q "^CONFIG_${key}=y$" "$file" || { echo "Kernel prerequisite absent: $key"; exit 1; }
done
for key in NET_SCH_INGRESS NET_CLS_BPF; do
  grep -Eq "^CONFIG_${key}=(y|m)$" "$file" || { echo "Kernel prerequisite absent: $key"; exit 1; }
done
if grep -q '^CONFIG_DEBUG_INFO_REDUCED=y$' "$file"; then echo 'Reduced debug information conflicts with BTF'; exit 1; fi
echo 'dae kernel configuration prerequisites passed; real eBPF load test remains required'
