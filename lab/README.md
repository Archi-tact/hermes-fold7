# 테스트 공간 (Lab)

실폰에 올리기 전에 키트를 검증하는 두 가지 테스트 공간.

| | `lab/arm64` — 빠른 검증 | `lab/redroid` — 진짜 안드로이드 |
|---|---|---|
| 어디서 | Docker 되는 아무 서버/PC (x86이면 qemu ARM64 에뮬) | ARM64 클라우드 VM (binder 커널 모듈 필요) |
| 무엇을 | Hermes ARM64 설치 + 보안 설정 키 + 차단 규칙(Hermes 자체 매처), 폰 브리지 SSH 경로 보안 | Termux 3종 앱 설치 → 키트 스크립트를 폰에서처럼 실행 → 알림/확인창/잠금/adb 화면조작 E2E |
| 못하는 것 | 안드로이드 API, 실제 확인창 | 실제 하드웨어(카메라·SMS·GPS), 삼성 One UI 배터리 정책, 폴드 화면 전환 |

## 0. 서버 없이 온라인으로: GitHub Actions (`.github/workflows/lab.yml`)

이 키트를 GitHub 저장소에 올리면 push할 때마다(또는 Actions 탭 → lab → Run workflow) 자동 실행됩니다.

| 잡 | 러너 | 내용 |
|---|---|---|
| `arm64-lab` | 공개 저장소: ARM64 러너(무료) / 비공개: x86 + qemu | Hermes 설치, 보안 설정, 차단 규칙 19건, 스킬 인식, 브리지 SSH 보안 13건 |
| `android-e2e` | x86_64 러너 (binder 모듈 있음) | redroid 안드로이드 → Termux 3종 → 키트(Plan B) → 확인창/잠금/알림/스크린샷 E2E, 결과 스크린샷·로그를 아티팩트로 |

- 실제 에이전트 대화까지 하려면: 저장소 Settings → Secrets → Actions 에 `LAB_SECRETS_ENV` (내용: `OPENROUTER_API_KEY=...`).
- 한계: x86_64라 **Plan A(공식 Termux 패키지, aarch64 전용)는 못 돌림**. 화면을 실시간으로 볼 수는 없고 스크린샷으로 확인.
- 비용: 공개 저장소 무료. 비공개 저장소는 무료 한도(월 2,000분) 차감.

## 1. lab/arm64

```bash
docker run --privileged --rm tonistiigi/binfmt --install arm64   # x86 호스트만, 1회
```

```bash
bash lab/arm64/run-bridge-ssh-test.sh
```

```bash
git clone --depth 1 https://github.com/NousResearch/hermes-agent /tmp/hermes-agent
HERMES_SRC=/tmp/hermes-agent bash lab/arm64/run-hermes-arm64.sh
```

## 2. lab/redroid (Oracle Cloud Ampere A1 예시)

1. Oracle Cloud → Compute → Instance 생성: Shape **VM.Standard.A1.Flex** (무료 한도 내 2–4 OCPU / 12–24GB), 이미지 **Ubuntu 24.04 (aarch64)**, SSH 공개키 등록. 보안 목록(Security List)에는 **22번만** 열어두세요.
2. 서버에 키트 복사 후:

```bash
sudo bash lab/redroid/setup-server.sh
```

binder 모듈 오류가 나면 안내대로 `linux-generic` 커널 설치 → 재부팅 → 다시 실행.

```bash
sudo PLAN=auto bash lab/redroid/install-termux.sh
```

```bash
sudo bash lab/redroid/e2e-test.sh
```

3. (선택) 실제 에이전트 대화까지: `lab/redroid/secrets.env` 를 만들고(절대 커밋 금지) install 재실행.

```ini
OPENROUTER_API_KEY=sk-or-...
```

4. 내 PC에서 테스트 폰 화면 보기/조작 (adb는 서버 밖으로 안 나감, SSH 터널만):

```bash
ssh -N -L 5555:127.0.0.1:5555 ubuntu@<서버IP>
```

```bash
adb connect 127.0.0.1:5555 && scrcpy -s 127.0.0.1:5555
```

### 개발 루프

PC(Antigravity / VS Code / Claude Code)에서 SSH 원격으로 서버의 `hermes-fold7`을 열고 수정 → `install-termux.sh` → `e2e-test.sh`. 통과하면 실폰에 반영.

### 보안 메모
- redroid는 `--privileged` 컨테이너입니다. **테스트 전용 VM**에서만 돌리고 개인 데이터/키를 두지 마세요.
- adb 5555는 `127.0.0.1`에만 바인딩됩니다. 공개하면 호스트까지 장악될 수 있습니다 (redroid 공식 경고).
- `install-termux.sh`는 테스트를 위해 `adb root`, `allow-external-apps`, 권한 자동 허용을 씁니다. 실폰에선 하지 마세요.
- API 키는 사용 후 Termux 쪽에서 삭제되고 `~/.hermes/.env`(600)에만 남습니다. 테스트용 키는 사용 한도를 걸어두세요.
