# lib/backup.sh - unified backup UX (absorbs the original restore/unbackup).
#   chd backup                         interactive:
#       backups exist -> [1] create new  [2] manage existing -> pick -> [1] restore [2] delete
#       no backups    -> straight to instance picker -> create
#   chd backup <instance> [path]       non-interactive: create immediately
# Archive: $CHD_ROOT/.backup/<name>.tar.xz = instance rootfs + .config/<name>.conf
# (original format). Auto-unmounts before tar; refuses if mounts survive (a live
# bind would suck /data into the archive). Restore ports the original common-path
# checks; no jail entry afterwards (decision F).

_chd_backup_dir() { echo "$CHD_ROOT/.backup"; }

# --- create ------------------------------------------------------------------
# _chd_backup_create <instance> [custom_path]
_chd_backup_create() {
    _bn="$1"; _bcustom="${2:-}"
    _bd="$(chd_instance_dir "$_bn")"
    chd_profile_load "$_bn" 2>/dev/null || true
    # Installed = visible rootfs OR an unmounted file-mode instance whose image
    # exists (post-reboot - the most natural time to back up).
    if [ ! -d "$_bd/etc" ] && \
       ! { [ "${TARGET_TYPE:-}" = "file" ] && [ -n "${TARGET_PATH:-}" ] && [ -f "$TARGET_PATH" ]; }; then
        print_message error "instance '$_bn' is not installed."; return 1
    fi

    # Must be fully unmounted before tar (live binds would leak /data into the tar).
    if ! chd_unmount "$_bd"; then
        print_message error "Mounts still busy under '$_bn' - cannot back up safely:"
        _chd_mounts_under "$_bd" | while IFS= read -r _m; do [ -n "$_m" ] && print_message error "   $_m"; done
        print_message note "Close its shells/processes (or chd unmount $_bn -f), then retry."
        return 1
    fi
    # file-mode: rootfs lives inside the img which is now unmounted -> the DIR is
    # empty. Back up by remounting the image read-only for the tar, then unmount.
    _bremount=0
    if [ "${TARGET_TYPE:-file}" = "file" ] && [ -n "${TARGET_PATH:-}" ]; then
        chd_image_mount "$TARGET_PATH" "" "${FS_TYPE:-ext4}" "$_bd" || return 1
        _bremount=1
    fi

    if [ -z "$_bcustom" ]; then
        mkdir -p "$(_chd_backup_dir)"
        _bpath="$(_chd_backup_dir)/$_bn.tar.xz"
        if [ -f "$_bpath" ]; then
            if [ -t 0 ]; then
                _ow="$(_chd_yesno "Backup already exists for '$_bn'. Overwrite" "false")"
                [ "$_ow" = "true" ] || { print_message note "cancelled."; [ "$_bremount" = 1 ] && chd_unmount "$_bd"; return 0; }
            else
                print_message note "overwriting existing backup (non-interactive)."
            fi
            rm -f "$_bpath"
        fi
    else
        _bpath="$_bcustom"
        case "$_bpath" in /*) : ;; *) _bpath="$PWD/$_bpath" ;; esac
    fi

    _bitems="$_bn"
    [ -f "$CHD_ROOT/.config/$_bn.conf" ] && _bitems="$_bitems .config/$_bn.conf"
    print_message info "Creating backup: $_bpath  (this can take a while)"
    ( cd "$CHD_ROOT" || exit 1
      tar -caf "$_bpath" $_bitems 2>/dev/null ) || {
        print_message error "Failed to create the backup."
        rm -f "$_bpath" 2>/dev/null
        [ "$_bremount" = 1 ] && chd_unmount "$_bd"
        return 1
    }
    [ "$_bremount" = 1 ] && chd_unmount "$_bd"
    # Honest verification: archive exists, is non-trivial, and lists.
    if [ ! -s "$_bpath" ] || ! tar -tf "$_bpath" >/dev/null 2>&1; then
        print_message error "Backup verification failed (archive unreadable)."; return 1
    fi
    print_message info "[OK] Backup created: $_bpath ($(du -h "$_bpath" 2>/dev/null | cut -f1))"
}

# --- restore (original common-path checks) -----------------------------------
# _chd_backup_restore <instance> <archive>
_chd_backup_restore() {
    _rn="$1"; _rpath="$2"
    [ -f "$_rpath" ] || { print_message error "backup not found: $_rpath"; return 1; }
    _rd="$(chd_instance_dir "$_rn")"

    # Existing = visible rootfs OR unmounted file-mode with its image present.
    # Without the image check, restoring over an unmounted file-mode instance
    # would silently MERGE old and new rootfs inside the existing image.
    chd_profile_load "$_rn" 2>/dev/null || true
    _rexists=0
    [ -d "$_rd/etc" ] && _rexists=1
    [ "${TARGET_TYPE:-}" = "file" ] && [ -n "${TARGET_PATH:-}" ] && [ -f "$TARGET_PATH" ] && _rexists=1
    if [ "$_rexists" = 1 ]; then
        _ow="$(_chd_yesno "Instance '$_rn' already exists. OVERWRITE it with this backup" "false")"
        [ "$_ow" = "true" ] || { print_message note "restore cancelled."; return 0; }
        chd_cmd_uninstall "$_rn" || { print_message error "could not remove existing instance safely; restore aborted."; return 1; }
    fi

    # Validate archive root (ported from the original).
    _rlist="$(tar -tf "$_rpath" 2>/dev/null | head -200)"
    [ -n "$_rlist" ] || { print_message error "archive unreadable/corrupted."; return 1; }
    _rroot="$(printf '%s\n' "$_rlist" | head -1 | cut -f1 -d/)"
    case "$_rroot" in
        "$_rn")
            # new-format backup: entries are <name>/... (+ .config/<name>.conf)
            print_message info "Restoring '$_rn' from $_rpath ..."
            # file-mode target: recreate + mount the image first so the rootfs
            # lands inside it (conf inside the archive; use template as fallback).
            _tc="$CHD_ROOT/.profile/$_rn.conf"
            _restored_conf=0
            # Extract the instance conf directly (do NOT scan the file list: the
            # rootfs has 100k+ entries and the conf is last, so a head-limited grep
            # would always miss it and wrongly fall back to the template).
            if ( cd "$CHD_ROOT" && tar -xf "$_rpath" ".config/$_rn.conf" 2>/dev/null ) \
               && [ -f "$CHD_ROOT/.config/$_rn.conf" ]; then
                _restored_conf=1
            fi
            [ "$_restored_conf" = 1 ] || { [ -f "$_tc" ] && cp "$_tc" "$CHD_ROOT/.config/$_rn.conf"; }
            chd_profile_load "$_rn" 2>/dev/null || true
            if [ "${TARGET_TYPE:-file}" = "file" ] && [ -n "${TARGET_PATH:-}" ]; then
                chd_image_ensure "$_rd" || return 1
            fi
            ( cd "$CHD_ROOT" || exit 1; tar -xf "$_rpath" "$_rn" 2>/dev/null ) || {
                print_message error "Failed to unpack the archive."; return 1; }
            ;;
        .config|.)
            ( cd "$CHD_ROOT" || exit 1; tar -xf "$_rpath" 2>/dev/null ) || {
                print_message error "Failed to unpack the archive."; return 1; }
            ;;
        data)
            print_message error "Old-style absolute backup (root dir 'data') - not supported by rb2. Extract manually after review."
            return 1 ;;
        *)
            print_message error "Backup looks like a different instance (root dir '$_rroot'). Review before restoring."
            return 1 ;;
    esac

    if [ ! -d "$_rd/etc" ]; then
        print_message error "Restore failed: no rootfs after unpacking."; return 1
    fi
    [ -f "$CHD_ROOT/.config/$_rn.conf" ] || print_message warning "instance conf missing after restore."
    print_message info "[OK] Restore complete. Enter with:  chd login $_rn"
}

# --- the command -------------------------------------------------------------
chd_cmd_backup() {
    chd_require_root
    if [ -n "$1" ]; then
        _chd_backup_create "$1" "${2:-}"
        return $?
    fi

    # Interactive.
    _bl=""
    for f in "$(_chd_backup_dir)"/*.tar.xz; do
        [ -f "$f" ] || continue
        _bl="$_bl $(basename "$f" .tar.xz)"
    done

    if [ -n "$_bl" ]; then
        _act="$(_chd_menu 'Backup:' 1 'Create a new backup' 'Manage existing backups')" || return 0
    else
        _act="Create a new backup"
    fi

    case "$_act" in
        Create*)
            _il=""
            for d in "$CHD_ROOT"/*/; do
                [ -d "$d" ] || continue
                b=$(basename "$d"); chd_is_reserved "$b" && continue
                [ -d "$d/etc" ] || { chd_instance_exists "$b" || continue; }
                _il="$_il $b"
            done
            # include file-mode instances whose dir is empty but conf exists
            for c in "$CHD_ROOT"/.config/*.conf; do
                [ -f "$c" ] || continue
                b=$(basename "$c" .conf)
                case " $_il " in *" $b "*) : ;; *) _il="$_il $b" ;; esac
            done
            [ -n "$_il" ] || { print_message note "no instances to back up."; return 0; }
            _pick="$(_chd_menu 'Back up which instance?' 1 $_il)" || return 0
            _chd_backup_create "$_pick"
            ;;
        Manage*)
            _pick="$(_chd_menu 'Which backup?' 1 $_bl)" || return 0
            _bpath="$(_chd_backup_dir)/$_pick.tar.xz"
            _op="$(_chd_menu "Backup '$_pick' ($(du -h "$_bpath" 2>/dev/null | cut -f1)):" 1 'Restore' 'Delete')" || return 0
            case "$_op" in
                Restore) _chd_backup_restore "$_pick" "$_bpath" ;;
                Delete)
                    _ok="$(_chd_yesno "Really delete backup '$_pick'" "false")"
                    [ "$_ok" = "true" ] && rm -f "$_bpath" && print_message info "deleted: $_bpath"
                    ;;
            esac
            ;;
    esac
}
