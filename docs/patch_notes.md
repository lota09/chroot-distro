# chroot-distro 버그 수정 및 패치 노트

본 문서는 `system/bin/chroot-distro` 내에 존재하던 논리적 오류(버그)의 원인과 이를 어떻게 해결하고 코드를 수정했는지에 대한 상세 내역을 담고 있습니다.

## 1. 동적 마운트의 시스템 언마운트 누락(Leak) 버그

### 🔴 문제점 파악
`chroot-distro`는 실행 성능 최적화 및 FBE 환경 우회 등을 위해 `/sdcard`, `tmpfs`, Arch Linux의 `pacman` self-bind 마운트 등을 지원합니다. 이들은 **마운트 함수(`chroot_distro_mount_system_points`) 실행 시 전역 변수인 `system_points`에 동적으로 텍스트가 추가**되며 마운트됩니다.

하지만 보통 사용자가 마운트 해제(`chd unmount`)를 명령할 때는 쉘이 새로 실행되는 환경이므로, `chroot_distro_unmount_system_points` 함수를 호출할 때 동적할당되었던 `system_points` 목록들이 모두 초기화되어 있는 상태가 됩니다. (즉 기본 시스템 포인트인 `/dev /sys /proc /dev/pts`만 가지고 있습니다). 이로 인해 **안드로이드 공유 폴더 및 패키지 관리용 마운트들이 언마운트 되지 못하고 계속 남게 되는 심각한 마운트 누수(Leak)**가 발생했습니다.

또한 Arch Linux의 `pacman` 지원용 self-bind 마운트 로직(`system_points="${distro_path} ${system_points}"`)이 정상적으로 `unmount` 단계까지 도달하더라도, 파일 경로 조합 시 `$distro_path$point` 코드로 인해 `$distro_path$distro_path`라는 중복된 경로 문자열이 생성되어 정상적인 언마운트가 실패하는 문법적 허점도 있었습니다.

### 🟢 해결 방안
`chroot_distro_unmount_system_points` 내부에서도 마운트 때와 완벽히 동일하게 `android_bind_val`, `ram_bind_val`, `pacman`의 조건부 변수들을 재평가하여 `system_points`를 올바르게 복원하도록 추가했습니다. 역순 정렬 시 중복을 방지하기 위해 `sort -ru`를 적용하였으며, self-bind (`$distro_path`) 경로가 감지될 경우에는 경로 중복 결합 오류를 피하기 위한 예외 처리 분기문을 추가했습니다.

동일한 중복 문제를 예방하기 위해 `chroot_distro_mount_system_points` 함수에서도 마운트 추가 시 변수 스트링이 중복 할당되지 않도록 `grep -q` 문을 방어적으로 삽입해 보강했습니다.

### 💻 코드 변경 내역 (chroot_distro_unmount_system_points)

**기존 코드 (수정 전)**
```sh
chroot_distro_unmount_system_points() {
    distro_path="$1"
    force="$2"
    system_points=$(echo $system_points | tr ' ' '\n' | sort -r | tr '\n' ' ')
    for point in $system_points; do
        chroot_distro_unmount_system_point "$distro_path$point" "$force"
    done
} 
```

**변경 코드 (수정 후)**
```sh
chroot_distro_unmount_system_points() {
    distro_path="$1"
    force="$2"
    # 1. 누락되었던 동적 마운트 포인트 변수 복원
    if [ "1" = "$android_bind_val" ]; then
        mount_android_dirs
    fi
    if [ "1" = "$ram_bind_val" ]; then
        for d in /tmp /run /var/tmp /dev/shm; do
            echo " $system_points " | grep -q " $d " || system_points="$system_points $d"
        done
    fi
    if [ -f "${distro_path}/usr/bin/pacman" ] || [ -f "${distro_path}/bin/pacman" ] || [ -f "${distro_path}/usr/local/bin/pacman" ]; then
        echo " $system_points " | grep -q " ${distro_path} " || system_points="${distro_path} ${system_points}"
    fi
    
    # 2. 중복 방지 (sort -ru) 적용
    system_points=$(echo $system_points | tr ' ' '\n' | sort -ru | tr '\n' ' ')
    
    # 3. 경로 결합 오류 방지
    for point in $system_points; do
        if [ "$point" = "$distro_path" ]; then
            chroot_distro_unmount_system_point "$distro_path" "$force"
        else
            chroot_distro_unmount_system_point "$distro_path$point" "$force"
        fi
    done
} 
```

### 💻 코드 변경 내역 (chroot_distro_mount_system_points)

