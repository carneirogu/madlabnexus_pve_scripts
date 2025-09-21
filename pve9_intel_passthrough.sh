#!/usr/bin/env bash
#
#   MADLABNEXUS-PVE9 2025 v1 (refined)
#
# Proxmox VE 9 — Intel Virtualization & Passthrough Auto-Config
# Version 1

set -euo pipefail

# ---------------------------------------------------------------
# Defaults (used when SKIP_MENU=1 or user accepts the prompt)
# ---------------------------------------------------------------
ENABLE_ACS_OVERRIDE=0         # Split IOMMU groups (may reduce isolation)
ENABLE_ISOLATION=0            # Add isolcpus/nohz_full/rcu_nocbs
CORE_RANGE="2-15"             # Cores to isolate if ENABLE_ISOLATION=1

BLACKLIST_GPU_DRIVERS=1       # Blacklist nouveau/nvidia/radeon/amdgpu for booting ONLY
BLACKLIST_I915=1              # Blacklist Intel iGPU for booting ONLY
BLACKLIST_GPU_AUDIO_STACK=1   # Blacklist snd_hda_* + nvidiafb for HDMI and AUDIO booting ONLY

USE_INITCALL_BLACKLIST=1      # Use initcall_blacklist=sysfb_init (stronger) instead of video=efifb:off
QUIET_IGNORED_MSRS=0          # Suppress KVM ignored MSR logs

ENABLE_SRIOV=0                # Enable SR-IOV VFs
SRIOV_IFACE="enp3s0f0"        # NIC name for SR-IOV
SRIOV_VFS=8                   # Number of VFs to create

SET_ZFS_ARC_LIMIT_GB=0        # Limit ZFS ARC size
ARC_GB=64                     # ARC limit (GiB)

declare -a SRIOV_CONFIGS=()   # Populated during menu when SR-IOV is enabled

# ---------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------
print_section() {
  local title="$1"
  echo
  echo "===================================================================="
  echo " ${title}"
  echo "===================================================================="
}

menu_bool() {
  # $1=varname  $2=prompt  $3=default(0/1)
  local __var="$1" __prompt="$2" __def="$3" ans
  local defstr="N"
  [[ "$__def" == "1" ]] && defstr="Y"
  read -r -p "[${defstr}] ${__prompt} (y/N): " ans </dev/tty || true
  case "${ans,,}" in
    y|yes) printf -v "$__var" "1" ;;
    n|no|"") printf -v "$__var" "$__def" ;;
    *) printf -v "$__var" "$__def" ;;
  esac
}

menu_str() {
  # $1=varname  $2=prompt  $3=default
  local __var="$1" __prompt="$2" __def="$3" ans
  read -r -p "[${__def}] ${__prompt}: " ans </dev/tty || true
  if [[ -z "${ans}" ]]; then
    printf -v "$__var" "%s" "$__def"
  else
    printf -v "$__var" "%s" "$ans"
  fi
}

