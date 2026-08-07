import Testing
import Foundation
@testable import AtticCore

@Suite("ReclaimGuard — 삭제 안전 경계")
struct ReclaimGuardTests {
    static let home = "/Users/tester"
    static let guardian = ReclaimGuard(home: home)

    /// 통과해야 하는 것들
    @Test("허용된 캐시 경로는 통과", arguments: [
        ("/Users/tester/Library/Developer/Xcode/DerivedData/App-abc", ReclaimKind.buildCache),
        ("/Users/tester/Library/Developer/Xcode/iOS DeviceSupport/17.0", ReclaimKind.deviceSupport),
        ("/Users/tester/Library/Caches/Homebrew", ReclaimKind.packageCache),
        ("/Users/tester/.npm/_cacache", ReclaimKind.packageCache),
        // Caches 직속 캐시는 고정 목록에서 구조 판정(.libraryCache)으로 옮겼다 —
        // 개발자 도구만 아는 목록으로는 일반 사용자의 앱을 찾지 못했다.
        ("/Users/tester/Library/Caches/JetBrains", ReclaimKind.libraryCache),
    ] as [(String, ReclaimKind)])
    func allowsKnownCaches(path: String, kind: ReclaimKind) {
        #expect(Self.guardian.check(path: path, kind: kind, lockfilePresent: false,
                                    ageDays: 0, isSymlink: false, resolvedPath: path,
                                    staleThresholdDays: 90) == nil)
    }

    @Test func allowsStaleNodeModulesWithLockfile() {
        let p = "/Users/tester/workspace/old-proj/node_modules"
        #expect(Self.guardian.check(path: p, kind: .nodeModules, lockfilePresent: true,
                                    ageDays: 200, isSymlink: false, resolvedPath: p,
                                    staleThresholdDays: 90) == nil)
    }

    /// CRITICAL 1 — 접두어 매칭이 컴포넌트 경계를 지키는지: 허용 뿌리의 "형제" 디렉터리는
    /// 절대 통과하면 안 된다. 단순 hasPrefix라면 이들이 통과해 버린다.
    @Test("허용 뿌리의 형제 디렉터리는 거부", arguments: [
        ("/Users/tester/Library/Caches/HomebrewBackup", ReclaimKind.packageCache),
        ("/Users/tester/Library/pnpm-store", ReclaimKind.packageCache),
        ("/Users/tester/Library/Developer/Xcode/DerivedData-archive", ReclaimKind.buildCache),
    ] as [(String, ReclaimKind)])
    func refusesSiblingsOfAllowedRoots(path: String, kind: ReclaimKind) {
        #expect(Self.guardian.check(path: path, kind: kind, lockfilePresent: false,
                                    ageDays: 0, isSymlink: false, resolvedPath: path,
                                    staleThresholdDays: 90) == .outsideAllowedRoots,
                "허용되면 안 됨: \(path)")
    }

    /// 거부해야 하는 것들 — 하나라도 통과하면 사용자 파일이 사라진다.
    /// IMPORTANT 5: kind를 nodeModules + "/node_modules"로 끝나는 경로 + lockfile 있음 +
    /// ageDays 999로 고정해 두면, kind의 자체 allowlist나 notNodeModules/missingLockfile/
    /// tooRecent 규칙은 전부 통과하게 되므로, 남는 것은 protectedPrefixes 규칙 하나뿐이다.
    /// 이 규칙을 지워도 다른 규칙이 대신 거부해 초록불이 나오는 일이 없다.
    @Test func refusesProtectedLocations() {
        for prefix in ["Documents", "Desktop", "Downloads", "Pictures",
                       "Movies", "Music", "Library/Mobile Documents", "Library/CloudStorage"] {
            let p = "/Users/tester/\(prefix)/proj/node_modules"
            #expect(Self.guardian.check(path: p, kind: .nodeModules, lockfilePresent: true,
                                        ageDays: 999, isSymlink: false, resolvedPath: p,
                                        staleThresholdDays: 90) == .protectedLocation,
                    "허용되면 안 됨: \(p)")
        }
    }

    @Test func refusesHomeItself() {
        #expect(Self.guardian.check(path: Self.home, kind: .packageCache, lockfilePresent: false,
                                    ageDays: 999, isSymlink: false, resolvedPath: Self.home,
                                    staleThresholdDays: 90) == .homeItself)
    }

    @Test func refusesSystemAndOtherUserRoots() {
        for p in ["/", "/System/Library", "/Library/Caches",
                  "/Applications/Xcode.app", "/Users/other/Library/Caches/Homebrew"] {
            #expect(Self.guardian.check(path: p, kind: .packageCache, lockfilePresent: false,
                                        ageDays: 999, isSymlink: false, resolvedPath: p,
                                        staleThresholdDays: 90) == .protectedLocation,
                    "허용되면 안 됨: \(p)")
        }
    }

    @Test func refusesNodeModulesWithoutLockfile() {
        let p = "/Users/tester/workspace/proj/node_modules"
        #expect(Self.guardian.check(path: p, kind: .nodeModules, lockfilePresent: false,
                                    ageDays: 999, isSymlink: false, resolvedPath: p,
                                    staleThresholdDays: 90) == .missingLockfile)
    }

    @Test func refusesRecentNodeModules() {
        let p = "/Users/tester/workspace/proj/node_modules"
        #expect(Self.guardian.check(path: p, kind: .nodeModules, lockfilePresent: true,
                                    ageDays: 3, isSymlink: false, resolvedPath: p,
                                    staleThresholdDays: 90) == .tooRecent(days: 3))
    }

    /// CRITICAL 2 (guard-level slice): the fail-closed default used by the
    /// scanner/reclaimer when a project's mtime can't be read is `ageDays: 0`
    /// — confirm the guard treats that as "too recent", not as safe-to-trash.
    @Test func refusesUnreadableAgeDefaultOfZero() {
        let p = "/Users/tester/workspace/proj/node_modules"
        #expect(Self.guardian.check(path: p, kind: .nodeModules, lockfilePresent: true,
                                    ageDays: 0, isSymlink: false, resolvedPath: p,
                                    staleThresholdDays: 90) == .tooRecent(days: 0))
    }

    @Test func refusesNonNodeModulesPathUnderNodeModulesKind() {
        // 프로젝트 소스를 nodeModules 종류로 넘기는 사고를 막는다
        let p = "/Users/tester/workspace/proj/src"
        #expect(Self.guardian.check(path: p, kind: .nodeModules, lockfilePresent: true,
                                    ageDays: 999, isSymlink: false, resolvedPath: p,
                                    staleThresholdDays: 90) == .notNodeModules)
    }

    @Test func refusesSymlink() {
        let p = "/Users/tester/Library/Caches/Homebrew"
        #expect(Self.guardian.check(path: p, kind: .packageCache, lockfilePresent: false,
                                    ageDays: 0, isSymlink: true, resolvedPath: p,
                                    staleThresholdDays: 90) == .symlink)
    }

    @Test func refusesEscapingResolvedPath() {
        let p = "/Users/tester/Library/Caches/Homebrew"
        // 표준화하면 허용 뿌리를 벗어나는 경로(../ 탈출)
        #expect(Self.guardian.check(path: p, kind: .packageCache, lockfilePresent: false,
                                    ageDays: 0, isSymlink: false,
                                    resolvedPath: "/Users/tester/Documents/secret",
                                    staleThresholdDays: 90) == .escapesRoot)
    }

    /// IMPORTANT 7 — the guard must not simply trust a caller-supplied
    /// `resolvedPath`; it normalizes `path` itself and refuses any literal
    /// `..` component, even when the caller claims `resolvedPath == path`.
    @Test func refusesLiteralDotDotComponentEvenWhenResolvedPathMatches() {
        let p = "/Users/tester/Library/Caches/Homebrew/../../Documents/secret"
        #expect(Self.guardian.check(path: p, kind: .packageCache, lockfilePresent: false,
                                    ageDays: 0, isSymlink: false, resolvedPath: p,
                                    staleThresholdDays: 90) == .escapesRoot)
    }

    /// IMPORTANT 5 — isolate the `.git` rule specifically: use a nodeModules
    /// path (ends with "/node_modules", so notNodeModules can't fire),
    /// lockfile present (missingLockfile can't fire), ageDays 999 (tooRecent
    /// can't fire), with a `.git` component elsewhere in the path. Only the
    /// git-component rule can cause this to be refused.
    @Test func refusesGitDirectories() {
        let p = "/Users/tester/workspace/proj/.git/node_modules"
        #expect(Self.guardian.check(path: p, kind: .nodeModules, lockfilePresent: true,
                                    ageDays: 999, isSymlink: false, resolvedPath: p,
                                    staleThresholdDays: 90) == .protectedLocation)
    }

    @Test func refusesArchivesAndSimulatorEvenThoughUnderDeveloper() {
        // 계획에서 의도적으로 제외한 것들 — 규칙에 없으므로 통과하면 안 된다
        for p in ["/Users/tester/Library/Developer/Xcode/Archives/2026",
                  "/Users/tester/Library/Developer/CoreSimulator/Devices/x"] {
            #expect(Self.guardian.check(path: p, kind: .buildCache, lockfilePresent: false,
                                        ageDays: 999, isSymlink: false, resolvedPath: p,
                                        staleThresholdDays: 90) == .outsideAllowedRoots,
                    "허용되면 안 됨: \(p)")
        }
    }

    /// 놓치고 있던 캐시들 — 이 맥에 실제로 크게 존재하는 것들을 확인했다
    /// (docs 참고: .cocoapods 6.1GB, .yarn/berry/cache 2.2GB, Library/Logs 1.2GB).
    @Test("새로 추가한 캐시 경로는 통과", arguments: [
        ("/Users/tester/.cocoapods", ReclaimKind.packageCache),
        ("/Users/tester/.yarn/berry/cache", ReclaimKind.packageCache),
        ("/Users/tester/.android/cache", ReclaimKind.packageCache),
        ("/Users/tester/.android/build-cache", ReclaimKind.packageCache),
        ("/Users/tester/Library/Logs", ReclaimKind.appCache),
    ] as [(String, ReclaimKind)])
    func allowsNewlyAddedCaches(path: String, kind: ReclaimKind) {
        #expect(Self.guardian.check(path: path, kind: kind, lockfilePresent: false,
                                    ageDays: 0, isSymlink: false, resolvedPath: path,
                                    staleThresholdDays: 90) == nil)
    }

    /// 캐시가 아니라 설치본이라 지우면 재설치가 필요한 것들 — 절대 허용 목록에
    /// 들어가면 안 된다. 이들이 이 맥에서 각각 3.0GB/1.1GB로 캐시들 못지않게 크더라도
    /// 지우면 도구 자체가 사라진다는 점에서 결이 다르다.
    @Test("설치본은 거부 — 캐시가 아니다", arguments: [
        ("/Users/tester/.nvm", ReclaimKind.packageCache),
        ("/Users/tester/.rustup", ReclaimKind.packageCache),
    ] as [(String, ReclaimKind)])
    func refusesInstallationsNotCaches(path: String, kind: ReclaimKind) {
        #expect(Self.guardian.check(path: path, kind: kind, lockfilePresent: false,
                                    ageDays: 0, isSymlink: false, resolvedPath: path,
                                    staleThresholdDays: 90) == .outsideAllowedRoots,
                "허용되면 안 됨: \(path)")
    }

    @Test func trimsTrailingSlashFromHome() {
        let g = ReclaimGuard(home: "/Users/tester/")
        let p = "/Users/tester/Library/Caches/Homebrew"
        #expect(g.check(path: p, kind: .packageCache, lockfilePresent: false,
                        ageDays: 0, isSymlink: false, resolvedPath: p,
                        staleThresholdDays: 90) == nil)
    }
}

