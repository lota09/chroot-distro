# chd (chroot-distro) 재구축 계획서

> 승인 후 코드 작성 시작. 이 문서가 유일한 사양 기준이며,
> 여기 없는 동작 변경은 하지 않는다.

---

## 0. 대원칙

원본(chroot-distro 3.1.9, 3688줄 단일 파일)에서 **바꾸는 것은 딱 두 가지**:

1. **모듈화** — 단일 파일을 기능별 lib 모듈로 분리 (디버깅/유지보수 목적)
2. **서비스 재구성** — chd_startup.sh 방식 → supervisord (chroot 내 systemctl 대체)

**그 외 모든 동작·명령어·프로파일 구조·이미지 모드는 원본과 동일하게 보존한다.**
단, 사용자가 명시적으로 결정한 항목(아래 1장)만 예외.

---

## 1. 확정 사양 (사용자 결정 사항)

### 1-1. 명령어 세트 (최종)

| 명령 | 상태 | 비고 |
|---|---|---|
| `help` | 유지 | |
| `list` | 유지 | **트리 구조** 출력: 프로파일 -> 인스턴스 상태 (1-7장) |
| `profile [name]` | **원상복구** | 원본 마법사 전체, 번호 메뉴 (1-2장) |
| `install [--no-init] [--no-img] <profile>` | **원상복구** | 템플릿 읽기 + 이미지모드. 단 **jail 자동진입 없음**(결정 F) |
| `login <name>` | 유지 | mount → 서비스 → root 쉘 |
| `command <name> "<cmd>"` | 유지 | login과 동일 경로, 명령 실행 |
| `mount <name>` | **복구** | 이미지+시스템 마운트만, 진입 없음 |
| `unmount <name\|all> [-f]` | **복구** | -f: 프로세스 강제 종료 후 해제 |
| `uninstall <name> [-f] [--include-profile]` | 유지 | 인스턴스 **하나** 삭제(+img). 원본 플래그 복구 |
| `backup [name] [path]` | **통합** | restore/unbackup 흡수 (1-3장) |
| `rename <old> <new>` | **복구** | 원본 동작 (dir+conf+backup 이동) |
| `debug` | **복구+개명** | 구 `env`. 환경 진단 출력 |
| ~~`remove`~~ | **제거** | suite 전체 삭제는 위험, uninstall로 충분 |
| ~~`add`~~ | **제거** | 커스텀 distro 불필요 |
| ~~`download`~~ | **제거** | install이 자동 다운로드 |
| ~~`delete`~~ | **제거** | 아카이브 정리는 수동 |
| ~~`restore`~~ / ~~`unbackup`~~ | **backup에 흡수** | |
| ~~`ram-bind`~~ / ~~`android-bind`~~ | **제거 — 고정 동작** | ram-mount y / storage-mount y / android-mount n (1-5장) |

### 1-2. profile 마법사 (원본 흐름 + 번호 메뉴)

```
chd profile <이름>
 1) Distribution        [번호 메뉴: 지원 20종]
 2) Suite/variant       [번호 메뉴: distro별. ubuntu=noble/jammy/..., debian=bookworm/...]
 3) User name           [자유입력, 기본 user]           (비밀번호는 changeme 고정, 원본과 동일)
 4) Graphics Mode       [1] Headless  [2] Termux-X11  [3] X11+VNC (기본 3, 원본과 동일)
 5) Desktop             [1] LXDE(권장) [2] XFCE [3] LXQt [4] MATE [5] GNOME [6] KDE
                        (Headless면 생략, virgl 자동 on)
 6) SSH                 [y/n, 기본 y]
 7) PulseAudio          [y/n, 기본 y]
 8) 고급 옵션?           [y/n, 기본 n]  ← n이면 아래 전부 기본값
    - GPU가속(virgl)    [y/n]
    - Target type       [1] file(.img — 삼성/FDE 필수) [2] dir  (기본 file)
    - (file일 때) 이미지 경로 [기본 /sdcard/<이름>.img]
    - (file일 때) 이미지 크기 [기본 131072 MB = 128GB, sparse]
    - (file일 때) 파일시스템  [1] ext4 [2] f2fs [3] xfs
    - Arch              [기본 자동감지 arm64]
 → 저장: $CHD_ROOT/.profile/<이름>.conf  (템플릿)
```

