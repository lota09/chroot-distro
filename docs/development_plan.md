# chroot-distro development plan

## 1) Planned features (updated)

- Config-driven setup (profile-based) with interactive prompts
- Safe stop/unmount: full cleanup without system damage
- Termux GPU setup: host + chroot wiring for acceleration (termux-only)

## 2) Commands (alias: chd)

### chd profile [profile_name]

- Store profiles at /data/local/chroot-distro/.profile/<name>.conf
- If no argument:
  - If profiles exist: show options (edit existing or create new)
  - If no profiles: go straight to create
- Create flow:
  - Ask for profile name
  - Prompt for distro, ssh/vnc enable + settings, user/pass, etc.
  - Defaults: default.conf for new profile, existing profile for edits
  - Write <name>.conf

### chd install <profile_name>

- Merges download + install flow using profile settings
- Per-distro init script dispatch (example: ubuntu -> chroot_ubuntu_init.sh)
- Init script runs by default; can be disabled with --no-init
- --no-profile keeps legacy flow

Examples:
- chd install --no-profile --no-init ubuntu
  - Legacy behavior: no download, no init
- chd install --no-profile ubuntu
  - Legacy behavior with init
- chd install --no-init my_profile
  - Profile-based install, skip init

### chd download [--no-profile] <distro>

- --no-profile: legacy download (no prompt)
- Without --no-profile:
  - Profile-based download, no prompts
  - Uses profile to decide distro and target paths

## 3) Focus areas

- chd login as primary entry point
- Safe mount/unmount handling and idempotent behavior

## 4) Deferred / pending

- Support multiple instances per distro via profile-based names
- Add chd setgpu ubuntu (termux-only)
- chd login : mount if needed

## 5) Added / Modified Functions & Commands
### Modified

- chroot-distro mount/login/command/unmount
  - System mount points are now auto-mounted on entry (login/command/install) and unmounted on uninstall
  - Added a final residual mount/loopback check after unmount to prevent unsafe removal if anything remains mounted

- chroot-distro list
  - Sanitizes map variable names derived from filesystem entries to avoid errors with names like lost+found
  - Prevents eval errors when non-alnum characters exist in directory names

- chroot-distro mount (image support)
  - Rootfs image mount now retries with explicit ext4 + loop options for Android builds that require it

- docs/chroot_distro_ubuntu_init.sh
  - Now supports Linux Deploy-style conf mapping and INCLUDE-based toggles
  - Optional SSH/Pulse/VNC/X11 and desktop profiles (xfce/lxde/mate/xterm/kde)
  - Verbose debug tracing and step-by-step logging for deterministic runs
  - User creation aligned with Ubuntu default (adduser) and safe chown using primary group

### Added

- chroot-distro/docs/development_plan.md updates
  - Reworked plan toward profile-based config-driven setup
  - Removed deprecated post-setup automation plan
## 새로 추가할 기능 및 명령
### 1. `chd profile`
- /data/local/chroot-distro/.profile 에 프로파일파일 my_profile.conf 을 만드는 명령(이름은 사용자 지정) 
- 명령흐름 : 
  1. (인자가 없는경우) 기존프로필이 있는경우 기존프로필 개수 +1개의 옵션 : 기존 프로필 수정 + 새로운 프로필 생성 (chd profile my_profile 처럼 인자가 있으면 a옵션 건너뜀)
  2. (새로운 프로필 생성만 해당)profile이름 묻기 - 이 이름에 따라 my_profile.conf 파일의 이름이 결정됨
  3. 배포판선택, ssh vnc활성화 비활성화 및 세팅, 사용자이름, 비밀번호등 my_profile.conf 내용을 결정하는 프롬프트. 프롬프트는 기본값을 제공함(신규생성일경우 chroot-distro/default.conf 기준, 기존수정일경우 기존 프로필 기준)
  4. my_profile.conf 이 생성됨

### 2. `chd install profile_name` : 
- chd download와 병합 : profile_name에 해당하는 프로필에따라 설치 진행. 내부엔 배포판에 따라 서로 다른 init 스크립트를 실행하는 if문이 있음
- 다시말해, if distro == ubuntu run chroot_ubuntu_init.sh 같은 식임. init 스크립트 실행은 기본실행, `--no-init` 인자로 억제할 수 있음(지금처럼 init스크립트를 install이 안해줌).
- `--no-profile` 인자는 기존 방식을 사용가능하게 해줌(다운로드도 직접 해줘야함)
#### 예시
- `chd install --no-profile --no-init ubuntu` : install이 download도 안해주고 init도 안해주는 기존 방식과 동등
- `chd install --no-profile ubuntu` : 기존 방식인데 init은 해줌
- `chd install --no-init my_profile` : 프로필 방식인데 init은 안함

### 3. `chd download --no-profile ubuntu`:
- 기존 chd download ubuntu와 동등한 명령.
- chd download 도 프로필 기반으로 변경
- --no-profile인자가 없으면 chd download는 더이상 사용자에게 프롬프트를 요청하지 않을것.
- 이부분을 구현하는것이 가장 어려울것으로 예상됨.