@Suite("ReclaimGuard 경계 — 대소문자·주입 보호경로")
struct ReclaimGuardBoundaryTests {
    /// APFS는 기본이 대소문자 무시라 `~/documents/x/node_modules`가 실제로 열린다.
    /// 문자열 비교가 대소문자를 구분하면 Documents 보호를 그대로 통과한다
    /// (실측 2026-08-06: 경로가 열리고 resolvingSymlinksInPath도 정규화하지 않는다).
    @Test(arguments: ["documents", "DOCUMENTS", "Desktop", "desktop", "DownLoads"])
    func refusesProtectedFoldersRegardlessOfCase(_ folder: String) {
        let home = "/Users/tester"
        let guardian = ReclaimGuard(home: home)
        let path = "\(home)/\(folder)/proj/node_modules"
        let refusal = guardian.check(path: path, kind: .nodeModules, lockfilePresent: true,
                                    ageDays: 999, isSymlink: false, resolvedPath: path,
                                    staleThresholdDays: 90)
        #expect(refusal == .protectedLocation)
    }

    /// 홈 자체도 대소문자만 다르면 통과하면 안 된다.
    @Test func refusesHomeItselfCaseInsensitively() {
        let guardian = ReclaimGuard(home: "/Users/tester")
        let refusal = guardian.check(path: "/users/TESTER", kind: .nodeModules,
                                    lockfilePresent: true, ageDays: 999, isSymlink: false,
                                    resolvedPath: "/users/TESTER", staleThresholdDays: 90)
        #expect(refusal != nil)
    }

