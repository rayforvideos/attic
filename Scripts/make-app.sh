#!/bin/bash
# Scripts/make-app.sh — swift build 산출물을 .app 번들로 조립하고 서명
#
# 서명 아이덴티티: 키체인에 Apple Development 인증서(무료 계정으로 발급)가
# 있으면 그걸 쓴다. 애드혹 서명은 알림 권한 프롬프트조차 뜨지 않고 즉시
# 거부되며(실측 2026-08-05, macOS 26), 리빌드마다 cdhash가 바뀌어 TCC/알림
# 권한이 초기화된다. 인증서가 없으면 애드혹으로 내려가되 경고를 남긴다.
set -euo pipefail
cd "$(dirname "$0")/.."

# 번역 자리표시자가 어긋나면 실행 중 SIGSEGV로 죽는다 — 빌드 전에 막는다.
python3 Scripts/check-strings.py || exit 1

swift build -c release
APP=build/Attic.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/AtticApp "$APP/Contents/MacOS/Attic"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# 언어 리소스. SPM 리소스 번들을 쓰지 않고 .app에 직접 넣는다 — Bundle.main이
# 곧 이 번들이라 앱·코어 양쪽에서 같은 테이블을 조회할 수 있다.
for lproj in Resources/*.lproj; do
    cp -R "$lproj" "$APP/Contents/Resources/"
done

# 배포용 서명은 release.sh가 Developer ID로 다시 한다. 여기서는 개발용이다.
IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"')}
TIMESTAMP_FLAG=--timestamp
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="-"
    # 애드혹 서명에 보안 타임스탬프를 요청하면 codesign이 실패한다.
    TIMESTAMP_FLAG=--timestamp=none
    echo "경고: Apple Development 인증서가 없어 애드혹으로 서명합니다 — 알림 배너가 비활성화됩니다" >&2
fi
# --timestamp: 애플 타임스탬프 서버의 보안 타임스탬프. 공증(notarization)의
# 필수 조건이라 개발 빌드에도 넣어둔다 — 배포 직전에야 없는 것을 발견하면
# 그때 서명 설정을 처음부터 다시 확인해야 한다.
codesign --force --sign "$IDENTITY" --options runtime $TIMESTAMP_FLAG \
  --entitlements Attic.entitlements "$APP"
sign_info=$(codesign -dv "$APP" 2>&1)
if [[ "$sign_info" == *"flags="*"runtime"* ]]; then
    echo "OK: $APP (hardened runtime, identity: $IDENTITY)"
else
    echo "FAIL: signing verification (hardened runtime flag missing)" >&2
    echo "$sign_info" >&2
    exit 1
fi

if [[ "${1:-}" == "--install" ]]; then
    rm -rf /Applications/Attic.app
    cp -R "$APP" /Applications/Attic.app
    echo "Installed: /Applications/Attic.app"
    echo "로그인 시 실행 등록은 앱을 /Applications에서 실행한 뒤 설정에서 켤 것"
fi
