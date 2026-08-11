# lib/download.sh - rootfs download + archive path helpers. Distro-agnostic (OSMD).
# Ported from the proven per-distro URL logic of the original chroot-distro.
# Public API:
#   CHD_ARCH                      normalized arch (arm64|armhf|i386|amd64)
#   chd_download_supported        prints the supported-distro list
#   chd_download_check_supported <distro>
#   chd_rootfs_archive_name  <distro> [suite]   -> <distro>[-<suite>].tar.xz
#   chd_rootfs_archive_path  <distro> [suite]   -> $CHD_ROOT/.rootfs/<name>
#   chd_download <distro> [suite] [force]       -> download into archive path
#   chd_download_if_needed <distro> [suite]

# --- architecture (normalized) ---------------------------------------------
CHD_ARCH="$(uname -m)"
case "$CHD_ARCH" in
    aarch64|arm64)                                   CHD_ARCH="arm64" ;;
    arm|armel|armhf|armhfp|armv7|armv7l|armv7a|armv8l) CHD_ARCH="armhf" ;;
    386|i386|i686|x86)                               CHD_ARCH="i386" ;;
    amd64|x86_64)                                    CHD_ARCH="amd64" ;;
esac

CHD_SUPPORTED_DISTROS="alpine arch artix debian deepin fedora manjaro openkylin opensuse pardus ubuntu void kali parrot backbox centos_stream rocky adelie chimera gentoo"

# --- rootfs base URLs (upstream, proven) -----------------------------------
proot_distro_rootfs_base_url=https://github.com/termux/proot-distro/releases/download
anlinux_rootfs_base_url=https://github.com/EXALAB/Anlinux-Resources
debian_rootfs_base_url_prootdistro=$proot_distro_rootfs_base_url
openkylin_rootfs_base_url=$proot_distro_rootfs_base_url/v4.10.0
pardus_rootfs_base_url=$proot_distro_rootfs_base_url/v4.18.0
opensuse_rootfs_base_url=$proot_distro_rootfs_base_url/v4.21.0
artix_rootfs_base_url=$proot_distro_rootfs_base_url/v4.6.0
deepin_rootfs_base_url=$proot_distro_rootfs_base_url/v4.16.0
rocky_rootfs_base_url=$proot_distro_rootfs_base_url/v4.20.0
ubuntu_rootfs_base_url=https://cdimage.ubuntu.com/ubuntu-base/releases
kali_rootfs_base_url=http://kali.download/nethunter-images
alpine_rootfs_base_url=http://dl-cdn.alpinelinux.org/alpine/latest-stable/releases
void_rootfs_base_url=https://repo-default.voidlinux.org/live/current
archlinux_rootfs_base_url_arm=http://ca.us.mirror.archlinuxarm.org/os
archlinux_rootfs_base_url=https://mirrors.ocf.berkeley.edu/archlinux/iso/latest
adelie_rootfs_base_url=https://distfiles.adelielinux.org/adelie/1.0-beta6/iso
gentoo_rootfs_base_url=https://distfiles.gentoo.org/releases
chimera_rootfs_base_url=https://repo.chimera-linux.org/live/latest
debian_rootfs_base_url_anlinux=$anlinux_rootfs_base_url/raw/master/Rootfs/Debian
parrot_rootfs_base_url=$anlinux_rootfs_base_url/raw/master/Rootfs/Parrot
backbox_rootfs_base_url=$anlinux_rootfs_base_url/raw/master/Rootfs/BackBox
centos_stream_rootfs_base_url=$anlinux_rootfs_base_url/raw/master/Rootfs/CentOS_Stream

chd_download_supported() { echo "$CHD_SUPPORTED_DISTROS"; }

chd_download_check_supported() {
    for _d in $CHD_SUPPORTED_DISTROS; do
        [ "$_d" = "$1" ] && return 0
    done
    print_message error "The distribution '$1' is not supported."
    return 1
}

chd_rootfs_archive_name() {
    if [ -n "$2" ]; then printf '%s-%s.tar.xz' "$1" "$2"; else printf '%s.tar.xz' "$1"; fi
}

chd_rootfs_archive_path() {
    printf '%s/.rootfs/%s' "$CHD_ROOT" "$(chd_rootfs_archive_name "$1" "$2")"
}

