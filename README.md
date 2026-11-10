# Hermes Agent on Galaxy Fold7

Nous Research의 **Hermes Agent**를 갤럭시 폴드7(Android, aarch64)에서 **폰 단독으로** 돌리기 위한 설치·보안·자동화 키트.
폰 폴더에서 개발하고, 폰 기능(알림·카메라·위치·SMS·화면 조작)을 다루고, 자동화(크론·텔레그램 원격)까지 할 수 있습니다.

## ⚡ 빠른 시작 — 폰 하나로, API 키만 넣으면 끝

1. 폰에 설치: **Termux**, **Termux:API**, **Termux:Boot** (GitHub 또는 F-Droid 판, 셋 다 같은 출처)
2. Termux 에서 한 줄:

```bash
pkg install -y git && git clone https://github.com/Archi-tact/hermes-fold7 ~/hermes-fold7 && bash ~/hermes-fold7/scripts/install.sh
```

3. 끝나면 브라우저가 열림 → 화면에 나온 아이디 `fold` / 비밀번호로 로그인 → **AI 고르고 API 키 입력** (NVIDIA 무료 키 추천)
4. Chrome ⋮ → **홈 화면에 추가** → 앱처럼 사용. 재부팅해도 자동으로 켜짐. PC 는 필요 없음.

> 기준: Hermes `main` 문서 (2026-11-01). **공식 Termux 패키지는 현재 "고장(수정 중)" 공지 상태**라서 Plan B를 같이 제공합니다.

---

## 1. 구조

```
┌──────────────── Galaxy Fold7 (루트 없음) ────────────────┐
│ Termux 앱                                                 │
│  ├─ Plan A: hermes (공식 Termux APT 패키지)               │
│  │     또는                                               │
│  ├─ Plan B: proot Debian ─ hermes (데스크톱 install.sh)   │
│  │            └─ /root/work  ⇄  ~/work (작업 폴더)       │
│  │            └─ `phone` ──SSH(127.0.0.1:8022, 강제명령)─┐ │
│  ├─ phone-bridge  ← 허용목록 + 정책 + 화면 확인창 + 감사로그│
│  │     ├─ Termux:API  (알림, 카메라, 위치, SMS, 클립보드…)  │
│  │     └─ adb (무선 디버깅 → 자기 자신, 화면 탭/스샷/앱실행) │
│  └─ Termux:Boot  (부팅 시 sshd + 게이트웨이 자동시작)       │
└───────────────────────────────────────────────────────────┘
        ▲ (선택) 텔레그램 봇 — 허용된 내 ID만 명령 가능
```

| | Plan A: 공식 Termux 패키지 | Plan B: proot Debian |
|---|---|---|
| 상태 | 공식 지원, **현재 고장 공지** | 지금 바로 동작 (비공식 경로) |
| 기능 | core + acp (데스크톱 extras 없음) | 리눅스 arm64 전체 설치, Debian chromium 브라우저 |
| 속도 | 빠름 | proot 오버헤드 있음 |
| 폰 기능 경로 | `phone` → 브리지 직접 | `phone` → SSH 강제명령 → 브리지 (분리가 더 좋음) |
| 업데이트 | `pkg upgrade hermes-agent` | `hermes-proot update` |

둘 다 **Docker 샌드박스는 불가**(루트 없는 Android). 그래서 보안은 *정책 + 사람 승인 + 권한 분리*로 만듭니다.

---

## 2. 준비물

1. **Termux**, **Termux:API**, **Termux:Boot** — 반드시 *같은 출처*(F-Droid 또는 GitHub 릴리스)에서 설치. Play 스토어판 섞지 말 것.
2. Termux:API 앱 권한: 카메라/위치/SMS/연락처 등은 쓸 것만 허용.
3. 배터리: 설정 → 애플리케이션 → Termux(+API, Boot) → 배터리 → **제한 없음**. 디바이스 케어의 *절전 예외 앱*에도 추가.
4. LLM API 키 (OpenRouter / Anthropic / Nous Portal 등) — `hermes setup`에서 입력.

