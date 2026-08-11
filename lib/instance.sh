# lib/instance.sh - install / login / command / uninstall / remove.
# Distro-agnostic (OSMD). Consumes download.sh, profile.sh, mount.sh, jail.sh, and
# (optionally) services.sh + lib/distro/* which are wired later.

# --- rootfs extraction ------------------------------------------------------
# chd_extract_rootfs <archive> <dest_dir>
# Handles tar.gz/tar.xz/txz/tar.bz2/tar.zst/tar.zst-as-.zst. Strips a single
# leading directory (e.g. arch's root.x86_64/) so the rootfs lands directly.
chd_extract_rootfs() {
    _ar="$1"; _dest="$2"
    [ -f "$_ar" ] || { print_message error "archive missing: $_ar"; return 1; }
    mkdir -p "$_dest" || { print_message error "cannot create: $_dest"; return 1; }

    print_message info "Extracting $(basename "$_ar") -> $_dest"
    # xz guard: most rootfs are .tar.xz. If busybox tar lacks xz support, fail with
    # a clear message instead of a cryptic tar error (matches the original's check).
    case "$_ar" in
        *.xz|*.txz)
            if ! tar --help 2>&1 | grep -q -- '-J' && ! command -v xz >/dev/null 2>&1 && ! command -v unxz >/dev/null 2>&1; then
                print_message error "tar here cannot decompress xz and no xz/unxz found - update busybox (>=1.36.1)."
                return 1
            fi ;;
    esac
    case "$_ar" in
        *.zst|*.tar.zst)
            if tar --help 2>&1 | grep -q -- '--zstd'; then
                tar --zstd -xf "$_ar" -C "$_dest" || return 1
            elif command -v zstd >/dev/null 2>&1; then
                zstd -dc "$_ar" | tar -x -C "$_dest" || return 1
            elif command -v unzstd >/dev/null 2>&1; then
                unzstd -c "$_ar" | tar -x -C "$_dest" || return 1
            else
                print_message error "zstd not available to unpack $_ar"; return 1
            fi ;;
        *)
            # busybox/gnu tar autodetects gz/xz/bz2 with -xf
            tar -xf "$_ar" -C "$_dest" || return 1 ;;
    esac

    # Flatten a single leading directory if present.
    # NOTE: a freshly formatted ext4 image already contains lost+found, so it must
    # be EXCLUDED from the count or every leading-dir archive (kali, arch bootstrap)
    # would see 2 entries, skip flattening, and fail verification permanently.
    _n=0; _only=""
    for _e in "$_dest"/* "$_dest"/.[!.]*; do
        [ -e "$_e" ] || continue
        case "$(basename "$_e")" in lost+found) continue ;; esac
        _n=$((_n+1)); _only="$_e"
        [ "$_n" -gt 1 ] && break
    done
    if [ "$_n" = 1 ] && [ -d "$_only" ] && [ ! -d "$_dest/etc" ] && [ ! -d "$_dest/bin" ]; then
        print_message info "Stripping leading dir: $(basename "$_only")/"
        ( cd "$_only" && tar -cf - . ) | ( cd "$_dest" && tar -xf - ) || return 1
        rm -rf "$_only"
    fi
    return 0
}

# --- Android chroot preparation (network/gpu/audio groups + hosts) -----------
# Faithful to the original prepare_chroot_distro, but writes VALID /etc/group
# lines (name:x:gid:members) instead of the malformed "gid name" the original
# appended. Android grants AF_INET only to processes in gid 3003 (aid_inet), so
# without this the chroot has NO network (apt/wget fail). Idempotent (GID-keyed).
_chd_prepare_chroot() {
    _p="$1"
    # Refresh /etc/hosts from Android so name resolution basics work.
    cp /etc/hosts "$_p/etc/hosts" 2>/dev/null || {
        [ -s "$_p/etc/hosts" ] || printf '127.0.0.1 localhost\n' > "$_p/etc/hosts" 2>/dev/null
    }
    _g="$_p/etc/group"
    [ -f "$_g" ] || return 0
    # Guard: if the file does not end in a newline, our first append would glue
    # onto the last existing line. Add one first.
    if [ -s "$_g" ] && [ "$(tail -c1 "$_g" 2>/dev/null; echo x)" != "$(printf '\nx')" ]; then
        printf '\n' >> "$_g"
    fi
    # Debian's apt fetches as the _apt user, so it too needs aid_inet.
    _extra=""
    grep -q '^_apt:' "$_p/etc/passwd" 2>/dev/null && _extra=",_apt"
    for _entry in "aid_inet 3003" "aid_net_raw 3004" "aid_graphics 1003" \
                  "aid_input 1004" "aid_audio 1005" "aid_video 1006" "aid_drm 1007"; do
        _gname="${_entry%% *}"; _gid="${_entry##* }"
        # Skip if a group with this GID already exists (avoid dup / respect distro).
        if awk -F: -v g="$_gid" '$3==g{f=1} END{exit !f}' "$_g" 2>/dev/null; then
            continue
        fi
        if [ "$_gname" = "aid_inet" ]; then
            printf '%s:x:%s:root%s\n' "$_gname" "$_gid" "$_extra" >> "$_g"
        else
            printf '%s:x:%s:root\n' "$_gname" "$_gid" >> "$_g"
        fi
    done
    return 0
}

# --- install ----------------------------------------------------------------
# chd_cmd_install <profile> [--no-init] [--no-img]
# ORIGINAL semantics: reads the TEMPLATE .profile/<name>.conf (must exist),
# instance name = profile name, copies the template to .config/<name>.conf,
# file-mode: creates+loop-mounts the .img BEFORE extracting (Samsung/FDE).
# Reborn improvements kept: idempotent (re-runnable), honest verification,
# does NOT auto-enter the shell at the end (decision F).
chd_cmd_install() {
    _name=""; _no_init=""; _no_img=""
    for _a in "$@"; do
        case "$_a" in
            --no-init) _no_init=yes ;;
            --no-img)  _no_img=yes ;;
            -*) print_message error "unknown option: $_a"; return 1 ;;
            *) _name="$_a" ;;
        esac
    done
    [ -n "$_name" ] || { print_message error "usage: chd install [--no-init] [--no-img] <profile>"; return 1; }
    chd_require_root

    _tpl="$(chd_profile_resolve_conf "$_name")" || {
        print_message error "Profile not found: $_name"
        print_message note  "Create one with:  chd profile $_name"
        return 1
    }
    # shellcheck disable=SC1090
    . "$_tpl"
    _name="$(basename "$_tpl" .conf)"
    _distro="${DISTRIB:-}"; _suite="${SUITE:-}"
    [ -n "$_distro" ] || { print_message error "Profile is missing DISTRIB: $_tpl"; return 1; }
    chd_download_check_supported "$_distro" || return 1
    if chd_is_reserved "$_name"; then
        print_message error "'$_name' is a reserved name."; return 1
    fi

    print_message info "Installing '$_name' (distro=$_distro suite=${_suite:-none} target=${TARGET_TYPE:-file})"
    _dir="$(chd_instance_dir "$_name")"
    mkdir -p "$CHD_ROOT/.rootfs" "$CHD_ROOT/.config" "$CHD_ROOT/.backup" "$CHD_ROOT/log"

    # Instance conf = copy of the template (the template layer stays reusable).
    cp "$_tpl" "$(chd_instance_conf "$_name")"

    # file-mode: image must be mounted on the instance dir BEFORE extract.
    if [ "$_no_img" != "yes" ] && [ "${TARGET_TYPE:-file}" = "file" ]; then
        chd_image_ensure "$_dir" || { print_message error "image setup failed."; return 1; }
    fi

    if chd_instance_exists "$_name"; then
        print_message note "'$_name' already extracted - skipping (idempotent)."
    else
        chd_download_if_needed "$_distro" "$_suite" || { print_message error "download failed."; return 1; }
        _ar="$(chd_rootfs_archive_path "$_distro" "$_suite")"
        [ -f "$_ar" ] || { print_message error "rootfs archive missing after download: $_ar"; return 1; }
        if ! chd_extract_rootfs "$_ar" "$_dir"; then
            print_message error "extract failed."
            # dir-mode: safe to clean the plain directory. file-mode: keep the
            # image (partial extract inside it), user can re-run install.
            if [ "${TARGET_TYPE:-file}" = "dir" ]; then rm -rf "$_dir"; fi
            return 1
        fi
        if [ ! -d "$_dir/etc" ] || { [ ! -e "$_dir/bin/sh" ] && [ ! -e "$_dir/usr/bin/sh" ]; }; then
            print_message error "extracted tree has no /etc or /bin/sh - archive bad."
            if [ "${TARGET_TYPE:-file}" = "dir" ]; then rm -rf "$_dir"; fi
            return 1
        fi
        print_message info "Rootfs extracted into: $_dir"
    fi

    mkdir -p "$_dir/root/.chd-init"
    chd_mount "$_dir" >/dev/null 2>&1 || true
    _chd_prepare_chroot "$_dir"

    if [ "$_no_init" = "yes" ]; then
        print_message note "--no-init: skipping distro init."
    elif command -v chd_distro_init >/dev/null 2>&1; then
        print_message info "Running distro init for '$_distro'..."
        if chd_distro_init "$_name" "$_dir"; then
            print_message info "[OK] init complete."
        else
            print_message warning "init reported problems; re-run 'chd install $_name' to finish (idempotent)."
        fi
    fi

    print_message info "[DONE] '$_name' ready. Enter it with:  chd login $_name"
    return 0
}

# --- login / command --------------------------------------------------------
_chd_require_installed() {
    if ! chd_instance_exists "$1"; then
        print_message error "instance '$1' is not installed. Run: chd install $1"
        return 1
    fi
    return 0
}

# Common bring-up used by login/command/mount: conf -> image -> mounts -> prepare.
_chd_bring_up() {
    _name="$1"
    _dir="$(chd_instance_dir "$_name")"
    chd_profile_load "$_name" || print_message note "no instance conf for '$_name' (using defaults)."
    if [ "${TARGET_TYPE:-file}" = "file" ] && [ -n "${TARGET_PATH:-}" ]; then
        chd_image_ensure "$_dir" nocreate || return 1
    fi
    _chd_require_installed "$_name" || return 1
    chd_mount "$_dir" || return 1
    _chd_prepare_chroot "$_dir"
    return 0
}

# chd_cmd_login <name>
chd_cmd_login() {
    _name="$1"
    [ -n "$_name" ] || { print_message error "usage: chd login <name>"; return 1; }
    chd_require_root
    _chd_bring_up "$_name" || return 1
    _dir="$(chd_instance_dir "$_name")"
    if command -v chd_services_up >/dev/null 2>&1; then
        chd_services_up "$_name" "$_dir" || print_message warning "some services failed to start (continuing to shell)."
    fi
    print_message info "Entering '$_name' (root shell). Ctrl-D to exit."
    chd_jail "$_dir"
}

# chd_cmd_command <name> <cmd...>
chd_cmd_command() {
    _name="$1"; { [ "$#" -gt 0 ] && shift; } || true
    [ -n "$_name" ] && [ $# -ge 1 ] || { print_message error 'usage: chd command <name> "<cmd>"'; return 1; }
    chd_require_root
    _chd_bring_up "$_name" || return 1
    _dir="$(chd_instance_dir "$_name")"
    if command -v chd_services_up >/dev/null 2>&1; then
        chd_services_up "$_name" "$_dir" || print_message warning "some services failed (continuing)."
    fi
    chd_jail "$_dir" "$*"
}

# --- mount / unmount commands ------------------------------------------------
# chd mount <name> : image + system mounts + prepare, WITHOUT entering (original).
chd_cmd_mount() {
    _name="$1"
    [ -n "$_name" ] || { print_message error "usage: chd mount <name>"; return 1; }
    chd_require_root
    _chd_bring_up "$_name" || return 1
    print_message info "'$_name' mounted (image + system points). Enter with: chd login $_name"
}

# chd unmount <name|all> [-f]
chd_cmd_unmount() {
    _name=""; _force=""
    for _a in "$@"; do
        case "$_a" in
            -f|--force) _force=yes ;;
            *) _name="$_a" ;;
        esac
    done
    [ -n "$_name" ] || { print_message error "usage: chd unmount <name|all> [-f]"; return 1; }
    chd_require_root
    if [ "$_name" = "all" ]; then
        for d in "$CHD_ROOT"/*/; do
            [ -d "$d" ] || continue
            b=$(basename "$d"); chd_is_reserved "$b" && continue
            chd_profile_load "$b" 2>/dev/null || true
            [ "$_force" = "yes" ] && _chd_kill_holders "${d%/}"
            chd_unmount "${d%/}" && print_message info "unmounted: $b"                 || print_message warning "mounts remain under: $b"
        done
        return 0
    fi
    _dir="$(chd_instance_dir "$_name")"
    chd_profile_load "$_name" 2>/dev/null || true
    [ "$_force" = "yes" ] && _chd_kill_holders "$_dir"
    if chd_unmount "$_dir"; then
        print_message info "'$_name' fully unmounted."
    else
        print_message error "mounts remain under $_dir:"
        _chd_mounts_under "$_dir" | while IFS= read -r _m; do [ -n "$_m" ] && print_message error "   $_m"; done
        return 1
    fi
}

