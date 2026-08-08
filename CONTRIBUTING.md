# 기여하기

*[English below](#contributing-in-english)*

고맙습니다. 이 문서는 PR을 보내기 전에 알아두면 좋은 것들입니다.

## 시작하기

이 저장소는 SwiftPM 패키지입니다. Xcode 없이도 됩니다.

```bash
git clone https://github.com/rayforvideos/attic.git
cd attic
swift build
swift test
```

테스트는 실제 앱을 띄우지 않고 돌아갑니다. 로직은 전부 `AtticCore`에 있고, `AtticApp`은
화면만 담당합니다. **코드를 고쳤으면 `swift test`가 통과하는지 확인하고 PR을 보내주세요.**

### 앱으로 직접 실행해보고 싶다면

권장하지 않지만 방법은 있습니다. 이 앱은 전체 디스크 접근이 필요하고, 그 권한은 서명된
앱 번들에 부여됩니다. `Scripts/make-app.sh`가 `.app`을 만들지만 Apple Development 인증서가
필요합니다. 무료 Apple ID로도 Xcode에서 개인용 인증서를 만들 수 있습니다.

번거로우면 안 하셔도 됩니다. 대부분의 변경은 테스트로 확인되고, 실기기 확인은 메인테이너가
머지 전에 합니다.

## 안전 규칙

이 앱은 남의 디스크를 만집니다. 버그 하나가 남의 파일을 지웁니다. 그래서 다음은
협상 대상이 아닙니다.

**`ReclaimGuard`를 거치지 않는 삭제 경로를 만들지 않습니다.** 후보 경로는 스캔할 때
한 번, 실제로 옮기기 직전에 한 번, 두 번 검사를 통과해야 합니다. "여기는 확실히 캐시니까"
같은 이유로 우회로를 내지 마세요.

**`FileManager.removeItem`을 새로 쓰지 않습니다.** 이 앱이 지우는 곳은 사용자가 직접
확인하고 누르는 휴지통 비우기 하나뿐입니다. 나머지는 전부 `trashItem`입니다.

**허용 목록으로만 넓힙니다.** 새로운 종류를 찾게 하려면 `ReclaimKind`를 추가하고 그
종류가 손댈 수 있는 경로를 명시적으로 적습니다. "이 폴더만 빼고 전부"는 안 됩니다.

**모르면 손대지 않습니다.** 크기를 못 쟀으면 목록에서 빼고, 나이를 못 읽었으면 방금 쓴
것으로 봅니다. 애매할 때 안전한 쪽은 언제나 "아무것도 안 하기"입니다.

**새 종류를 추가하면 가드 테스트도 같이 냅니다.** `Tests/AtticCoreTests/GuardAdversarialTests.swift`
가 가드를 뚫으려고 시도하는 테스트입니다. 여기에 본인이 추가한 종류를 뚫는 시도를 넣어주세요.

## 코드에 대해

**주석은 무엇이 아니라 왜를 적습니다.** 코드를 다시 설명하는 주석은 필요 없습니다.
"왜 이렇게 했는지", "이렇게 안 하면 뭐가 깨지는지"를 적어주세요. 기존 코드가 그렇게
되어 있습니다. 한국어로 적어도 되고 영어로 적어도 됩니다.

**측정한 숫자를 적어주세요.** 성능 때문에 무언가를 바꿨다면 재본 값을 주석이나 PR 설명에
남겨주세요. 이 저장소의 성능 관련 결정은 전부 실측 근거가 있습니다.

**테스트는 동작을 확인합니다.** 구현을 그대로 옮겨 쓴 테스트는 아무것도 막지 못합니다.
버그를 고쳤다면 고치기 전 코드에서 그 테스트가 실패하는지 확인해보세요.

## PR 보내기

- 하나의 PR은 하나를 고칩니다. 리팩터링과 기능 추가를 섞지 마세요
- 커밋 메시지는 무엇을 왜 바꿨는지 적습니다. 형식은 자유입니다
- 큰 변경은 먼저 이슈로 이야기해주세요. 방향이 안 맞으면 서로 시간을 버립니다

## 받기 어려운 것

- **외부 의존성 추가.** 이 앱은 지금 의존성이 하나도 없고, 그 상태를 유지하려 합니다
- **자동으로 지우는 기능.** 사람이 고르는 단계를 없애자는 제안은 받지 않습니다
- **사용 정보 수집.** 네트워크는 새 버전 확인에만 씁니다

## 라이선스

이 프로젝트는 [MIT](LICENSE)입니다. 자유롭게 쓰고, 고치고, 배포하고, 팔아도 됩니다.
저작권 표시만 남기면 됩니다.

**PR을 보내면 그 코드도 MIT로 제공하는 것에 동의하는 것으로 봅니다.**
저작권은 기여자 본인에게 그대로 있습니다. CLA는 없습니다.

---

# Contributing (in English)

Thanks for looking. Here is what you need to know before sending a PR.

## Getting started

This is a SwiftPM package. You do not need Xcode.

```bash
git clone https://github.com/rayforvideos/attic.git
cd attic
swift build
swift test
```

Tests run without launching the app. All logic lives in `AtticCore`; `AtticApp` is only the
UI. **Please make sure `swift test` passes before opening a PR.**

You do not need to run the actual app. It requires Full Disk Access, which macOS grants to
signed app bundles, so building a runnable `.app` needs an Apple Development certificate.
Most changes are verifiable through tests, and the maintainer does the on-device check
before merging.

## Safety rules

This app touches other people's disks. One bug deletes someone's files. These are not
negotiable:

**No deletion path bypasses `ReclaimGuard`.** Every candidate is checked twice: once when
scanning, once immediately before it is moved. Do not add a shortcut because "this one is
obviously a cache".

**Do not introduce new calls to `FileManager.removeItem`.** The only place this app deletes
anything is emptying the Trash, which the user confirms explicitly. Everything else is
`trashItem`.

**Widen by allowlist only.** To find a new kind of item, add a `ReclaimKind` and state
exactly which paths that kind may touch. "Everything except this folder" is not acceptable.

**When in doubt, do nothing.** If a size could not be measured, the item is left out. If an
age could not be read, it is treated as just-modified. The safe direction is always inaction.

**A new kind comes with guard tests.** `Tests/AtticCoreTests/GuardAdversarialTests.swift`
tries to break through the guard. Add an attempt against whatever you introduced.

## About the code

**Comments explain why, not what.** Restating the code is not useful. Say why it is written
this way and what breaks otherwise. The existing code does this. Korean or English is fine.

**Include the numbers you measured.** If you changed something for performance, put the
measurement in a comment or the PR description. Every performance decision in this repo has
one.

**Tests should verify behaviour.** A test that mirrors the implementation prevents nothing.
If you fixed a bug, check that your test fails against the code before the fix.

## Sending a PR

- One PR, one change. Do not mix refactoring with new features
- Commit messages say what changed and why. No required format
- Open an issue first for anything large, so neither of us wastes the effort

## Hard to accept

- **New third-party dependencies.** The app has none today, and that is deliberate
- **Anything that deletes without the user picking it**
- **Usage tracking.** The network is used only to check for a new version

## License

This project is [MIT](LICENSE) licensed. Use it, change it, ship it, sell it. Just keep the
copyright notice.

**By sending a PR you agree that your contribution is provided under the MIT license.**
You keep the copyright to what you wrote. There is no CLA.
