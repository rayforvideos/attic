#!/bin/bash
# Scripts/publish.sh — 릴리스를 끝까지 배달한다. DMG 빌드·공증(release.sh),
# GitHub 릴리스 생성, Homebrew tap의 cask 갱신, 설치 경로 검증 순서로 진행한다.
#
# tap 갱신을 사람 손에 맡겼더니 cask가 몇 버전씩 뒤처졌다(0.2.27에 멈춘 채
# 0.2.30까지 릴리스됨). 릴리스와 cask를 한 스크립트에 묶어 재발을 막는다.
#
# 사용법:
#   Scripts/publish.sh "릴리스 노트"           문자열로 바로
#   Scripts/publish.sh --notes-file notes.md   파일로
#
# 준비물: release.sh의 준비물 + gh CLI(rayforvideos 계정) + ~/workspace/homebrew-tap
set -euo pipefail
cd "$(dirname "$0")/.."

TAP_DIR="${TAP_DIR:-$HOME/workspace/homebrew-tap}"
CASK="$TAP_DIR/Casks/attic.rb"
REPO=rayforvideos/attic

say() { printf '\n\033[1m%s\033[0m\n' "$1"; }
die() { printf '\033[31m실패: %s\033[0m\n' "$1" >&2; exit 1; }

# ---------------------------------------------------------------- 0. 릴리스 노트
NOTES=""
if [[ "${1:-}" == "--notes-file" ]]; then
    [[ -f "${2:-}" ]] || die "노트 파일이 없습니다: ${2:-<빈 값>}"
    NOTES=$(cat "$2")
else
    NOTES="${1:-}"
fi
[[ -n "$NOTES" ]] || die "릴리스 노트가 비었습니다. 받는 사람이 읽는 글입니다.
    Scripts/publish.sh \"고친 것·바뀐 것을 사용자 말로\"
    Scripts/publish.sh --notes-file notes.md"

# ------------------------------------------------------------ 1. 사전 확인
# 검사는 전부 빌드보다 앞에 둔다. 공증까지 몇 분 기다린 뒤에 막히면 늦다.
say "1/5 사전 확인"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
TAG="v$VERSION"

# 커밋 안 된 변경이 섞이면 릴리스와 저장소 내용이 어긋난다.
[[ -z "$(git status --porcelain --untracked-files=no)" ]] \
    || die "커밋하지 않은 변경이 있습니다. 커밋하거나 치운 뒤 다시 실행하세요."
git fetch origin main --quiet
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] \
    || die "로컬 main이 origin과 다릅니다. 먼저 푸시하세요."

# 세컨드 계정이어야 한다. 회사 계정으로 릴리스가 나가면 되돌릴 수 없다.
LOGIN=$(gh api user -q .login 2>/dev/null || true)
[[ "$LOGIN" == "rayforvideos" ]] \
    || die "gh 활성 계정이 '$LOGIN'입니다. gh auth switch --user rayforvideos"

gh release view "$TAG" -R "$REPO" >/dev/null 2>&1 \
    && die "$TAG 릴리스가 이미 있습니다. Info.plist 버전을 먼저 올리세요."

[[ -f "$CASK" ]] || die "tap 사본이 없습니다: $CASK
    git clone git@github-second:rayforvideos/homebrew-tap.git $TAP_DIR"
git -C "$TAP_DIR" pull --ff-only --quiet || die "tap을 최신으로 받지 못했습니다"
[[ -z "$(git -C "$TAP_DIR" status --porcelain)" ]] \
    || die "tap 사본에 커밋하지 않은 변경이 있습니다: $TAP_DIR"
echo "  버전 $VERSION · 계정 $LOGIN · tap 최신 ✓"

# ------------------------------------------------------------ 2. 빌드·공증
say "2/5 DMG 빌드·공증 (release.sh)"
Scripts/release.sh
DMG="build/Attic-$VERSION.dmg"
[[ -f "$DMG" ]] || die "DMG가 없습니다: $DMG"

# ------------------------------------------------------------ 3. GitHub 릴리스
say "3/5 GitHub 릴리스 만들기"
gh release create "$TAG" "$DMG" -R "$REPO" --title "$VERSION" --notes "$NOTES"

# ------------------------------------------------------------ 4. cask 갱신
say "4/5 Homebrew cask 갱신"
SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
# 값이 무엇이든 그 줄을 통째로 바꾼다. 옛 값을 박아두면 tap이 앞서갔을 때 빗나간다.
sed -i '' -E \
    -e "s/^  version \".*\"/  version \"$VERSION\"/" \
    -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$CASK"
grep -q "version \"$VERSION\"" "$CASK" && grep -q "sha256 \"$SHA\"" "$CASK" \
    || die "cask를 고치지 못했습니다: $CASK"
git -C "$TAP_DIR" add Casks/attic.rb
git -C "$TAP_DIR" commit --quiet -m "attic $VERSION"
git -C "$TAP_DIR" push --quiet
echo "  version $VERSION · sha256 ${SHA:0:12}… 푸시됨"

# ------------------------------------------------------------ 5. 설치 경로 검증
say "5/5 받는 사람이 설치할 수 있는지 확인"
# brew가 쓰는 tap 사본은 별도 체크아웃이라 따로 당겨야 방금 푸시가 보인다.
LOCAL_TAP=$(brew --repository rayforvideos/tap 2>/dev/null || true)
if [[ -d "$LOCAL_TAP" ]]; then
    git -C "$LOCAL_TAP" pull --ff-only --quiet
    # fetch가 성공하면 릴리스 URL과 sha256이 실제로 맞는 것이다.
    brew fetch --cask rayforvideos/tap/attic >/dev/null || die "brew fetch가 실패했습니다"
    echo "  brew fetch ✓ (URL·체크섬 검증 통과)"
else
    echo "  ⚠︎ 이 맥에 tap이 설치되어 있지 않아 건너뜁니다: brew tap rayforvideos/tap"
fi

printf '\n\033[32m배포 완료: %s\033[0m\n' "https://github.com/$REPO/releases/tag/$TAG"
echo "brew install rayforvideos/tap/attic 로 새 버전이 설치됩니다."
