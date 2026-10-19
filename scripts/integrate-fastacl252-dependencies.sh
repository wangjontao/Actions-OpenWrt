#!/bin/sh
set -eu
test -f target/linux/mediatek/filogic/config-6.6
mkdir -p package/juliangtk-dae
cp profiles/fastacl-v252/core-Makefile package/juliangtk-dae/Makefile
# Expose the JIT settings so defconfig preserves them and the kernel merge
# applies them after the generic and target fragments.
if ! grep -q '^config KERNEL_BPF_JIT$' config/Config-kernel.in; then
  cat >> config/Config-kernel.in <<'EOF'

config KERNEL_BPF_JIT
	bool "Enable BPF JIT for dae"
	default y

config KERNEL_BPF_JIT_ALWAYS_ON
	bool "Always use BPF JIT for dae"
	depends on KERNEL_BPF_JIT
	default y
EOF
fi
cat profiles/fastacl-v252/dependencies.config >> .config
# Explicit target requirements not exposed as top-level OpenWrt menu symbols.
for key in BPF BPF_SYSCALL BPF_JIT CGROUPS KPROBES NET_INGRESS NET_EGRESS NET_CLS_ACT BPF_STREAM_PARSER KPROBE_EVENTS BPF_EVENTS; do
  sed -i "/^CONFIG_${key}=/d; /^# CONFIG_${key} is not set/d" target/linux/mediatek/filogic/config-6.6
  printf 'CONFIG_%s=y\n' "$key" >> target/linux/mediatek/filogic/config-6.6
done
make defconfig
for pkg in juliangtk-dae kmod-sched-core kmod-sched-bpf kmod-veth ip-full tc-full ca-bundle curl bpftool-minimal; do
  grep -q "^CONFIG_PACKAGE_${pkg}=y$" .config || { echo "Missing dae dependency: $pkg"; exit 1; }
done
for key in BPF_JIT BPF_JIT_ALWAYS_ON CGROUPS CGROUP_BPF KPROBES KPROBE_EVENTS BPF_EVENTS BPF_STREAM_PARSER DEBUG_INFO DEBUG_INFO_BTF; do
  grep -q "^CONFIG_KERNEL_${key}=y$" .config || { echo "Missing kernel dependency: $key"; exit 1; }
done