- 기존 템플릿이 있으면 로드해서 **기본값으로 사용** (편집 모드, 원본 동작)
- 비대화형: `chd profile <이름> <distro> [suite] [graphics] [desktop]` — 스크립트/테스트용
- 어느 메뉴든 `q` 입력 시 취소

### 1-3. backup 통합 UX

```
chd backup                     # 대화형
 ├─ 기존 백업 있음 → [1] 새 백업 생성  [2] 기존 백업 관리
 │    ├─ [1] → 설치된 인스턴스 번호 메뉴 → 생성
 │    └─ [2] → 백업 번호 메뉴 → [1] 복원  [2] 삭제
 │         ├─ 복원: 대상 인스턴스가 이미 있으면 덮어쓰기 y/n 확인
 │         │        (확인 시 안전 uninstall 후 복원. 복원 후 jail 진입 없음)
 │         └─ 삭제: y/n 확인 후 아카이브 삭제
 └─ 기존 백업 없음 → 바로 인스턴스 번호 메뉴 → 생성

chd backup <인스턴스> [경로]     # 비대화형: 메뉴 없이 즉시 새 백업 생성
```

- 저장 위치: `$CHD_ROOT/.backup/<이름>.tar.xz` (원본과 동일)
- 백업 내용: 인스턴스 rootfs + `.config/<이름>.conf` (원본과 동일)
- 백업 전 자동 unmount 시도. 마운트가 남아 있으면 **거부** (원본은 수동 안내였으나
  안전상 자동 시도로 개선 — 파일 정합성 목적, 동작 결과는 동일)
- 복원 로직: 원본의 common-path 검증 (신형식/구형식/오염 아카이브 판별) 그대로 포팅

### 1-4. 이미지 모드 (.img) — 삼성 FDE 대응 [최우선]

원본 `chroot_distro_mount_rootfs_image` 충실 포팅:

- `TARGET_TYPE=file`(기본)일 때 인스턴스 rootfs는 `.img` 루프마운트 **안**에 존재
- 이미지 없으면: `truncate -s <크기>M` (sparse) → `mke2fs -t ext4` (f2fs/xfs는 mkfs.* 있으면)
- 마운트: `mount -o rw,relatime` → 실패 시 `mount -t ext4 -o loop,rw,relatime` (원본 2단계)
- 마운트 후 `mount -o remount,exec,suid,dev` (FDE/noexec 우회, 원본과 동일)
- **install 시 추출 전에 이미지가 먼저 마운트**되어야 함 (순서 보장)
- unmount 시 `losetup -d`로 루프 디바이스 해제
- uninstall 시 이미지 파일도 삭제 (원본과 동일)

### 1-5. 마운트 설정 3분리 (프로파일 고급 설정)

구 ram-bind/android-bind를 역할 기준으로 3개로 분리하되, **마법사에서 묻지 않고
고정 동작한다** (최종 결정). 디버깅용 숨은 env 오버라이드만 존재.