## 3. 설치 순서

이 폴더를 폰으로 옮긴 뒤(예: `~/hermes-fold7`), Termux에서:

```bash
cd ~/hermes-fold7 && bash scripts/00-termux-bootstrap.sh
```

**Plan A** (먼저 시도):

```bash
bash scripts/10-install-hermes-apt.sh && hermes setup
```

`hermes --version`이 실패하면 **Plan B**:

```bash
bash scripts/11-install-hermes-proot.sh && hermes-proot setup
```

공통:

```bash
bash scripts/30-phone-bridge.sh
```

```bash
HERMES_MODE=apt bash scripts/20-harden.sh      # Plan B면 HERMES_MODE=proot
```

시스템 조작(화면 탭·스크린샷·앱 실행)이 필요하면 무선 디버깅 페어링 (폴드 분할화면 추천):

```bash
bash scripts/40-adb-pair.sh
```

자동시작 (+ 선택: 텔레그램 원격 게이트웨이):

```bash
bash scripts/50-autostart.sh apt --gateway     # Plan B면 proot
```

실행:

```bash
cd ~/work && hermes --tui                      # Plan B: hermes-proot --tui
```

### 화면: Hermes Fold (폰) + Hermes Desktop (PC)

폰 전용 화면 — 접으면 채팅, 펼치면 채팅 + 📱 폰 실시간 패널(조작 진행·빠른 설정·읽은 화면 구조):

```bash
bash scripts/80-hermes-fold.sh setup
```

```bash
bash scripts/80-hermes-fold.sh start
```

Chrome 에서 `http://127.0.0.1:9130` → 아이디 `fold` / setup 이 보여준 비밀번호 → ⋮ → **홈 화면에 추가**.

PC 에서 클로드 코드 데스크탑 같은 화면으로 쓰기 (공식 Hermes Desktop, Tailscale 필요):

```bash
bash scripts/80-hermes-fold.sh remote-on
```

출력된 URL·Session token 을 Hermes Desktop → *Connect to existing Hermes* 에 입력. 끄기: `remote-off`.

- 서버는 `127.0.0.1` 에만 열리고 로그인 필수 모드로 강제(폰의 다른 앱도 비밀번호 없이는 못 씀). 비밀번호는 scrypt 해시로만 저장.
- PC 연결은 Tailscale 주소에서만 중계(socat) + 세션 토큰. 같은 와이파이의 다른 기기는 접근 불가.
- 위험 명령의 승인은 채팅 안 카드(이번만 허용 / 이 대화에선 허용 / 거부)로.

### 앱 조작 · 설정 직접 변경

- 화면 조작: Hermes Hands 앱 — Releases → `hands-latest` → `hermes-hands.apk` 설치 → 접근성 켜기 → 앱에서 토큰 복사 → `phone-hands-pair`.
- 설정은 화면 대신 `phone set dark on`, `phone set brightness 120`, `phone set volume media 7` … (무선 디버깅 필요).
- 여러 단계는 `phone hands-run` 스크립트로 한 번에, 성공한 흐름은 `~/work/recipes/<이름>.json` 레시피로 저장 → `phone hands-run @이름`.

## 4. 개발 폴더

- 기본 작업 폴더는 **`~/work`** (Termux 홈). 에이전트의 터미널 시작 위치와 `write_file` 허용 범위가 여기로 고정됩니다.
- `/sdcard`(내장 메모리)는 FUSE라서 실행권한·심볼릭링크가 안 됨 → `node_modules`, venv, git 훅이 깨집니다. **코드는 `~/work`에 두고**, 결과물만 `/sdcard`로 복사하세요.
- 다른 폴더를 쓰려면: `HERMES_WORKSPACE=/원하는/경로` 를 설치·하드닝 스크립트 실행 시 지정.
- 폰 브리지 결과물(사진·스크린샷·UI 덤프)은 `~/work/.phone/`에 저장됩니다.

