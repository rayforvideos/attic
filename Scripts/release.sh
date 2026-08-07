#!/bin/bash
# Scripts/release.sh — 웹에서 배포할 DMG를 만든다: Developer ID 서명 → 공증 →
# 티켓 첨부 → Gatekeeper 검증.
#
# 왜 필요한가: 개발용 서명(Apple Development)으로 만든 앱은 남의 맥에서 열리지
# 않는다. 실측으로 확인했다 — quarantine을 붙여 `spctl`에 물어보면 `rejected`다.
# macOS 15부터는 우클릭 → 열기 우회도 없어서, 받는 사람이 시스템 설정까지
# 들어가 「그대로 열기」를 눌러야 한다. 디스크를 정리하고 전체 디스크 접근을
# 요구하는 앱에게 그 과정을 거쳐줄 사람은 없다.
#
# 앱스토어는 이 앱에 닫혀 있다: 샌드박스가 필수인데 이 앱의 핵심 기능(남의 앱
# 캐시 삭제, launchctl, 프로세스 종료, 휴지통 비우기)이 전부 샌드박스 금지
# 항목이다. CleanMyMac·OnyX도 같은 이유로 웹 배포만 한다.
#
# 사용법:
#   Scripts/release.sh              전체 배포본 만들기(인증서·공증 자격 필요)
#   Scripts/release.sh --dry-run    서명·DMG까지만. 공증은 건너뛴다.
#
# 준비물(한 번만):
#   1. Apple Developer Program 가입 → Developer ID Application 인증서 발급
#   2. appleid.apple.com 에서 앱 암호(app-specific password) 생성
#   3. xcrun notarytool store-credentials "attic-notary" \
#        --apple-id <이메일> --team-id <팀ID> --password <앱 암호>
set -euo pipefail
cd "$(dirname "$0")/.."

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

NOTARY_PROFILE=${NOTARY_PROFILE:-attic-notary}
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Resources/Info.plist)
APP=build/Attic.app
DMG="build/Attic-$VERSION.dmg"

say() { printf '\n\033[1m%s\033[0m\n' "$1"; }
die() { printf '\033[31m실패: %s\033[0m\n' "$1" >&2; exit 1; }

# ---------------------------------------------------------------- 1. 사전 확인
say "1/6 사전 확인"

# 배포 서명은 Developer ID Application이어야 한다. Apple Development(개발용)로
# 서명하면 공증 자체가 거부된다 — 여기서 막지 않으면 몇 분 기다린 뒤에 안다.
# Developer ID 인증서가 여러 개면 **고르지 않는다**. 이 맥에는 회사 팀
# (UN7QI3 Inc.) 인증서가 있었던 이력이 있어, 자동으로 첫 번째를 집으면 개인
# 프로젝트가 회사 명의로 서명돼 나갈 수 있다 — 배포 후에는 되돌릴 수 없다.
# macOS는 bash 3.2라 mapfile이 없다 — while read로 읽는다.
CANDIDATES=()
while IFS= read -r line; do
    [[ -n "$line" ]] && CANDIDATES+=("$line")
done < <(security find-identity -v -p codesigning 2>/dev/null \
    | grep -o '"Developer ID Application: [^"]*"' | tr -d '"' || true)