    /// 설정의 "보호할 프로젝트 경로"가 실제로 가드에 반영돼야 한다 — 반영되지
    /// 않으면 사용자는 보호했다고 믿는 폴더가 휴지통으로 가는 것을 보게 된다.
    @Test func honorsInjectedProtectedPaths() {
        let home = "/Users/tester"
        let path = "\(home)/work/client-x/node_modules"
        let unprotected = ReclaimGuard(home: home)
        #expect(unprotected.check(path: path, kind: .nodeModules, lockfilePresent: true,
                                 ageDays: 999, isSymlink: false, resolvedPath: path,
                                 staleThresholdDays: 90) == nil)

        let guarded = ReclaimGuard(home: home,
                                   extraProtected: ["\(home)/work/client-x"])
        #expect(guarded.check(path: path, kind: .nodeModules, lockfilePresent: true,
                             ageDays: 999, isSymlink: false, resolvedPath: path,
                             staleThresholdDays: 90) == .protectedLocation)
    }

    /// 형제 디렉토리가 접두사로 걸려선 안 된다: /work 보호가 /work-other를 막으면
    /// 사용자가 의도하지 않은 폴더까지 정리 대상에서 빠진다.
    @Test func injectedProtectionAnchorsOnPathComponents() {
        let home = "/Users/tester"
        let guarded = ReclaimGuard(home: home, extraProtected: ["\(home)/work"])
        let sibling = "\(home)/work-other/proj/node_modules"
        #expect(guarded.check(path: sibling, kind: .nodeModules, lockfilePresent: true,
                              ageDays: 999, isSymlink: false, resolvedPath: sibling,
                              staleThresholdDays: 90) == nil)
    }
}