**기존 코드 (수정 전)**
```sh
chroot_distro_mount_system_points() {
    if [ "${CHROOT_DISTRO_MOUNT:-}" = "false" ]; then
       return
    fi
    chroot_distro_mount_rootfs_image
    distro_path="$1"
    if [ "1" = "$android_bind_val" ]; then
        mount_android_dirs
    fi
    if [ "1" = "$ram_bind_val" ]; then
        system_points="$system_points /tmp /run /var/tmp /dev/shm"
    fi
    if [ -f "${distro_path}/usr/bin/pacman" ] || [ -f "${distro_path}/bin/pacman" ] || [ -f "${distro_path}/usr/local/bin/pacman" ]; then
        system_points="${distro_path} ${system_points}"
    fi
    for point in $system_points; do
        chroot_distro_mount_system_point "$distro_path" "$point" "$distro_path$point"
    done
}
```

**변경 코드 (수정 후)**
```sh
chroot_distro_mount_system_points() {
    if [ "${CHROOT_DISTRO_MOUNT:-}" = "false" ]; then
       return
    fi
    chroot_distro_mount_rootfs_image
    distro_path="$1"
    if [ "1" = "$android_bind_val" ]; then
        mount_android_dirs
    fi
    if [ "1" = "$ram_bind_val" ]; then
        for d in /tmp /run /var/tmp /dev/shm; do
            echo " $system_points " | grep -q " $d " || system_points="$system_points $d"
        done
    fi
    if [ -f "${distro_path}/usr/bin/pacman" ] || [ -f "${distro_path}/bin/pacman" ] || [ -f "${distro_path}/usr/local/bin/pacman" ]; then
        echo " $system_points " | grep -q " ${distro_path} " || system_points="${distro_path} ${system_points}"
    fi
    for point in $system_points; do
        chroot_distro_mount_system_point "$distro_path" "$point" "$distro_path$point"
    done
}
```

---

## 2. 안드로이드 특수 그룹(gid) 주입 중복 버그

### 🔴 문제점 파악
디바이스 권한(FBE 시스템 보호 한계 극복)을 위해 chroot 진입 전 `/etc/group` 내에 미리 안드로이드 시스템 식별 그룹(`aid_*`)들을 써넣어 주는 `prepare_chroot_distro()` 함수 부분에서 `1003 aid_graphics` 라인이 코딩 실수로 두 줄 중복 출력되는 사소한 실수가 있었습니다.

### 🟢 해결 방안
중복 기재된 `echo "1003 aid_graphics"` 줄 중 하나를 삭제하여 문법적 오류를 없앴습니다.

### 💻 코드 변경 내역

**기존 코드 (수정 전)**
```sh
       echo "3003 aid_inet"
       echo "3004 aid_net_raw"
       echo "1003 aid_graphics"
       echo "1003 aid_graphics" # <- 중복 라인
       echo "1004 aid_input"
       echo "1005 aid_audio"
```

**변경 코드 (수정 후)**
```sh
       echo "3003 aid_inet"
       echo "3004 aid_net_raw"
       echo "1003 aid_graphics"
       echo "1004 aid_input"
       echo "1005 aid_audio"
```

---

## 3. 안내 메시지 변수 이스케이프(Escape) 버그 

### 🔴 문제점 파악
사용자에게 CLI 환경에서 도움말이나 피드백을 전달하는 `print_message note` 부분에서 사용 예시 안내를 할 때, 스크립트 실행자 변수인 `$script` 앞에 백슬래시(`\`)가 들어가 있었습니다.

*예시 문장*: `"You can use '\$script install $INSTANCE_NAME' to install the instance."`

셸 스크립트에서 큰따옴표(`""`) 안의 `\$script`는 변수가 확장(치환)되지 않고 백슬래시 문법으로 해석되어 리터럴 문자열인 `$script` 자체를 그대로 터미널에 노출시킵니다. 따라서 사용자는 올바른 명령어(`chroot-distro install 명칭`) 대신 `You can use '$script install 명칭'` 이라는 어색한 가이드라인을 보게 됩니다.

### 🟢 해결 방안
불필요한 백슬래시(`\`)를 모두 제거하여 런타임 환경에서 `$script` 변수가 실제 자신이 동작하는 메인 실행파일의 이름으로 정상 표출되도록 바꾸었습니다. (수정된 포인트: `unbackup`, `backup`, `uninstall`, `install` 명령어 오류 메시지 등 도합 7곳)

### 💻 코드 변경 내역

**기존 코드 (수정 전)**
```sh
# (총 7곳의 유사코드 모두)
print_message note "You can use '\$script install $INSTANCE_NAME' to install the instance."
```

**변경 코드 (수정 후)**
```sh
# (총 7곳의 유사코드 모두 수정)
print_message note "You can use '$script install $INSTANCE_NAME' to install the instance."
```