## 5. 보안 설계 (무엇이 막히고, 무엇이 안 막히는지)

| 계층 | 설정 | 효과 |
|---|---|---|
| 위험 명령 승인 | `approvals.mode: manual` | `rm -r`, `chmod 777`, `curl\|sh` 등은 매번 사람 승인 |
| 무인 실행 | `cron_mode / single_query_mode / unattended_mode: deny` | 크론·원샷·웹훅은 위험 명령 자동 거부 |
| 절대 금지 | `approvals.deny` (YOLO에서도 유효) | `termux-*`·`adb` 직접호출, 브리지/설정/SSH 키 건드리기, `su`, 강제 push, 원격 스크립트 실행 등 |
| 파일 쓰기 | `HERMES_WRITE_SAFE_ROOT=작업폴더` | `write_file`/`patch`는 작업폴더 밖에 못 씀 |
| 폰 기능 | `phone-bridge` 허용목록 | 정해진 동작만, 인자 검증, 임의 쉘 없음, `adb-shell` 기본 금지 |
| 사람 확인 | `confirm` 정책 → **폰 화면 확인창** | SMS·전화·위치·카메라·화면조작은 내가 직접 '예'를 눌러야 실행 |
| 자기승인 방지 | 브리지 전역 직렬 잠금 | 확인창이 떠 있는 동안 에이전트가 탭으로 스스로 승인 불가 |
| 분리 (Plan B) | SSH `command=` + `restrict` + `from=127.0.0.1` | 게스트에서 쓸 수 있는 건 브리지뿐 (포워딩·셸 불가) |
| 네트워크 | sshd `ListenAddress 127.0.0.1`, 키 인증만 | 외부에서 폰 SSH 접속 불가 |
| ADB | 무선 디버깅 페어링만, `adb tcpip` 금지, 동작 후 adb 서버 종료 | 다른 프로세스가 ADB 세션 재사용 어렵게 |
| 메신저 | `TELEGRAM_ALLOWED_USERS`, `unauthorized_dm_behavior: ignore` | 내 ID 외에는 무시(기본 거부) |
| 감사 | `~/.hermes-bridge/audit.log` | 모든 폰 기능 요청/승인/거부 기록 |

**정직한 한계**
- 루트 없는 Android에선 진짜 샌드박스(Docker 등)가 없습니다. Hermes 문서도 deny 규칙은 "정책이지 OS 샌드박스가 아님"이라고 명시합니다. 에이전트의 터미널은 Termux 사용자 권한으로 돌므로, 마음먹고 우회하는 악성 프롬프트(프롬프트 인젝션)를 100% 막진 못합니다.
- proot도 보안 경계가 아닙니다(호환 레이어).
- 그래서: **은행/인증 앱 근처에서 화면 자동화 금지**, 무선 디버깅은 쓸 때만 켜기, 낯선 웹페이지·문서를 읽힌 직후 위험 동작 승인 요청이 오면 거부.
- 더 강한 격리가 필요하면: 폰은 *클라이언트*(텔레그램/SSH)로만 쓰고 Hermes는 PC·서버의 Docker 백엔드에서 돌리는 구성을 권장합니다.

## 6. 자동화 예시

```bash
hermes cron create "every 1d at 08:30" --timezone Asia/Seoul "phone battery 결과를 확인하고 30% 미만이면 phone notify로 충전 알림"
```

- 크론은 무인이라 `confirm` 동작(확인창)은 응답이 없어 거부됩니다 → 크론엔 `allow` 동작(notify, battery, tts…)만 쓰세요.
- 폰 화면이 꺼져도 돌게 하려면 Termux:Boot 스크립트가 `termux-wake-lock`을 겁니다. 그래도 Android가 죽일 수 있어 **최선 노력(best-effort)** 입니다.
- 텔레그램 게이트웨이를 켜두면 밖에서 "작업폴더의 프로젝트 테스트 돌려줘"처럼 원격 지시 가능. 위험 명령은 텔레그램으로 승인 요청이 옵니다(`yes`/`no`).