@Suite("ReclaimGuard — Electron 앱 캐시")
struct ElectronCacheGuardTests {
    let home = "/Users/tester"
    var support: String { "\(home)/Library/Application Support" }

    private func check(_ path: String) -> ReclaimRefusal? {
        ReclaimGuard(home: home).check(path: path, kind: .electronCache,
                                      lockfilePresent: false, ageDays: 0,
                                      isSymlink: false, resolvedPath: path,
                                      staleThresholdDays: 90)
    }

    /// 실측한 실제 구조(2026-08-06): 앱 루트 바로 아래, Partitions 아래,
    /// DesktopProfile 버전 아래 세 형태로 같은 이름의 캐시 폴더가 나온다.
    @Test(arguments: [
        "Slack/Cache",
        "Slack/Service Worker",
        "Claude/Code Cache",
        "Notion/Partitions/notion/Cache",
        "Notion/Partitions/notion/Service Worker",
        "Figma/DesktopProfile/v42/Code Cache",
        "Figma/DesktopProfile/v42/DawnWebGPUCache",
    ])
    func allowsChromiumCacheFolders(_ relative: String) {
        #expect(check("\(support)/\(relative)") == nil)
    }

    /// **앱 데이터 루트는 절대 후보가 아니다** — 통째로 지우면 로그인·설정·로컬
    /// 문서가 사라진다. 캐시가 아닌 하위 폴더도 마찬가지다.
    @Test(arguments: [
        "Slack",                       // 앱 루트
        "Slack/IndexedDB",             // 로컬 DB
        "Slack/Local Storage",         // 로그인 상태
        "Slack/Cookies",
        "Notion/notion.db",            // 로컬 문서 DB
        "Notion/Partitions",           // 파티션 컨테이너
        "Notion/Partitions/notion",    // 파티션 루트
        "Claude/vm_bundles",           // VM 이미지 — 캐시가 아니다
        "Figma/DesktopProfile",
        "Figma/DesktopProfile/v42",
    ])
    func refusesAppDataAndNonCacheFolders(_ relative: String) {
        #expect(check("\(support)/\(relative)") != nil)
    }

