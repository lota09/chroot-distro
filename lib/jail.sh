# lib/jail.sh - enter/exec inside an instance as root. PURE primitive (no service
# starting - that is the login flow's job). Distro-agnostic (OSMD).

_chd_fix_dns() {
    _p="$1"
    # resolv.conf: (re)create when missing, dangling symlink, or empty.
    if [ ! -e "$_p/etc/resolv.conf" ] || { [ -L "$_p/etc/resolv.conf" ] && [ ! -e "$_p/etc/resolv.conf" ]; } || [ ! -s "$_p/etc/resolv.conf" ]; then
        rm -f "$_p/etc/resolv.conf" 2>/dev/null
        printf 'nameserver 8.8.8.8\nnameserver 8.8.4.4\n' > "$_p/etc/resolv.conf" 2>/dev/null || true
    fi
    # localtime: mirror Android's timezone if the zoneinfo db is present.
    if [ -d "$_p/usr/share/zoneinfo" ]; then
        _tz=""
        command -v getprop >/dev/null 2>&1 && _tz=$(getprop persist.sys.timezone 2>/dev/null | tr -d '[:space:]')
        [ -z "$_tz" ] && [ -f /etc/timezone ] && _tz=$(head -n1 /etc/timezone 2>/dev/null | tr -d '[:space:]')
        [ -z "$_tz" ] && _tz="Etc/UTC"
        if [ -f "$_p/usr/share/zoneinfo/$_tz" ]; then
            ln -sf "/usr/share/zoneinfo/$_tz" "$_p/etc/localtime" 2>/dev/null || true
        fi
    fi
}

# chd_jail <instance_path> [command]
#   no command  -> interactive root login shell
#   command set -> run it as root, non-interactively (used by `chd command`)
chd_jail() {
    _p="$1"; _cmd="$2"
    chd_require_root
    _chd_fix_dns "$_p"
    _su="$(chd_find_su "$_p")"
    if [ -n "$_su" ]; then
        if [ -n "$_cmd" ]; then
            ( unset PREFIX; PATH= chroot "$_p" "$_su" - root -c "$_cmd" )
        else
            ( unset PREFIX; PATH= chroot "$_p" "$_su" - root )
        fi
        return $?
    fi
    print_message warning "no 'su' in rootfs; entering via /bin/sh -l"
    _jp=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    ( unset HISTFILE TMPDIR PREFIX LD_LIBRARY_PATH BOOTCLASSPATH SYSTEMSERVERCLASSPATH
      if [ -n "$_cmd" ]; then
          SHELL=/bin/sh HOME=/root PATH="$_jp" chroot "$_p" /bin/sh -lc "$_cmd"
      else
          SHELL=/bin/sh HOME=/root PATH="$_jp" chroot "$_p" /bin/sh -l
      fi )
}