## 7. 정책 바꾸기

`~/.hermes-bridge/policy.conf`:

```ini
adb-screenshot=allow   # 스크린샷은 자유롭게
sms-send=deny          # 문자 발송 아예 금지
```

현재 정책 확인: `phone help`

## 8. 파일

| 파일 | 역할 |
|---|---|
| `scripts/00-termux-bootstrap.sh` | Termux 패키지, 저장소 권한, 작업폴더 |
| `scripts/10-install-hermes-apt.sh` | Plan A — 서명키 지문 검증 후 공식 APT 설치 |
| `scripts/11-install-hermes-proot.sh` | Plan B — proot Debian + 공식 install.sh, `hermes-proot` 런처 |
| `scripts/20-harden.sh` | 승인/금지 규칙, 작업폴더, 쓰기 샌드박스, 스킬 연결, 권한 |
| `scripts/30-phone-bridge.sh` | 브리지·정책·로컬 sshd·강제명령 키 |
| `scripts/40-adb-pair.sh` | 무선 디버깅 자기 페어링 |
| `scripts/50-autostart.sh`, `boot/10-hermes` | Termux:Boot 자동시작, 텔레그램 게이트웨이 |
| `bridge/phone-bridge`, `bridge/phone` | 폰 기능 게이트웨이 / 클라이언트 |
| `skills/fold7-phone/SKILL.md` | 에이전트에게 `phone` 사용법을 가르치는 Hermes 스킬 |
| `scripts/60-weather-brief.sh` | 매일 날씨 브리핑 예약 작업 |
| `scripts/70-skills-storage.sh` | 스킬을 내장 메모리로 내보내기 / 검토 후 가져오기 |
| `scripts/80-hermes-fold.sh`, `ui/fold/` | 폰 전용 화면(Hermes Fold) + PC Desktop 원격 연결 |
| `scripts/85-exaone.sh` | K-EXAONE 2.5 API 를 Hermes 모델로 연결 |
| `android/hands/` | Hermes Hands 앱 (접근성 · 보호막 · 일시정지 · 스크립트 실행) |
| `skills/fold7-hands/SKILL.md` | 앱 조작 방법(읽기→스크립트→레시피)을 가르치는 스킬 |

## 9. 테스트 공간

실폰 전에 검증: [`lab/README.md`](lab/README.md)
- `lab/arm64` — Docker ARM64 컨테이너에서 Hermes 설치·보안설정·차단규칙·브리지 SSH 보안 테스트
- `lab/redroid` — ARM 클라우드 VM에 진짜 안드로이드(redroid) + Termux를 올려 키트 전체 E2E 테스트
- GitHub Actions: `hands`(보호막·일시정지), `apps`(실제 앱 6종 + 설정 직접 변경 + 레시피), `fold`(폰 화면 + PC 원격, 실제 모델), `weather`

## 10. 문제 해결

- `hermes doctor` 먼저.
- Termux:API 무응답 → Termux:API 앱 설치 출처 확인, 앱 권한 확인.
- 화면 꺼지면 게이트웨이 멈춤 → 배터리 '제한 없음', 알림창에서 Termux wake-lock 확인.
- 확인창이 안 뜨고 60초 뒤 거부됨 → 설정 → 애플리케이션 → Termux:API(및 Termux) → **다른 앱 위에 표시** 허용. (안전하게 실패하도록 설계됨: 확인창이 없으면 실행 안 됨)
- ADB 미연결 → 무선 디버깅 ON(Wi‑Fi 필요), `phone adb-status`. 재부팅 후엔 무선 디버깅 다시 켜기.
- Plan B에서 `phone` 실패 → Termux에서 `sshd` 실행 중인지, `bash scripts/30-phone-bridge.sh` 재실행.