| 키 (질문 순서대로) | 기본 | 마운트 대상 | 역할 / 근거 |
|---|---|---|---|
| ram-mount | **y 고정** | /tmp /run /var/tmp /dev/shm 에 tmpfs (/tmp 1777) | 정상 리눅스 부팅과 동일(/run은 원래 tmpfs). /dev/shm 없으면 브라우저·데스크탑 공유메모리 깨짐. distro 자체 /tmp를 shadow할 뿐 충돌 없음 |
| storage-mount | **y 고정** | /sdcard + /storage/* | 파일 교환. 사고 반경 작음 |
| android-mount | **n 고정** | 그 외 안드로이드 최상위 디렉터리(/data /system /vendor /apex /mnt ...) — distro 자신의 디렉터리·FBE 키 디렉터리는 스킵목록으로 제외 | 안드로이드 내부 열람용. **기본 꺼짐**: 켜면 chroot 안 사고(rm 등)의 폭발 반경이 기기 전체가 되고, 삭제/백업 안전 관리 비용 증가. GPU·데스크탑·오디오는 이것 없이 동작(전용 bind/코어 /dev 사용) |

- env 오버라이드: CHD_RAM_MOUNT=0 / CHD_STORAGE_MOUNT=0 / CHD_ANDROID_MOUNT=1 (문서에만, 마법사 노출 없음)
- uninstall의 "마운트 잔존 시 삭제 거부" 안전장치는 유지 (android-mount=y 대비)

### 1-6. 기타 확정 동작

| 항목 | 결정 |
|---|---|
| install 후 jail 진입 | **안 함** — "chd login <이름>" 안내만 (mount와 유사) |
| jail | 순수 원시연산 (chroot + su - root). 서비스 시작 안 함 |
| env/gpuacc/proc-smi | init에서 1회 생성 + **login 시 없으면 재생성(self-heal)** |
| install 멱등성 | 유지 — 이미 추출됐으면 스킵, init 재실행 가능 (기존 합의) |
| 서비스 | supervisord (root, 소켓 0700, program별 user= 강등, 독립 program) |
| 호스트 서비스 | pulse/virgl/x11 — Termux 컨텍스트에서 실행, login 시 기동 (기존 합의) |
| GPU | 데스크탑 xstartup이 **런타임에** virgl 소켓 확인 → virpipe/softpipe 자동 (기존 합의) |
| uninstall 안전장치 | 인스턴스 하위 마운트가 하나라도 남으면 rm 거부 (실 /data 삭제 사고 방지) — 유지 |
| uninstall 시 .img | **당연 삭제** (file 모드 인스턴스 = 이미지가 본체) — 확정 |

### 1-7. list 트리 출력

프로파일(템플릿)을 뿌리로, 설치 상태를 트리로 표시:

```
chd list
Profiles & instances  ($CHD_ROOT)
├─ ubuntu_noble   ubuntu/noble   [installed · file:/sdcard/ubuntu_noble.img · 4.2G]
│   └─ services: sshd cron desktop x11vnc   (supervisord up)
├─ mydeb          debian/bookworm [installed · dir]
└─ testprof       kali/minimal    [not installed → chd install testprof]
```

- 1행: 이름, distro/suite, 설치 여부, target(file이면 img 경로+실사용량 / dir)
- 설치본은 services 줄 추가 (supervisord 살아있을 때 program 목록)
- 템플릿 없이 rootfs만 있는 고아 인스턴스도 표시 ("(no profile)")

---

## 2. 모듈 구조 (최종)

```
system/bin/chroot-distro    엔트리: lib 소싱 + dispatch (얇게)
system/bin/chd              래퍼 → chroot-distro
lib/util.sh                 로깅, 공용 헬퍼, 마운트 판정(/proc/mounts), 예약이름
lib/mount.sh                시스템 마운트 (RAM_BIND/ANDROID_BIND 반영), 전체 해제+검증
lib/image.sh                .img 생성/포맷/루프마운트/해제           [신규]
lib/jail.sh                 chroot+su 진입 (순수) + resolv.conf/localtime fix
lib/download.sh             rootfs URL 20종 (원본 문자단위 동일) + 다운로드 (내부용)
lib/profile.sh              마법사(원본 흐름·번호메뉴) + .profile 템플릿 + conf 로드
lib/instance.sh             install/login/command/mount/unmount/uninstall/rename/list
lib/backup.sh               backup 통합 UX (생성/관리→복원/삭제)      [신규]
lib/debug.sh                debug 명령 (구 env)                      [신규]
lib/supervisor.sh           게스트 supervisord 프레임워크 (기존, 검증 완료)
lib/services.sh             호스트 pulse/virgl/x11 + supervisord 보장 (기존, 검증 완료)
lib/distro/common.sh        init 프레임워크 + 서비스 등록 + xstartup 생성 (기존)
lib/distro/debian.sh        Debian/Ubuntu init 백엔드 (기존)
scripts/guest/init_debian.sh  게스트 apt init (기존, 리질리언트)
scripts/host/host_start_*.sh  virgl/pulse/x11 (기존, 검증된 하드닝 버전)
deploy_chd.py               Python zip 빌드 → push → magisk 설치 → 검증
```

### debug 출력 항목
버전/versionCode, 스크립트 경로+md5, arch, CHD_ROOT, toybox/busybox 경로·버전,
tar xz 지원 여부, 설치된 인스턴스, .rootfs 아카이브 목록, CHD_ROOT 하위 마운트,
losetup -a, Termux/Termux:X11 설치 여부

---

## 3. 작업 순서 (승인 후)

| 단계 | 내용 | 검증 |
|---|---|---|
| 1 | profile.sh — 마법사+템플릿층+bind 키 | 메뉴 파이프 입력 시뮬, 템플릿 필드 전수 확인 |
| 2 | image.sh + mount.sh bind 키 반영 | (VM) 생성/포맷/마운트 로직, sparse 확인 |
| 3 | instance.sh — 템플릿 install·이미지모드·플래그·mount/unmount/rename | 흐름 시뮬 (chroot 스텁) |
| 4 | backup.sh — 통합 UX + 원본 복원 로직 | 생성/복원/삭제/거부 시나리오 |
| 5 | debug.sh + 엔트리 dispatch 갱신 | dispatch 회귀 |
| 6 | 전체 회귀 (sh -n, CRLF, 변수충돌 기계감사, zip 검증) | 게이트 통과 |
| 7 | 배포 → 실기 테스트 (마법사→install→login→apt→서비스) | 실기 |

**코드 위치 (확정):** `chd_rb2`에서 **새로 시작**. 디렉터리 구조는 2장 기준으로 재설계.
chd_reborn의 검증 완료 모듈(supervisor/services/distro/host scripts/deploy)은 검토 후
가져오되, 이 계획서 사양과 대조 검증한 것만 반입. chd_reborn은 참고용으로만 보존.

---

## 4. 결정 이력

| 질문 | 결정 |
|---|---|
| 코드 위치 | chd_rb2 새로 시작, 구조 재설계 허용 |
| uninstall 시 .img | 당연 삭제 |
| list 미설치 프로파일 | 유지, 트리 구조로 (1-7장) |
| debug 출력 항목 | 작성자 판단 (2장 목록) |
| 마운트 설정 | 질문 없음, 고정: ram-mount y / storage-mount y / android-mount n (1-5장) |

*이 계획서 밖의 동작 변경은 하지 않습니다. 변경이 필요해지면 먼저 물어봅니다.*

## 부록: 데스크탑 렌더 백엔드 (DESKTOP_BACKEND) — 사후 결정

원본은 "LXDE 전체를 virpipe로 돌리면 블랙스크린"이라 softpipe 세션을 하드코딩했으나,
그건 이 기기+LXDE 한 관측을 모든 데스크탑·환경에 과잉 일반화하는 문제가 있었다.
소켓 존재만 보는 "자동"은 판정 근거가 틀렸다(소켓이 있어도 세션은 깨질 수 있음).
결론: 마법사에서 사용자에게 명시적으로 묻는다.

- 마법사 흐름: graphics(headless/x11/x11+vnc) → desktop(headless면 생략) →
  **Desktop rendering backend**: [1] softpipe (CPU, stable) [2] virpipe (GPU, may be unstable). 기본 1.
- headless면 백엔드 질문 없음. conf 키 `DESKTOP_BACKEND` (softpipe|virpipe|"").
- 데스크탑 **세션**만 이 선택을 따른다. virpipe 선택이라도 소켓 부재 시 softpipe로 자가폴백.
- `VIRGL_ENABLE`(호스트 virgl 스택)과 별개 — softpipe 세션이라도 개별 앱은 `gpuacc <app>`으로 GPU.
- 셸 로그인 env(/etc/profile.d/chd_env.sh)는 소켓 있으면 virpipe(앱 단위라 안전).
