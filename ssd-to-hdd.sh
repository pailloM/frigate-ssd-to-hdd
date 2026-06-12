#!/bin/bash
LOCKFILE=/var/lock/ssd_to_hdd.lock
exec 9>"$LOCKFILE"
if ! flock -n 9; then
  log "Another instance is running; exiting."
  exit 0
fi
# keep fd 9 open for the lifetime of the script to hold the lock


set -euo pipefail

SSD_BASE="/media/frigate"
HDD_BASE="/media/frigate-hdd"
SUBDIRS=("recordings" "clips")
MIN_AGE_DAYS="${MIN_AGE_DAYS:-0}"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') — $*"
}

sync_to_hdd() {
    local subdir="$1"
    local ssd_dir="$SSD_BASE/$subdir"
    local hdd_dir="$HDD_BASE/$subdir"
    [ -d "$ssd_dir" ] || return 0

    local find_args=("$ssd_dir" -type f)
    if [ "$MIN_AGE_DAYS" -gt 0 ]; then
        find_args+=(-mtime "+${MIN_AGE_DAYS}")
        log "Starting SSD → HDD sync for $subdir (files older than ${MIN_AGE_DAYS} days)"
    else
        log "Starting SSD → HDD sync for $subdir"
    fi

    find "${find_args[@]}" -print0 | while IFS= read -r -d '' ssd_file; do
        rel_path="${ssd_file#$ssd_dir/}"
        hdd_file="$hdd_dir/$rel_path"

        [ -f "$hdd_file" ] && continue

        mkdir -p "$(dirname "$hdd_file")"
        mv "$ssd_file" "$hdd_file"
        ln -s "$hdd_file" "$ssd_file"
        log "Moved: $subdir/$rel_path"
    done

    log "SSD → HDD sync complete for $subdir"
}

cleanup_hdd() {
    local subdir="$1"
    local ssd_dir="$SSD_BASE/$subdir"
    local hdd_dir="$HDD_BASE/$subdir"
    [ -d "$hdd_dir" ] || return 0

    log "Starting HDD cleanup for $subdir"

    find "$hdd_dir" -type f -print0 | while IFS= read -r -d '' hdd_file; do
        rel_path="${hdd_file#$hdd_dir/}"
        ssd_path="$ssd_dir/$rel_path"

        # If Frigate removed the entry from SSD entirely, delete from HDD
        if [ ! -e "$ssd_path" ] && [ ! -L "$ssd_path" ]; then
            rm "$hdd_file"
            log "Cleaned: $subdir/$rel_path"
        fi
    done

    find "$hdd_dir" -mindepth 1 -type d -empty -delete 2>/dev/null || true

    log "HDD cleanup complete for $subdir"
}

repair_symlinks() {
    local subdir="$1"
    local ssd_dir="$SSD_BASE/$subdir"
    local hdd_dir="$HDD_BASE/$subdir"
    [ -d "$hdd_dir" ] || return 0

    log "Starting symlink repair for $subdir"

    find "$hdd_dir" -type f -print0 | while IFS= read -r -d '' hdd_file; do
        rel_path="${hdd_file#$hdd_dir/}"
        ssd_path="$ssd_dir/$rel_path"

        # Skip if a valid symlink already exists
        [ -L "$ssd_path" ] && [ -e "$ssd_path" ] && continue

        # Remove broken symlink if present
        [ -L "$ssd_path" ] && rm "$ssd_path"

        mkdir -p "$(dirname "$ssd_path")"
        ln -s "$hdd_file" "$ssd_path"
        log "Repaired: $subdir/$rel_path"
    done

    log "Symlink repair complete for $subdir"
}

revert() {
    local subdir="$1"
    local ssd_dir="$SSD_BASE/$subdir"
    local hdd_dir="$HDD_BASE/$subdir"
    [ -d "$ssd_dir" ] || return 0

    log "Starting revert for $subdir"

    find "$ssd_dir" -type l -print0 | while IFS= read -r -d '' ssd_link; do
        rel_path="${ssd_link#$ssd_dir/}"
        hdd_file="$hdd_dir/$rel_path"

        if [ -f "$hdd_file" ]; then
            rm "$ssd_link"
            mv "$hdd_file" "$ssd_link"
            log "Reverted: $subdir/$rel_path"
        else
            rm "$ssd_link"
            log "Removed broken symlink: $subdir/$rel_path"
        fi
    done

    find "$hdd_dir" -mindepth 1 -type d -empty -delete 2>/dev/null || true

    log "Revert complete for $subdir"
}

case "${1:-}" in
    sync)
        for subdir in "${SUBDIRS[@]}"; do
            sync_to_hdd "$subdir"
            cleanup_hdd "$subdir"
        done
        ;;
    repair)
        for subdir in "${SUBDIRS[@]}"; do
            repair_symlinks "$subdir"
        done
        ;;
    revert)
        for subdir in "${SUBDIRS[@]}"; do
            revert "$subdir"
        done
        ;;
    ""|*)
        echo "Usage: $0 {sync|repair|revert}"
        exit 1
        ;;
esac