    /// Application Support 자체와 그 밖의 경로는 이름이 Cache여도 거부한다.
    @Test func refusesSupportRootAndOutsidePaths() {
        #expect(check(support) != nil)
        #expect(check("\(home)/Library/Application Support/Cache") != nil)   // 앱 이름 없음
        #expect(check("\(home)/Documents/Cache") != nil)
        #expect(check("\(home)/Library/Caches/Cache") != nil)
        // 너무 깊은 곳은 거부 — 규칙이 예상한 구조를 넘어선다
        #expect(check("\(support)/A/b/c/d/Cache") != nil)
    }
}

@Suite("ReclaimGuard — 일반 앱 캐시(구조 판정)")
struct LibraryCacheGuardTests {
    let home = "/Users/tester"

    private func check(_ path: String) -> ReclaimRefusal? {
        ReclaimGuard(home: home).check(path: path, kind: .libraryCache,
                                      lockfilePresent: false, ageDays: 0,
                                      isSymlink: false, resolvedPath: path,
                                      staleThresholdDays: 90)
    }

    /// macOS 관례상 `~/Library/Caches`는 앱이 다시 만들 수 있는 것을 두는 곳이다 —
    /// 고정 목록 대신 구조로 잡아야 개발자 도구가 아닌 앱(Spotify·Office 등)도
    /// 찾을 수 있다.
    @Test(arguments: ["Spotify", "com.spotify.client", "Adobe", "Zoom", "Google"])
    func allowsCachesDirectChildren(_ name: String) {
        #expect(check("\(home)/Library/Caches/\(name)") == nil)
    }

    /// App Store 앱은 샌드박스 컨테이너 안에 있다 — 실측: KakaoTalk 1.7GB가
    /// 고정 목록 방식으로는 전혀 보이지 않았다.
    @Test func allowsSandboxContainerCaches() {
        #expect(check("\(home)/Library/Containers/com.kakao.KakaoTalkMac/Data/Library/Caches") == nil)
    }

    /// Apple 것은 시스템이 스스로 관리한다 — 우리가 손대지 않는다.
    @Test(arguments: ["com.apple.Safari", "com.apple.helpd", "com.apple.parsecd"])
    func refusesAppleOwnedCaches(_ name: String) {
        #expect(check("\(home)/Library/Caches/\(name)") != nil)
    }

    /// 경계: Caches 자체, 그 아래 깊은 경로, 컨테이너의 데이터 폴더는 거부한다.
    @Test func refusesRootsAndNonCachePaths() {
        #expect(check("\(home)/Library/Caches") != nil)
        #expect(check("\(home)/Library/Caches/Spotify/deep/inner") != nil)
        #expect(check("\(home)/Library/Containers/com.kakao.KakaoTalkMac") != nil)
        #expect(check("\(home)/Library/Containers/com.kakao.KakaoTalkMac/Data") != nil)
        #expect(check("\(home)/Library/Containers/com.kakao.KakaoTalkMac/Data/Library") != nil)
        #expect(check("\(home)/Library/Application Support/Spotify") != nil)
        #expect(check("\(home)/Documents/Caches") != nil)
    }
}

@Suite("ReclaimGuard — 사용자 파일 (되돌릴 수 없는 것들)")
struct UserFileGuardTests {
    let home = "/Users/tester"

    private func check(_ path: String, _ kind: ReclaimKind, ageDays: Int = 200) -> ReclaimRefusal? {
        ReclaimGuard(home: home).check(path: path, kind: kind, lockfilePresent: false,
                                      ageDays: ageDays, isSymlink: false,
                                      resolvedPath: path, staleThresholdDays: 90)
    }