# True if any process has its root or cwd inside the instance (a "running" distro).
_chd_has_holders() {
    _hp="${1%/}"
    for _pd in /proc/[0-9]*; do
        _r=$(readlink "$_pd/root" 2>/dev/null); _w=$(readlink "$_pd/cwd" 2>/dev/null)
        case "$_r" in "$_hp"|"$_hp"/*) return 0 ;; esac
        case "$_w" in "$_hp"|"$_hp"/*) return 0 ;; esac
    done
    return 1
}

# Kill processes whose root/cwd lives inside the instance (force unmount aid).
# /proc scan - no lsof dependency (ported from the original's fallback).
_chd_kill_holders() {
    _kp="${1%/}"
    for _pd in /proc/[0-9]*; do
        _pid="${_pd#/proc/}"
        _rt=$(readlink "$_pd/root" 2>/dev/null)
        _cw=$(readlink "$_pd/cwd" 2>/dev/null)
        case "$_rt" in "$_kp"|"$_kp"/*) kill -9 "$_pid" 2>/dev/null; continue ;; esac
        case "$_cw" in "$_kp"|"$_kp"/*) kill -9 "$_pid" 2>/dev/null ;; esac
    done
    sleep 0.3
    return 0
}

# --- uninstall ---------------------------------------------------------------
# chd uninstall <name> [-f|--force] [--include-profile]   (original flags)
# Deletes ONE instance: rootfs (+ its .img in file-mode). Keeps the .profile
# template and the downloaded rootfs archive. --include-profile also removes
# the INSTANCE conf (.config/<name>.conf), matching the original help text.
chd_cmd_uninstall() {
    _name=""; _force=""; _incprof=""
    for _a in "$@"; do
        case "$_a" in
            -f|--force) _force=yes ;;
            --include-profile) _incprof=yes ;;
            -*) print_message error "unknown option: $_a"; return 1 ;;
            *) _name="$_a" ;;
        esac
    done
    [ -n "$_name" ] || { print_message error "usage: chd uninstall <name> [-f] [--include-profile]"; return 1; }
    chd_require_root
    if chd_is_reserved "$_name"; then
        print_message error "'$_name' is a reserved name, not an instance."; return 1
    fi
    _dir="$(chd_instance_dir "$_name")"
    case "$_dir" in
        "$CHD_ROOT"/?*) : ;;
        *) print_message error "refusing to delete unsafe path: $_dir"; return 1 ;;
    esac
    chd_profile_load "$_name" 2>/dev/null || true

    if [ -d "$_dir" ]; then
        # Original refused to delete a "potentially running" distro. Without -f,
        # refuse if any process still has its root/cwd inside (else rm pulls the
        # filesystem out from under a live VNC/ssh session -> SIGBUS/data loss).
        if [ "$_force" != "yes" ] && _chd_has_holders "$_dir"; then
            print_message error "'$_name' looks in use (a process has root/cwd inside it)."
            print_message note  "Close its shells/desktop/VNC, or force with: chd uninstall $_name -f"
            return 1
        fi
        [ "$_force" = "yes" ] && { print_message info "force: killing processes inside '$_name'..."; _chd_kill_holders "$_dir"; }
        # Unmount everything; refuse rm if ANY mount survives (a live /data bind
        # under the instance would make rm -rf recurse into real /data).
        if ! chd_unmount "$_dir"; then
            print_message error "Mounts still busy under $_dir:"
            _chd_mounts_under "$_dir" | while IFS= read -r _m; do [ -n "$_m" ] && print_message error "   still mounted: $_m"; done
            print_message note "Refusing to delete. Retry with -f, or close processes and retry."
            return 1
        fi
        if [ -n "$(_chd_mounts_under "$_dir")" ]; then
            print_message error "mounts reappeared under $_dir; aborting for safety."; return 1
        fi
        # Symlink pass before rm (original belt-and-suspenders).
        find "$_dir" -type l -exec rm -f {} \; >/dev/null 2>&1 || true
        rm -rf "$_dir" || { print_message error "failed to remove $_dir"; return 1; }
        print_message info "Rootfs removed: $_dir"
    else
        print_message note "'$_name' has no rootfs directory."
    fi

    # file-mode: delete the image file (original behavior).
    if [ "${TARGET_TYPE:-file}" = "file" ] && [ -n "${TARGET_PATH:-}" ] && [ -f "$TARGET_PATH" ]; then
        chd_image_detach "$TARGET_PATH"
        rm -f "$TARGET_PATH" && print_message info "Deleted image file: $TARGET_PATH"
    fi

    if [ "$_incprof" = "yes" ]; then
        _c="$(chd_instance_conf "$_name")"
        [ -f "$_c" ] && rm -f "$_c" && print_message info "Removed instance conf: $_c"
    fi
    print_message info "Uninstalled '$_name' (profile template + rootfs archive kept)."
}

# --- rename ------------------------------------------------------------------
# chd rename <old> <new>  (original: refuse if target exists; move dir + confs + backup)
chd_cmd_rename() {
    _old="$1"; _new="$2"
    [ -n "$_old" ] && [ -n "$_new" ] || { print_message error "usage: chd rename <old> <new>"; return 1; }
    chd_require_root
    _new="$(chd_profile_sanitize_name "$_new")"
    if chd_is_reserved "$_new"; then print_message error "'$_new' is reserved."; return 1; fi
    _od="$(chd_instance_dir "$_old")"; _nd="$(chd_instance_dir "$_new")"
    [ -d "$_od" ] || { print_message error "instance '$_old' is not installed."; return 1; }
    if [ -e "$_nd" ] || [ -e "$CHD_ROOT/.config/$_new.conf" ] || [ -e "$CHD_ROOT/.backup/$_new.tar.xz" ]; then
        print_message error "'$_new' already exists (instance, conf, or backup)."; return 1
    fi
    chd_profile_load "$_old" 2>/dev/null || true
    chd_unmount "$_od" || { print_message error "cannot unmount '$_old'; close it and retry."; return 1; }
    mv "$_od" "$_nd" || { print_message error "rename failed."; return 1; }
    [ -f "$CHD_ROOT/.config/$_old.conf" ] && mv "$CHD_ROOT/.config/$_old.conf" "$CHD_ROOT/.config/$_new.conf"
    [ -f "$CHD_ROOT/.profile/$_old.conf" ] && mv "$CHD_ROOT/.profile/$_old.conf" "$CHD_ROOT/.profile/$_new.conf"
    [ -f "$CHD_ROOT/.backup/$_old.tar.xz" ] && mv "$CHD_ROOT/.backup/$_old.tar.xz" "$CHD_ROOT/.backup/$_new.tar.xz"
    print_message note "Note: the disk image path (TARGET_PATH) is unchanged; edit .config/$_new.conf if you want it renamed too."
    print_message info "Renamed '$_old' -> '$_new'."
}

# --- list (tree) -------------------------------------------------------------
# Profiles (templates) as roots; per-profile install state, target, services.
chd_cmd_list() {
    print_message info "Profiles & instances  ($CHD_ROOT)"
    _shown=""   # instance names already printed under a profile
    _any=0

    # Collect profile names first so we know which entry is last (tree glyphs).
    _profs=""
    for f in "$CHD_ROOT"/.profile/*.conf; do
        [ -f "$f" ] || continue
        _profs="$_profs $(basename "$f" .conf)"
    done
    # Orphan instances (rootfs but no template).
    _orphans=""
    for d in "$CHD_ROOT"/*/; do
        [ -d "$d" ] || continue
        b=$(basename "$d")
        chd_is_reserved "$b" && continue
        [ -d "$d/etc" ] || continue
        case " $_profs " in *" $b "*) : ;; *) _orphans="$_orphans $b" ;; esac
    done

    _total=0
    for n in $_profs $_orphans; do _total=$((_total+1)); done
    _i=0
    for n in $_profs $_orphans; do
        _i=$((_i+1)); _any=1
        if [ "$_i" = "$_total" ]; then _br="└─"; _sp="   "; else _br="├─"; _sp="│  "; fi

        # source of metadata: instance conf if installed, else template.
        _c="$(chd_instance_conf "$n")"
        [ -f "$_c" ] || _c="$CHD_ROOT/.profile/$n.conf"
        _di=""; _su=""; _tt=""; _tp=""
        if [ -f "$_c" ]; then
            _di=$(sed -n 's/^DISTRIB="\(.*\)"/\1/p' "$_c")
            _su=$(sed -n 's/^SUITE="\(.*\)"/\1/p'   "$_c")
            _tt=$(sed -n 's/^TARGET_TYPE="\(.*\)"/\1/p' "$_c")
            _tp=$(sed -n 's/^TARGET_PATH="\(.*\)"/\1/p' "$_c")
        fi
        _dl="${_di:-?}${_su:+/$_su}"

        # Installed states:
        #   rootfs visible (dir-mode, or file-mode currently mounted)   -> installed
        #   file-mode, .img present but NOT mounted (post-reboot state) -> installed, image not mounted
        if [ -d "$CHD_ROOT/$n/etc" ]; then
            if [ "${_tt:-file}" = "file" ] && [ -n "$_tp" ]; then
                _sz=""
                [ -f "$_tp" ] && _sz=" · $(du -h "$_tp" 2>/dev/null | cut -f1)"
                _st="[installed · file:${_tp}${_sz}]"
            else
                _st="[installed · dir]"
            fi
            [ -f "$CHD_ROOT/.profile/$n.conf" ] || _st="$_st (no profile)"
            printf '%s %-14s %-22s %s\n' "$_br" "$n" "$_dl" "$_st"
            if command -v chd_sv_running >/dev/null 2>&1 && chd_sv_running "$CHD_ROOT/$n" 2>/dev/null; then
                _svs=$(ls "$CHD_ROOT/$n/etc/supervisor/conf.d" 2>/dev/null | sed 's/\.conf$//' | tr '\n' ' ')
                [ -n "$_svs" ] && printf '%s └─ services: %s(supervisord up)\n' "$_sp" "$_svs"
            fi
        elif [ "${_tt:-}" = "file" ] && [ -n "$_tp" ] && [ -f "$_tp" ]; then
            _sz=" · $(du -h "$_tp" 2>/dev/null | cut -f1)"
            printf '%s %-14s %-22s [installed · image not mounted:%s%s -> chd login %s]\n' "$_br" "$n" "$_dl" "$_tp" "$_sz" "$n"
        else
            printf '%s %-14s %-22s [not installed -> chd install %s]\n' "$_br" "$n" "$_dl" "$n"
        fi
    done
    [ "$_any" = 0 ] && echo "  (none - create a profile: chd profile <name>)"
}
