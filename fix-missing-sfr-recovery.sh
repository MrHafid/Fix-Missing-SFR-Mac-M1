#!/usr/bin/env bash
set -euo pipefail

readonly RECOVERY_PARTITION_GUID="52637672-7900-11AA-AA11-00306543ECAC"
readonly RECOVERY_GDISK_TYPE_CODE="AF0C"
readonly RECOVERY_SIZE_BYTES="${RECOVERY_SIZE_BYTES:-5368684544}"
readonly DRY_RUN="${DRY_RUN:-0}"

log_step() {
  printf '==> %s\n' "$*"
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

run_or_print() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

read_diskutil_field() {
  local device="$1" field_label="$2"
  diskutil info "$device" | awk -F: -v label="$field_label" '$1 ~ label { gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit }'
}

read_size_in_bytes() {
  diskutil info "$1" | sed -n 's/.*Disk Size:.*(\([0-9][0-9]*\) Bytes).*/\1/p' | head -n 1
}

ensure_macos_apple_silicon() {
  [[ "$(uname -s)" == "Darwin" ]] || fail "this script only runs on macOS"
  [[ "$(uname -m)" == "arm64" ]] || fail "this script only supports Apple Silicon Macs"
}

ensure_running_as_root() {
  [[ "$EUID" -eq 0 ]] || fail "run with sudo: sudo $0"
}

ensure_sip_disabled() {
  csrutil status | grep -q "disabled" || fail "System Integrity Protection is enabled; run 'csrutil disable' from Recovery first"
}

ensure_sgdisk_available() {
  local homebrew_bin_directory="/opt/homebrew/bin"
  [[ -d "$homebrew_bin_directory" ]] && export PATH="$homebrew_bin_directory:$PATH"
  command -v sgdisk >/dev/null 2>&1 || fail "sgdisk not found; run 'brew install gptfdisk' as your normal user first"
}

detect_startup_disk_layout() {
  STARTUP_PHYSICAL_STORE="$(read_diskutil_field / "APFS Physical Store")"
  STARTUP_CONTAINER="$(read_diskutil_field / "APFS Container")"
  [[ -n "$STARTUP_PHYSICAL_STORE" ]] || fail "could not find the APFS physical store for /"
  [[ -n "$STARTUP_CONTAINER" ]] || fail "could not find the APFS container for /"

  WHOLE_DISK="$(read_diskutil_field "$STARTUP_PHYSICAL_STORE" "Part of Whole")"
  [[ -n "$WHOLE_DISK" ]] || fail "could not find the whole disk for $STARTUP_PHYSICAL_STORE"

  STARTUP_PARTITION_INDEX="${STARTUP_PHYSICAL_STORE##*s}"
  [[ "$STARTUP_PARTITION_INDEX" =~ ^[0-9]+$ ]] || fail "could not parse the partition index of $STARTUP_PHYSICAL_STORE"
}

exit_if_recovery_partition_exists() {
  if diskutil list "$WHOLE_DISK" | grep -q "Apple_APFS_Recovery"; then
    log_step "Apple_APFS_Recovery already exists; nothing to repair"
    diskutil list "$WHOLE_DISK"
    exit 0
  fi
}

ensure_no_partitions_after_startup_container() {
  local trailing_partition_indexes
  trailing_partition_indexes="$(sgdisk -p "/dev/$WHOLE_DISK" | awk -v startup="$STARTUP_PARTITION_INDEX" '$1 ~ /^[0-9]+$/ && $1 > startup { print $1 }')"
  [[ -z "$trailing_partition_indexes" ]] || fail "found partitions after $STARTUP_PHYSICAL_STORE ($trailing_partition_indexes); refusing to modify an unknown layout"
}

calculate_shrunken_container_size() {
  local current_size_bytes recommended_minimum_bytes
  current_size_bytes="$(read_size_in_bytes "$STARTUP_PHYSICAL_STORE")"
  [[ -n "$current_size_bytes" ]] || fail "could not read the size of $STARTUP_PHYSICAL_STORE"
  [[ "$current_size_bytes" -gt "$RECOVERY_SIZE_BYTES" ]] || fail "$STARTUP_PHYSICAL_STORE is too small"

  SHRUNKEN_CONTAINER_SIZE_BYTES=$((current_size_bytes - RECOVERY_SIZE_BYTES))
  recommended_minimum_bytes="$(diskutil apfs resizeContainer "$STARTUP_PHYSICAL_STORE" limits | sed -n 's/.*Recommended minimum.*(\([0-9][0-9]*\) Bytes).*/\1/p' | head -n 1)"

  if [[ -n "$recommended_minimum_bytes" && "$SHRUNKEN_CONTAINER_SIZE_BYTES" -lt "$recommended_minimum_bytes" ]]; then
    fail "target size $SHRUNKEN_CONTAINER_SIZE_BYTES is below the APFS recommended minimum $recommended_minimum_bytes; free up disk space first"
  fi

  log_step "Startup container: $STARTUP_CONTAINER on $STARTUP_PHYSICAL_STORE ($WHOLE_DISK)"
  log_step "Shrinking $STARTUP_PHYSICAL_STORE from $current_size_bytes to $SHRUNKEN_CONTAINER_SIZE_BYTES bytes"
}

verify_disk_health() {
  log_step "Verifying partition map and startup container"
  diskutil verifyDisk "$WHOLE_DISK"
  diskutil verifyVolume "$STARTUP_CONTAINER"
}

shrink_startup_container() {
  log_step "Shrinking startup APFS container"
  run_or_print diskutil apfs resizeContainer "$STARTUP_PHYSICAL_STORE" "${SHRUNKEN_CONTAINER_SIZE_BYTES}B"
}

create_recovery_partition() {
  log_step "Adding Apple_APFS_Recovery partition in the freed space"
  run_or_print diskutil addPartition "$WHOLE_DISK" "%${RECOVERY_PARTITION_GUID}%" "%noformat%" 0
  [[ "$DRY_RUN" == "1" ]] && return

  RECOVERY_PHYSICAL_STORE="$(diskutil list "$WHOLE_DISK" | awk '/Apple_APFS_Recovery/ { print $NF; exit }')"
  [[ -n "$RECOVERY_PHYSICAL_STORE" ]] || fail "the new partition is not visible as Apple_APFS_Recovery"
  RECOVERY_PARTITION_INDEX="${RECOVERY_PHYSICAL_STORE##*s}"
}

create_recovery_container_and_volume() {
  [[ "$DRY_RUN" == "1" ]] && { printf '[dry-run] create APFS container and Recovery-role volume\n'; return; }

  log_step "Creating APFS container on $RECOVERY_PHYSICAL_STORE"
  diskutil apfs createContainer "$RECOVERY_PHYSICAL_STORE"

  RECOVERY_CONTAINER="$(read_diskutil_field "$RECOVERY_PHYSICAL_STORE" "APFS Container")"
  [[ -n "$RECOVERY_CONTAINER" ]] || fail "could not find the new APFS container on $RECOVERY_PHYSICAL_STORE"

  log_step "Adding Recovery-role volume to $RECOVERY_CONTAINER"
  diskutil apfs addVolume "$RECOVERY_CONTAINER" APFS Recovery -role R -nomount
}

retag_recovery_partition_type() {
  [[ "$DRY_RUN" == "1" ]] && { printf '[dry-run] sgdisk -t <index>:%s\n' "$RECOVERY_GDISK_TYPE_CODE"; return; }

  log_step "Retagging partition $RECOVERY_PARTITION_INDEX as Apple_APFS_Recovery"
  sgdisk -t "${RECOVERY_PARTITION_INDEX}:${RECOVERY_GDISK_TYPE_CODE}" -c "${RECOVERY_PARTITION_INDEX}:Recovery" "/dev/$WHOLE_DISK"
}

remove_auto_created_booter_partitions() {
  [[ "$DRY_RUN" == "1" ]] && { printf '[dry-run] remove empty Apple_Boot partitions after the recovery partition\n'; return; }

  local booter_partition
  for booter_partition in $(diskutil list "$WHOLE_DISK" | awk '/Apple_Boot/ { print $NF }'); do
    local booter_index="${booter_partition##*s}"
    if [[ "$booter_index" -gt "$RECOVERY_PARTITION_INDEX" ]]; then
      log_step "Removing empty Apple_Boot partition $booter_partition that diskutil created automatically"
      diskutil eraseVolume free none "$booter_partition"
    fi
  done
}

verify_repaired_layout() {
  [[ "$DRY_RUN" == "1" ]] && return

  log_step "Verifying repaired layout"
  diskutil verifyDisk "$WHOLE_DISK"
  diskutil verifyVolume "$RECOVERY_CONTAINER"
  diskutil list "$WHOLE_DISK"
  log_step "Done. Reboot, run Software Update, then re-enable SIP with 'csrutil enable' from Recovery"
}

main() {
  ensure_macos_apple_silicon
  ensure_running_as_root
  ensure_sip_disabled
  ensure_sgdisk_available
  detect_startup_disk_layout
  exit_if_recovery_partition_exists
  ensure_no_partitions_after_startup_container
  calculate_shrunken_container_size
  verify_disk_health
  shrink_startup_container
  create_recovery_partition
  create_recovery_container_and_volume
  retag_recovery_partition_type
  remove_auto_created_booter_partitions
  verify_repaired_layout
}

main "$@"