    /// Downloads 직속에서 오래된 것은 **종류를 가리지 않는다**. 확장자로 가리던
    /// 때는 90일 넘은 1,878MB 중 동영상·이미지·psd 400MB 이상을 놓쳤다(실측).
    @Test(arguments: ["app.dmg", "tool.pkg", "sdk.zip", "Xcode.xip", "disk.iso",
                      "report.pdf", "회의녹화.mp4", "시안.psd", "발표.pptx", "notes.txt",
                      "사진", "확장자없는파일"])
    func allowsAnyOldDownloadInRoot(_ name: String) {
        #expect(check("\(home)/Downloads/\(name)", .staleInstaller) == nil)
    }

    @Test func refusesRecentOrNestedOrOutsideDownloads() {
        // 최근 것은 손대지 않는다
        #expect(check("\(home)/Downloads/new.dmg", .staleInstaller, ageDays: 3) != nil)
        // 하위 폴더의 개별 파일은 항목이 아니다 — 폴더 하나로 제안한다(스캐너가
        // 안에 든 것이 전부 오래됐는지 확인한 뒤에).
        #expect(check("\(home)/Downloads/keep/app.dmg", .staleInstaller) != nil)
        #expect(check("\(home)/Downloads/a/b/c.mp4", .staleInstaller) != nil)
        // Downloads 밖은 이 종류가 아니다
        #expect(check("\(home)/Documents/app.dmg", .staleInstaller) != nil)
        #expect(check("\(home)/Desktop/app.dmg", .staleInstaller) != nil)
        // Downloads 자체는 절대 후보가 아니다
        #expect(check("\(home)/Downloads", .staleInstaller) != nil)
    }

    /// 스크린샷은 **파일명이 스크린샷 형식일 때만**. 데스크탑은 작업 파일이 섞이는
    /// 곳이라 이름으로 정확히 좁혀야 한다.
    @Test(arguments: [
        "스크린샷 2026-03-01 오후 1.23.45.png",
        "Screenshot 2026-03-01 at 1.23.45 PM.png",
        "Screen Shot 2026-03-01 at 1.23.45 PM.png",
    ])
    func allowsOldScreenshotsByFilename(_ name: String) {
        #expect(check("\(home)/Desktop/\(name)", .oldScreenshot) == nil)
    }

    @Test func refusesNonScreenshotFilesOnDesktop() {
        #expect(check("\(home)/Desktop/발표자료.png", .oldScreenshot) != nil)
        #expect(check("\(home)/Desktop/IMG_1234.png", .oldScreenshot) != nil)
        #expect(check("\(home)/Desktop/스크린샷.png", .oldScreenshot) != nil)   // 날짜 없음
        #expect(check("\(home)/Desktop/설계.key", .oldScreenshot) != nil)
        // 최근 스크린샷은 남긴다
        #expect(check("\(home)/Desktop/스크린샷 2026-08-05 오후 1.23.45.png",
                     .oldScreenshot, ageDays: 1) != nil)
    }

    /// 큰 파일은 홈 안이어야 하고, 보호 폴더(문서·사진 등)는 그대로 보호된다 —
    /// 무엇인지 앱이 판단할 수 없으므로 경계를 좁게 둔다.
    @Test func largeFileBoundaries() {
        #expect(check("\(home)/movie.mp4", .largeFile) == nil)
        #expect(check("\(home)/work/build.zip", .largeFile) == nil)
        // 사용자가 넣어둔 곳을 봐야 기능이 성립한다 — 대신 자동 선택에서 빼고
        // 경로·경고를 함께 보여준다(SpacePane.userFileKinds).
        #expect(check("\(home)/Documents/큰영상.mov", .largeFile) == nil)
        #expect(check("\(home)/Desktop/작업본.psd", .largeFile) == nil)
        // 사진 라이브러리는 하나의 큰 묶음이라 예외에서 뺀다
        #expect(check("\(home)/Pictures/사진.heic", .largeFile) != nil)
        #expect(check("/Users/other/movie.mp4", .largeFile) != nil)
        #expect(check("\(home)/Library/Caches/x", .largeFile) != nil)
    }
}