if (( ${#CANDIDATES[@]} > 1 )) && [[ -z "${SIGN_IDENTITY:-}" ]]; then
    printf '실패: Developer ID 인증서가 여러 개입니다. 쓸 것을 지정하세요:\n' >&2
    for cand in "${CANDIDATES[@]}"; do
        printf '    SIGN_IDENTITY="%s" Scripts/release.sh\n' "$cand" >&2
    done
    exit 1
fi
IDENTITY=${SIGN_IDENTITY:-${CANDIDATES[0]:-}}

if [[ -z "$IDENTITY" ]]; then
    if $DRY_RUN; then
        IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
            | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"' || true)
        [[ -n "$IDENTITY" ]] || die "서명할 인증서가 하나도 없습니다"
        echo "  ⚠︎ Developer ID 인증서가 없어 개발용($IDENTITY)으로 대신 서명합니다."
        echo "    이 DMG는 남의 맥에서 열리지 않습니다 — 스크립트 점검 용도입니다."
    else
        die "Developer ID Application 인증서가 없습니다.
    Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application
    (가입 전이라면 Scripts/release.sh --dry-run 으로 나머지 단계만 점검할 수 있습니다)"
    fi
else
    echo "  서명 인증서: $IDENTITY"
fi

# 팀 ID는 인증서 이름 끝의 괄호에 들어 있다. 손으로 찾아 적게 하면 회사 팀과
# 개인 팀을 헷갈린다(실제로 헷갈렸다) — 읽어서 그대로 보여준다.
TEAM_ID=$(sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p' <<<"$IDENTITY")
if ! $DRY_RUN; then
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
        || die "공증 자격증명('$NOTARY_PROFILE')이 없습니다. 이 줄을 그대로 실행하세요:

    xcrun notarytool store-credentials \"$NOTARY_PROFILE\" \\
      --apple-id <애플 계정 이메일> --team-id ${TEAM_ID:-<팀ID>} --password <앱 암호>

    앱 암호는 appleid.apple.com → 로그인 및 보안 → 앱 암호에서 만듭니다."
    echo "  공증 자격증명: $NOTARY_PROFILE (팀 ${TEAM_ID:-알 수 없음})"
fi
echo "  버전: $VERSION ($BUILD)"

# ---------------------------------------------------------------- 2. 빌드·서명
say "2/6 빌드하고 배포용으로 서명"
# 빌드 로그는 실패했을 때만 보여준다 — 성공 로그가 단계 출력에 섞이면 읽기 어렵다.
build_log=$(SIGN_IDENTITY="$IDENTITY" Scripts/make-app.sh 2>&1) \
    || { echo "$build_log" >&2; die "빌드·서명 실패"; }
echo "  $APP"

# ------------------------------------------------------------ 3. 서명 검증
# 공증은 이 세 가지가 모두 갖춰져야 통과한다. 제출 후 거부되면 원인을 로그에서
# 파헤쳐야 하니 여기서 먼저 확인한다.
say "3/6 서명 검증"
info=$(codesign -dvvv "$APP" 2>&1)
grep -q "flags=.*runtime" <<<"$info" || die "hardened runtime이 빠졌습니다"
grep -q "^Timestamp=" <<<"$info" || die "보안 타임스탬프가 빠졌습니다(공증 필수 조건)"
if ! $DRY_RUN; then
    grep -q "^Authority=Developer ID Application" <<<"$info" \
        || die "Developer ID로 서명되지 않았습니다"
fi
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -1
echo "  hardened runtime ✓  타임스탬프 ✓  서명 유효 ✓"

# ---------------------------------------------------------------- 4. DMG 만들기
say "4/6 DMG 만들기"
STAGE=build/dmg-stage
RW_DMG=build/attic-rw.dmg
# Finder에게 창을 꾸미게 하려면 /Volumes에 정상 마운트해야 한다. 프로젝트 폴더
# 안에 -mountpoint로 붙이면 Finder가 "disk"로 인식하지 못한다(실측: -1728).
MOUNT="/Volumes/Attic $VERSION"
rm -rf "$STAGE" "$DMG" "$RW_DMG"
hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/"
# 받는 사람이 끌어다 놓을 대상. 안내 없이도 무엇을 하면 되는지 보인다.
ln -s /Applications "$STAGE/Applications"
cp Resources/dmg/background.png "$STAGE/.background/background.png"
cp Resources/dmg/background@2x.png "$STAGE/.background/background@2x.png"

# 창 꾸미기는 읽기·쓰기 이미지에서만 된다(.DS_Store를 써야 한다) — 꾸민 뒤
# 압축본으로 변환한다. 출력을 버리지 않는다: 실패한 파일이 다음 단계로 넘어가면
# 공증이 오류 없이 멈춘다(실제로 30분 날렸다).
hdiutil create -volname "Attic $VERSION" -srcfolder "$STAGE" -ov \
    -format UDRW -fs HFS+ "$RW_DMG" >/dev/null || die "임시 DMG를 만들지 못했습니다"
hdiutil attach "$RW_DMG" >/dev/null || die "임시 DMG를 마운트하지 못했습니다"

# Finder에게 창 모양을 시킨다. 실패해도 배포는 계속한다 — 꾸밈이 없다고
# 설치가 안 되는 것은 아니다(자동화 권한이 없는 기계에서도 배포되어야 한다).
osascript >/dev/null 2>&1 <<APPLESCRIPT || echo "  ⚠︎ 창 꾸미기를 건너뜁니다(Finder 자동화 권한 없음)"
tell application "Finder"
    tell disk "Attic $VERSION"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 140, 820, 560}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 128
        set background picture of theViewOptions to file ".background:background.png"
        set position of item "Attic.app" of container window to {150, 210}
        set position of item "Applications" of container window to {470, 210}
        close
        open
        update without registering applications
        delay 2
    end tell
end tell
APPLESCRIPT

hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true
rm -rf "$STAGE"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null \
    || die "DMG를 압축하지 못했습니다"
rm -f "$RW_DMG"
# 만든 DMG가 실제로 열리는지 확인한다. 이 검사가 없어서 깨진 파일이 통과했다.
hdiutil verify "$DMG" >/dev/null 2>&1 || die "만든 DMG가 깨졌습니다 (hdiutil verify 실패)"
# DMG 자체도 서명한다 — 공증은 서명된 컨테이너를 요구한다.
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
echo "  $DMG ($(du -h "$DMG" | cut -f1))"

# ---------------------------------------------------------------- 5. 공증
if $DRY_RUN; then
    say "5/6 공증 — 건너뜀(--dry-run)"
else
    say "5/6 공증 제출(보통 몇 분)"
    # 공증은 심사가 아니라 자동 악성코드 검사다 — 기능을 이유로 거절되지 않는다.
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait \
        || die "공증이 거부되었습니다. 자세한 이유:
    xcrun notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE"
    # 티켓을 파일에 박아둔다 — 이게 없으면 받는 사람이 오프라인일 때 막힌다.
    xcrun stapler staple "$DMG"
    echo "  공증 완료, 티켓 첨부됨"
fi

# ------------------------------------------------------- 6. 받는 사람 관점 검증
say "6/6 받는 사람이 열 수 있는지 확인"
if $DRY_RUN; then
    echo "  건너뜀 — 공증하지 않은 DMG는 반드시 거부됩니다(그게 정상입니다)"
else
    xcrun stapler validate "$DMG" >/dev/null || die "티켓이 첨부되지 않았습니다"
    # Gatekeeper에게 실제로 물어본다. 여기서 accepted가 나와야 남의 맥에서
    # 경고 없이 열린다 — 내 맥에서 열리는 것과는 다른 질문이다.
    verdict=$(spctl -a -vvv -t open --context context:primary-signature "$DMG" 2>&1 || true)
    grep -q "accepted" <<<"$verdict" || die "Gatekeeper가 거부했습니다:
$verdict"
    echo "  Gatekeeper: accepted ✓  티켓 ✓"
    printf '\n\033[32m배포 준비 완료: %s\033[0m\n' "$DMG"
    echo "이 파일을 웹사이트에 올리면 받는 사람은 경고 없이 열 수 있습니다."
fi
