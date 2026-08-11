# lib/distro/debian.sh - Debian/Ubuntu (apt) init backend. Thin: runs the proven,
# resilient guest apt script inside the chroot, then registers supervisord programs
# host-side. Idempotent (guest script + register_services are both re-runnable).
chd_init_debian() {
    _name="$1"; _p="$2"
    _chd_run_guest_init "$_p" init_debian.sh
    _rc=$?
    if [ "$_rc" -ne 0 ]; then
        print_message warning "guest apt init returned $_rc (likely a transient mirror/network hiccup; re-run 'chd install $_name' to finish - it is idempotent)."
    else
        print_message info "guest apt init completed."
    fi
    # Register services regardless: if supervisor got installed, wire it up.
    chd_register_services "$_name" "$_p"
    return "$_rc"
}