# arch translation helpers used by several distros
_chd_arch_pd()   { echo "$CHD_ARCH" | sed 's/arm64/aarch64/;s/amd64/x86_64/;s/i386/i686/;s/armhf/arm/'; }
_chd_arch_glibc(){ echo "$CHD_ARCH" | sed 's/arm64/aarch64/g;s/amd64/x86_64/g;s/i386/i686/g;s/armhf/armv7/g'; }

# Resolve a download URL for <distro> [suite]. Echoes URL on stdout, or empty.
chd_resolve_url() {
    distro="$1"; suite="$2"; url=""; arch="$CHD_ARCH"
    case "$distro" in
      ubuntu)
        release="${suite:-noble}"
        version="$(wget -qO- "${ubuntu_rootfs_base_url}/${release}/release/" | grep -oE "ubuntu-base-[0-9]+(\.[0-9]+)*-base-${arch}\.tar\.gz" | head -n 1 | sed -E 's/ubuntu-base-([0-9]+(\.[0-9]+)*)-base-.*/\1/')"
        url="${ubuntu_rootfs_base_url}/${release}/release/ubuntu-base-${version}-base-${arch}.tar.gz" ;;
      alpine)
        a="$(echo "$arch" | sed 's/arm64/aarch64/g;s/amd64/x86_64/g;s/i386/x86/g')"
        url="${alpine_rootfs_base_url}/${a}/$(wget -qO- "${alpine_rootfs_base_url}/${a}/" | grep -oE "alpine-minirootfs-[0-9]+\.[0-9]+\.[0-9]+-${a}\.tar\.gz" | sed 's/.*-\([0-9]\+\.[0-9]\+\.[0-9]\+\)-.*/\1 &/' | sort -t. -k1,1nr -k2,2nr -k3,3nr | head -n1 | cut -d' ' -f2-)" ;;
      kali)
        rootfs="${suite:-minimal}"
        url="${kali_rootfs_base_url}/current/rootfs/kali-nethunter-rootfs-${rootfs}-${arch}.tar.xz" ;;
      debian)
        rootfs="${suite:-debian_bookworm}"
        case "$rootfs" in
          debian)          url="$debian_rootfs_base_url_anlinux/${arch}/debian-rootfs-${arch}.tar.xz" ;;
          debian_bullseye) url="${debian_rootfs_base_url_prootdistro}/v4.7.0/debian-bullseye-$(_chd_arch_pd)-pd-v4.7.0.tar.xz" ;;
          debian_bookworm) url="${debian_rootfs_base_url_prootdistro}/v4.17.3/debian-bookworm-$(_chd_arch_pd)-pd-v4.17.3.tar.xz" ;;
          debian_trixie)   url="${debian_rootfs_base_url_prootdistro}/v4.26.0/debian-trixie-$(_chd_arch_pd)-pd-v4.26.0.tar.xz" ;;
        esac ;;
      parrot)  url="$parrot_rootfs_base_url/${arch}/parrot-rootfs-${arch}.tar.xz" ;;
      arch)
        case "$arch" in
          amd64)        url="${archlinux_rootfs_base_url}/archlinux-bootstrap-x86_64.tar.zst" ;;
          armhf|arm64)  url="${archlinux_rootfs_base_url_arm}/ArchLinuxARM-$(echo "$arch" | sed 's/arm64/aarch64/;s/armhf/armv7/')-latest.tar.gz" ;;
        esac ;;
      artix)   url="${artix_rootfs_base_url}/artix-aarch64-pd-v4.6.0.tar.xz" ;;
      deepin)  url="${deepin_rootfs_base_url}/deepin-$(echo "$arch" | sed 's/arm64/aarch64/;s/amd64/x86_64/')-pd-v4.16.0.tar.xz" ;;
      fedora)
        rel="${suite:-v4.24.0}"
        url="${proot_distro_rootfs_base_url}/${rel}/fedora-$(echo "$arch" | sed 's/arm64/aarch64/;s/amd64/x86_64/')-pd-${rel}.tar.xz" ;;
      openkylin) url="${openkylin_rootfs_base_url}/openkylin-$(echo "$arch" | sed 's/arm64/aarch64/;s/amd64/x86_64/')-pd-v4.10.0.tar.xz" ;;
      rocky)     url="${rocky_rootfs_base_url}/rocky-$(echo "$arch" | sed 's/arm64/aarch64/;s/amd64/x86_64/')-pd-v4.20.0.tar.xz" ;;
      chimera)
        rootfs="${suite:-bootstrap}"
        version="$(wget -qO- "${chimera_rootfs_base_url}" | grep -oE "chimera-linux-$(echo "$arch" | sed 's/arm64/aarch64/;s/amd64/x86_64/')-ROOTFS-[0-9]{8}-${rootfs}\.tar.gz" | sed -E "s/.*ROOTFS-([0-9]{8})-${rootfs}\.tar\.gz/\1/" | head -n 1)"
        url="${chimera_rootfs_base_url}/${version}" ;;
      adelie)
        rootfs="${suite:-mini}"
        version="$(wget -qO- "$adelie_rootfs_base_url" | grep -oE "adelie-rootfs-${rootfs}-$(_chd_arch_glibc)-[^\" ]+-[0-9]{8}\.txz" | sed -E 's/.*-([0-9]{8})\.txz/\1/' | head -n 1)"
        url="${adelie_rootfs_base_url}/adelie-rootfs-${rootfs}-$(_chd_arch_glibc)-1.0-beta6-${version}.txz" ;;
      manjaro) url="$(wget -qO- https://api.github.com/repos/manjaro-arm/rootfs/releases/latest | grep 'browser_download_url' | cut -d '"' -f 4 | head -n1)" ;;
      opensuse) url="${opensuse_rootfs_base_url}/opensuse-$(_chd_arch_pd)-pd-v4.21.0.tar.xz" ;;
      pardus)   url="${pardus_rootfs_base_url}/pardus-$(_chd_arch_pd)-pd-v4.18.0.tar.xz" ;;
      backbox)  url="$backbox_rootfs_base_url/${arch}/backbox-rootfs-${arch}.tar.xz" ;;
      centos_stream) url="${centos_stream_rootfs_base_url}/${arch}/centos_stream-rootfs-${arch}.tar.xz" ;;
      gentoo)
        ga="$(echo "$arch" | sed 's/armhf/arm/')"
        version=$(wget -qO- "${gentoo_rootfs_base_url}/${ga}/autobuilds/current-stage3-${ga}-openrc/" | sed -n 's/.*href="\([^"]*\)".*/\1/p' | grep '^stage3.*\.xz$' | head -n1)
        url="${gentoo_rootfs_base_url}/${ga}/autobuilds/current-stage3-${ga}-openrc/${version}" ;;
      void)
        va="$(echo "$arch" | sed 's/arm64/aarch64/g;s/amd64/x86_64/g;s/i386/i686/g;s/armhf/armv7l/g')"
        url="${void_rootfs_base_url}/void-${va}-ROOTFS-$(wget -qO- ${void_rootfs_base_url}/ | grep -oE 'void-.*-ROOTFS-[0-9]+\.tar\.xz' | head -n 1 | sed -E 's/.*-ROOTFS-([0-9]+)\.tar\.xz/\1/').tar.xz" ;;
    esac
    printf '%s' "$url"
}