print_summary() {
  cat <<EOS
--- Selected options ---
ENABLE_ACS_OVERRIDE=${ENABLE_ACS_OVERRIDE}
ENABLE_ISOLATION=${ENABLE_ISOLATION}
CORE_RANGE=${CORE_RANGE}

BLACKLIST_GPU_DRIVERS=${BLACKLIST_GPU_DRIVERS}
BLACKLIST_I915=${BLACKLIST_I915}
BLACKLIST_GPU_AUDIO_STACK=${BLACKLIST_GPU_AUDIO_STACK}

USE_INITCALL_BLACKLIST=${USE_INITCALL_BLACKLIST}
QUIET_IGNORED_MSRS=${QUIET_IGNORED_MSRS}

ENABLE_SRIOV=${ENABLE_SRIOV}
EOS

  if (( ENABLE_SRIOV )); then
    if ((${#SRIOV_CONFIGS[@]} > 0)); then
      echo "SR-IOV selections:"
      local entry
      for entry in "${SRIOV_CONFIGS[@]}"; do
        local iface vfs
        IFS=: read -r iface vfs <<<"$entry"
        echo "  - ${iface}: ${vfs} VFs"
      done
    else
      echo "SRIOV_IFACE=${SRIOV_IFACE}"
      echo "SRIOV_VFS=${SRIOV_VFS}"
    fi
  else
    echo "SRIOV_IFACE=${SRIOV_IFACE}"
    echo "SRIOV_VFS=${SRIOV_VFS}"
  fi

  cat <<EOS

SET_ZFS_ARC_LIMIT_GB=${SET_ZFS_ARC_LIMIT_GB}
ARC_GB=${ARC_GB}
------------------------
EOS
}

timestamp() { date +"%Y-%m-%d_%H-%M-%S"; }
has_cmd() { command -v "$1" >/dev/null 2>&1; }
is_systemd_boot() { has_cmd bootctl && bootctl status 2>/dev/null | grep -qi "systemd-boot"; }
backup_file() {
  local file="$1"
  [[ -f "$file" ]] && cp -a "$file" "${file}.bak.$(timestamp)"
}
ensure_line_in_file() {
  local line="$1" file="$2"
  grep -qxF "$line" "$file" 2>/dev/null || echo "$line" >> "$file"
}
append_unique_flags() {
  local current="$1"
  shift
  local flag
  for flag in "$@"; do
    grep -qw -- "$flag" <<<"$current" || current="$current $flag"
  done
  echo "$current" | tr '\n' ' ' | sed 's/  \+/ /g' | sed 's/^ *//;s/ *$//'
}

detect_sriov_capable_nics() {
  local path iface total_file total
  for path in /sys/class/net/*; do
    iface=${path##*/}
    [[ "$iface" == "lo" ]] && continue
    total_file="${path}/device/sriov_totalvfs"
    if [[ -r "$total_file" ]]; then
      total=$(<"$total_file")
      if [[ "$total" =~ ^[0-9]+$ ]] && (( total > 0 )); then
        echo "${iface}:${total}"
      fi
    fi
  done
}

prompt_sriov_selection() {
  local -a detected=()
  local entry
  while IFS= read -r entry; do
    [[ -n "$entry" ]] && detected+=("$entry")
  done < <(detect_sriov_capable_nics)

  if ((${#detected[@]} == 0)); then
    echo "No SR-IOV capable NICs detected. SR-IOV will remain disabled."
    ENABLE_SRIOV=0
    return
  fi

  echo "Detected SR-IOV capable NICs:"
  for entry in "${detected[@]}"; do
    local iface total
    IFS=: read -r iface total <<<"$entry"
    echo "  - ${iface} (supports up to ${total} VFs)"
  done

  SRIOV_CONFIGS=()

  while true; do
    local choice
    read -r -p "Enter NIC name to configure (leave blank when finished): " choice </dev/tty || true
    [[ -z "$choice" ]] && break

    local total=""
    for entry in "${detected[@]}"; do
      local iface max_vfs
      IFS=: read -r iface max_vfs <<<"$entry"
      if [[ "$choice" == "$iface" ]]; then
        total="$max_vfs"
        break
      fi
    done

    if [[ -z "$total" ]]; then
      echo "Interface '${choice}' is not detected as SR-IOV capable. Please choose from the list above."
      continue
    fi

    local -a updated_configs=()
    local already_selected=0
    for entry in "${SRIOV_CONFIGS[@]}"; do
      local sel_iface sel_vfs
      IFS=: read -r sel_iface sel_vfs <<<"$entry"
      if [[ "$sel_iface" == "$choice" ]]; then
        already_selected=1
      else
        updated_configs+=("${sel_iface}:${sel_vfs}")
      fi
    done
    SRIOV_CONFIGS=("${updated_configs[@]}")

    local vfs
    while true; do
      read -r -p "Number of VFs for ${choice} (0-${total}): " vfs </dev/tty || true
      if [[ -z "$vfs" ]]; then
        echo "Please enter a number between 0 and ${total}."
        continue
      fi
      if [[ "$vfs" =~ ^[0-9]+$ ]] && (( vfs >= 0 && vfs <= total )); then
        break
      fi
      echo "Invalid value. Enter a number between 0 and ${total}."
    done

    SRIOV_CONFIGS+=("${choice}:${vfs}")
    (( already_selected )) && echo "Updated ${choice} to ${vfs} VFs." || echo "Configured ${choice} for ${vfs} VFs."
  done

  if ((${#SRIOV_CONFIGS[@]} == 0)); then
    echo "No interfaces selected; SR-IOV will not be enabled."
    ENABLE_SRIOV=0
  else
    IFS=: read -r SRIOV_IFACE SRIOV_VFS <<<"${SRIOV_CONFIGS[0]}"
  fi
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Please run as root."
    exit 1
  fi
}

run_menu() {
  if [[ "${SKIP_MENU:-0}" == "1" ]]; then
    echo "SKIP_MENU=1 set — using built-in defaults."
    return
  fi

  echo
  echo "========================================================================"
  echo "                     MADLAB NEXUS PVE Scripts"
  echo "========================================================================"
  echo "========================================================================"
  echo " Proxmox VE 9 — Intel Virt/Passthrough Auto-Config (Interactive script)"
  echo "========================================================================"
  echo "Press Enter to accept defaults in [brackets]."
  echo

  menu_bool ENABLE_ACS_OVERRIDE "Enable ACS override (split IOMMU groups — only if needed)" "${ENABLE_ACS_OVERRIDE}"
  menu_bool ENABLE_ISOLATION "Enable CPU isolation (isolcpus/nohz_full/rcu_nocbs)" "${ENABLE_ISOLATION}"
  [[ "$ENABLE_ISOLATION" == "1" ]] && menu_str CORE_RANGE "Core range to isolate" "${CORE_RANGE}"

  echo
  echo "Blacklisting (recommended for clean GPU passthrough):"
  menu_bool BLACKLIST_GPU_DRIVERS "Blacklist GPU stacks (nouveau/nvidia/radeon/amdgpu)" "${BLACKLIST_GPU_DRIVERS}"
  menu_bool BLACKLIST_I915 "Also blacklist Intel iGPU (i915)" "${BLACKLIST_I915}"
  menu_bool BLACKLIST_GPU_AUDIO_STACK "Also blacklist GPU audio stack (snd_hda_* + nvidiafb)" "${BLACKLIST_GPU_AUDIO_STACK}"

  echo
  menu_bool USE_INITCALL_BLACKLIST "Use initcall_blacklist=sysfb_init (stronger than video=efifb:off)" "${USE_INITCALL_BLACKLIST}"
  menu_bool QUIET_IGNORED_MSRS "Suppress ignored MSR logs (kvm.conf)" "${QUIET_IGNORED_MSRS}"

  echo
  menu_bool ENABLE_SRIOV "Enable SR-IOV VFs for a NIC" "${ENABLE_SRIOV}"
  if [[ "$ENABLE_SRIOV" == "1" ]]; then
    prompt_sriov_selection
  fi

  echo
  menu_bool SET_ZFS_ARC_LIMIT_GB "Limit ZFS ARC size" "${SET_ZFS_ARC_LIMIT_GB}"
  [[ "$SET_ZFS_ARC_LIMIT_GB" == "1" ]] && menu_str ARC_GB "ARC size limit (GiB)" "${ARC_GB}"

  echo
  print_summary
  read -r -p "Proceed with these settings? (Y/n): " _go </dev/tty || true
  case "${_go,,}" in
    n|no) echo "Aborted by user."; exit 1 ;;
    *) : ;;
  esac
}

configure_bootloader() {
  print_section "Detecting bootloader"

  local bootloader="grub"
  if is_systemd_boot; then
    bootloader="systemd-boot"
  fi
  echo "Detected: ${bootloader}"

  print_section "Altering Kernel boot"

  local base_flags=(
    "intel_iommu=on"
    "iommu=pt"
    "kvm.ignore_msrs=1"
    "mitigations=off"
    "pcie_aspm=off"
    "nvme_core.default_ps_max_latency_us=0"
  )

  local fb_flag
  if [[ "$USE_INITCALL_BLACKLIST" -eq 1 ]]; then
    fb_flag="initcall_blacklist=sysfb_init"
  else
    fb_flag="video=efifb:off"
  fi

  local flags=("${base_flags[@]}" "$fb_flag")
  (( ENABLE_ACS_OVERRIDE )) && flags+=("pcie_acs_override=downstream,multifunction")
  (( ENABLE_ISOLATION )) && flags+=(
    "isolcpus=nohz,managed,${CORE_RANGE}"
    "rcu_nocbs=${CORE_RANGE}"
    "nohz_full=${CORE_RANGE}"
  )

  if [[ "${bootloader}" == "systemd-boot" ]]; then
    local kcmd_file="/etc/kernel/cmdline"
    touch "$kcmd_file"
    backup_file "$kcmd_file"
    local current
    current=$(tr '\n' ' ' < "$kcmd_file" | sed 's/  \+/ /g')
    local new
    new=$(append_unique_flags "$current" "${flags[@]}")
    echo "$new" > "$kcmd_file"
  else
    local grub_file="/etc/default/grub"
    touch "$grub_file"
    backup_file "$grub_file"
    local existing
    existing=$(sed -n 's/^GRUB_CMDLINE_LINUX_DEFAULT="\([^"]*\)".*/\1/p' "$grub_file")
    [[ -z "$existing" ]] && existing="quiet"
    local new
    new=$(append_unique_flags "$existing" "${flags[@]}")
    sed -i "s#^GRUB_CMDLINE_LINUX_DEFAULT=.*#GRUB_CMDLINE_LINUX_DEFAULT=\"${new}\"#" "$grub_file"
  fi

  print_section "Adding VFIO Modules"

  mkdir -p /etc/modules-load.d /etc/modprobe.d

  cat >/etc/modules-load.d/vfio.conf <<'EOF'
vfio
vfio_iommu_type1
vfio_pci
vfio_virqfd
EOF

  local init_modules="/etc/initramfs-tools/modules"
  touch "$init_modules"
  ensure_line_in_file "vfio" "$init_modules"
  ensure_line_in_file "vfio_iommu_type1" "$init_modules"
  ensure_line_in_file "vfio_pci" "$init_modules"
  ensure_line_in_file "vfio_virqfd" "$init_modules"

  cat >/etc/modprobe.d/kvm-intel.conf <<'EOF'
options kvm-intel nested=Y ept=Y eptad=Y unrestricted_guest=Y vpid=Y enable_apicv=Y
EOF

  cat >/etc/modprobe.d/vfio-iommu.conf <<'EOF'
options vfio_iommu_type1 allow_unsafe_interrupts=0
EOF

  if (( QUIET_IGNORED_MSRS )); then
    cat >/etc/modprobe.d/kvm.conf <<'EOF'
options kvm ignore_msrs=Y report_ignored_msrs=0
EOF
  fi

  print_section "Blacklisting drivers"

  if (( BLACKLIST_GPU_DRIVERS || BLACKLIST_I915 || BLACKLIST_GPU_AUDIO_STACK )); then
    {
      (( BLACKLIST_GPU_DRIVERS )) && cat <<'EOF'
blacklist nouveau
blacklist nvidia
blacklist radeon
blacklist amdgpu
options vfio-pci disable_vga=1
EOF
      (( BLACKLIST_I915 )) && echo "blacklist i915"
      (( BLACKLIST_GPU_AUDIO_STACK )) && cat <<'EOF'
blacklist nvidiafb
blacklist snd_hda_codec_hdmi
blacklist snd_hda_intel
blacklist snd_hda_codec
blacklist snd_hda_core
EOF
    } >/etc/modprobe.d/pve-blacklist.conf
  fi

  echo "==> Rebuilding initramfs (all kernels)..."
  update-initramfs -u -k all

  if [[ "${bootloader}" == "systemd-boot" ]]; then
    proxmox-boot-tool refresh || true
  else
    update-grub || true
    proxmox-boot-tool refresh || true
  fi
}

setup_performance_governor() {
  print_section "Installing performance governor for CPU performance"

  apt-get update
  apt-get install -y linux-cpupower sysfsutils

  cat >/etc/systemd/system/cpupower.service <<'EOF'
[Unit]
Description=Set CPU governor to performance
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/bin/cpupower frequency-set -g performance

[Install]
WantedBy=multi-user.target
EOF

  systemctl enable --now cpupower
}

setup_sriov() {
  cat >/etc/systemd/system/sriov@.service <<'EOF'
[Unit]
Description=Enable SR-IOV VFs on %i
After=network-pre.target
Before=network.target

[Service]
Type=oneshot
EnvironmentFile=-/etc/default/sriov/%i
ExecStart=/bin/sh -c 'echo ${SRIOV_VFS:-0} > /sys/class/net/%i/device/sriov_numvfs'

[Install]
WantedBy=multi-user.target
EOF

  if (( ENABLE_SRIOV )); then
    local -a selections=("${SRIOV_CONFIGS[@]}")
    if ((${#selections[@]} == 0)); then
      selections=("${SRIOV_IFACE}:${SRIOV_VFS}")
    fi

    mkdir -p /etc/default/sriov

    local entry
    for entry in "${selections[@]}"; do
      local iface vfs
      IFS=: read -r iface vfs <<<"$entry"
      [[ -z "$iface" ]] && continue
      [[ -z "$vfs" ]] && vfs=0

      cat >"/etc/default/sriov/${iface}" <<EOF
SRIOV_VFS=${vfs}
EOF

      if [[ -e "/sys/class/net/${iface}" ]]; then
        systemctl enable --now "sriov@${iface}" || true
      else
        echo "NOTE: SR-IOV iface ${iface} not found; unit created but not enabled."
      fi
    done
  fi
}

configure_zfs_arc() {
  if (( SET_ZFS_ARC_LIMIT_GB )); then
    local bytes=$((ARC_GB * 1024 * 1024 * 1024))
    echo "options zfs zfs_arc_max=${bytes}" >/etc/modprobe.d/zfs-arc.conf
    update-initramfs -u -k all
  fi
}

perform_housekeeping() {
  systemctl disable --now ksmtuned >/dev/null 2>&1 || true
  echo 0 > /sys/kernel/mm/ksm/run 2>/dev/null || true
}

main() {
  require_root
  run_menu
  configure_bootloader
  setup_performance_governor
  setup_sriov
  configure_zfs_arc
  perform_housekeeping
  print_section "DONE. Reboot to apply all changes."
}

main "$@"
