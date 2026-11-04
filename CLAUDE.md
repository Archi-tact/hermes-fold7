# 작업 지침 (Claude Code)

## 언어
- **사용자에게 하는 모든 답변은 한국어로 씁니다.** 영어로 답하지 않습니다. (명령어·코드·파일 이름은 그대로)
- 사용자는 주로 폰(갤럭시 Z 폴드7)으로 보고 있으므로, 짧은 단계별 안내와 바로 붙여넣을 수 있는 명령을 줍니다.

## 이 저장소
- Hermes Agent 를 폴드7 에서 단독으로 돌리는 키트: Termux 설치 스크립트(`scripts/`), 폰 브리지(`bridge/`),
  화면 조작 앱 Hermes Hands(`android/hands/`), 폰 전용 화면 Hermes Fold(`ui/fold/`), 테스트(`lab/`, `.github/workflows/`).
- 실제 폰은 proot(Plan B) 모드로 설치돼 있음. proot-distro 는 명령 인자를 셸로 다시 해석할 수 있으니
  `$` 등이 든 값은 인자가 아니라 stdin 스크립트로 전달합니다.

## 보안
- 보안 규칙(approvals.deny, policy.conf, 토큰, 비밀번호)을 약하게 만드는 변경은 하지 않습니다.
- 비밀값(API 키, 서명 키, 비밀번호)은 커밋·로그·채팅에 남기지 않습니다.