# chd_download <distro> [suite] [force]
chd_download() {
    distro="$1"; suite="${2:-}"; force="${3:-}"
    chd_download_check_supported "$distro" || return 1

    url="$(chd_resolve_url "$distro" "$suite")"
    if [ -z "$url" ]; then
        print_message error "No rootfs URL for '$distro' on arch '$CHD_ARCH'."
        return 1
    fi
    print_message info "Distribution : $distro ${suite:+($suite)}"
    print_message info "Download link: $url"

    if ! wget --spider -q -T 10 -t 1 "$url"; then
        print_message error "Cannot reach URL: $url"
        print_message note "Check connectivity, or arch '$CHD_ARCH' may be unsupported for this distro."
        return 1
    fi

    archive_path="$(chd_rootfs_archive_path "$distro" "$suite")"
    mkdir -p "$CHD_ROOT/.rootfs"
    if [ -f "$archive_path" ]; then
        if [ "$force" = "yes" ] || [ "$force" = "force" ]; then
            rm -f "$archive_path"
        else
            print_message info "Rootfs archive already present: $archive_path (use force to re-download)"
            return 0
        fi
    fi

    if ! wget -O "$archive_path" "$url"; then
        print_message error "Download failed for '$distro'."
        [ -e "$archive_path" ] && rm -f "$archive_path"
        return 1
    fi
    print_message info "Rootfs downloaded: $archive_path"
    return 0
}

chd_download_if_needed() {
    distro="$1"; suite="${2:-}"
    archive_path="$(chd_rootfs_archive_path "$distro" "$suite")"
    if [ -f "$archive_path" ]; then
        print_message info "Rootfs already present: $archive_path"
        return 0
    fi
    chd_download "$distro" "$suite"
}
