# chd rb2 - 실기 테스트 가이드

Note20 (c2q), adb `192.168.50.153:5555`. 리포 루트
(`C:\Users\lota\Developments\note20_chroot\chd_rb2`)에서 실행.

## 1. 배포

```
python deploy_chd.py --reboot
```
Python zip(슬래시 경로, lib/ 포함) → push → magisk 설치 → system/bin/chd + lib 실재 검증 → 재부팅.
versionCode 21이 기존 20을 교체.

## 2. 프로파일 → 설치 → 진입 (이미지 모드 기본)

```
adb shell            # 이후 su
chd profile ubuntu_noble     # 마법사: 번호 선택 (ubuntu=11, noble=1, 데스크탑 LXDE=1)
chd install ubuntu_noble     # /sdcard/ubuntu_noble.img 생성(128GB sparse)→포맷→루프마운트→추출→apt init
chd login ubuntu_noble       # 마운트+서비스+root 쉘 (adb 직접이면: adb shell -t su -c "chd login ubuntu_noble")
# 쉘 안에서:
apt update && apt install -y neofetch && neofetch
```
첫 install은 데스크탑 apt 설치까지 하므로 오래 걸림. 미러 404로 죽으면 재실행(멱등).

## 3. 서비스 확인 (login 후 쉘 안에서)

```
supervisorctl -c /etc/supervisor/supervisord.conf status   # sshd/cron/desktop/x11vnc RUNNING?
ss -ltnp | grep -E ':22|:5900'
```
VNC 뷰어 → <기기IP>:5900, 비밀번호 changeme. GPU는 virgl 소켓 있으면 virpipe, 없으면 자동 softpipe(검은화면 방지).

## 4. 새 명령들

```
chd list                     # 트리: 프로파일→설치상태→서비스
chd debug                    # 환경 진단 덤프 (문제 생기면 이 출력을 공유)
chd mount ubuntu_noble       # 마운트만
chd unmount ubuntu_noble -f  # 강제 해제
chd backup                   # 대화형 (생성/관리→복원·삭제)
chd backup ubuntu_noble      # 즉시 백업
chd uninstall ubuntu_noble   # 인스턴스+img 삭제 (템플릿은 유지, 마운트 잔존 시 거부)
chd rename old new
```

## 5. 알려진 실기 리스크

- /sdcard의 .img 루프마운트가 커널/sdcardfs 제약으로 실패할 수 있음 → 그 경우
  `chd debug` 출력과 함께 보고 (이미지 경로를 /data/local/에 두는 대안 검증 필요)
- 첫 실행 시 Termux/Termux:X11 앱 필요 (virgl/X11)
- mke2fs 미존재 기기면 이미지 생성 불가 → `chd debug`가 표시함
