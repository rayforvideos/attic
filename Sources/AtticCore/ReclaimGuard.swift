import Foundation

/// Reasons a candidate path is refused by `ReclaimGuard`. A `nil` result from
/// `check` means the path passed every safety rule.
public enum ReclaimRefusal: Sendable, Equatable {
    case outsideAllowedRoots
    case protectedLocation
    case notNodeModules
    case missingLockfile
    case tooRecent(days: Int)
    case symlink
    case escapesRoot
    case homeItself
    /// 실행 중인 앱·프로세스가 쓰고 있다. 옮기면 휴지통에서 "사용 중"으로
    /// 되돌아오고, 열린 핸들로 휴지통 안에 계속 쓴다.
    case inUse
}

/// The category of reclaimable item. Each kind maps to a fixed set of
/// allowed root prefixes (see `ReclaimGuard.allowedRoots`), except
/// `nodeModules`, which is instead governed by lockfile/age/name rules.
public enum ReclaimKind: String, Sendable, CaseIterable, Codable {
    case buildCache
    case deviceSupport
    case packageCache
    case appCache
    case nodeModules
    /// Chromium 기반 앱(Electron)이 만드는 웹 캐시. 고정 경로가 아니라 **구조로**
    /// 판정한다 — 앱 이름을 미리 알 수 없기 때문이다(실측: Notion 6.9GB,
    /// Asana 2.1GB, Claude 1.5GB, Slack 1.2GB, Figma 1.1GB).
    case electronCache
    /// 앱이 `~/Library/Caches`(또는 샌드박스 컨테이너 안 같은 자리)에 두는 캐시.
    /// **구조로 판정한다** — 고정 목록은 개발자 도구만 알아서, 일반 사용자의 앱
    /// (Spotify·Office·KakaoTalk 등)을 전혀 찾지 못했다.
    case libraryCache
    /// Downloads에 남은 오래된 설치 파일. **사용자 파일이라 되돌릴 수 없다** —
    /// 앱은 찾아서 보여주기만 하고, 자동 선택하지 않는다.
    /// Downloads에서 오래 안 쓴 항목. 이름이 "설치 파일"인 것은 처음 만들 때
    /// 설치 파일만 다뤘기 때문이고, 지금은 종류를 가리지 않는다. case 이름이
    /// 저장된 스캔 결과의 키(Codable raw value)라 바꾸지 않는다.
    case staleInstaller
    /// 오래된 스크린샷. 파일명이 스크린샷 형식일 때만 후보다.
    case oldScreenshot
    /// 홈의 큰 파일. 무엇인지 앱이 판단할 수 없으므로 목록으로만 드러낸다.
    case largeFile
    /// Xcode가 배포용으로 만든 보관본(`*.xcarchive`). 캐시가 아니라 **결과물**이라
    /// 다시 만들려면 그 시점의 소스로 다시 빌드해야 한다 — 배포한 빌드의 크래시
    /// 로그를 해석하는 데도 쓰이므로 자동 선택에서 빼고 경고를 붙인다.
    case xcodeArchive
}

/// The single safety boundary for the reclaim feature. Every candidate path —
/// at scan time and again at execution time — must pass `check` before it can
/// ever reach `FileManager.trashItem`. This is allowlist-only: a path is
/// refused unless it matches a known rule.
public struct ReclaimGuard: Sendable {
    public let home: String
    /// 사용자가 설정에서 지정한 보호 경로. 이걸 받지 않으면 설정 화면이
    /// "보호할 프로젝트 경로"라고 말하면서 실제로는 프로세스 탐지에만 쓰여,
    /// 사용자가 보호했다고 믿는 폴더의 node_modules가 휴지통으로 간다.
    public let extraProtected: [String]

    public init(home: String, extraProtected: [String] = []) {
        // Normalize away a trailing slash so prefix comparisons below don't
        // have to special-case "home ends with /".
        func trimSlash(_ p: String) -> String {
            var t = p
            while t.count > 1 && t.hasSuffix("/") { t.removeLast() }
            return t
        }
        self.home = trimSlash(home)
        self.extraProtected = extraProtected
            .map { trimSlash(($0 as NSString).expandingTildeInPath) }
            .filter { !$0.isEmpty }
    }

    /// Home-relative prefixes that are always protected, regardless of kind.
    public static let protectedPrefixes: [String] = [
        "Documents",
        "Desktop",
        "Downloads",
        "Pictures",
        "Movies",
        "Music",
        "Library/Mobile Documents",
        "Library/CloudStorage",
    ]

    /// The allowlisted root directories per kind, rooted at `home`.
    public static func allowedRoots(home: String) -> [ReclaimKind: [String]] {
        [
            .buildCache: [
                "\(home)/Library/Developer/Xcode/DerivedData",
            ],
            .xcodeArchive: [
                "\(home)/Library/Developer/Xcode/Archives",
            ],
            .deviceSupport: [
                "\(home)/Library/Developer/Xcode/iOS DeviceSupport",
                "\(home)/Library/Developer/Xcode/watchOS DeviceSupport",
                "\(home)/Library/Developer/Xcode/tvOS DeviceSupport",
            ],
            // 의도적으로 뺀 것들 — 캐시가 아니라 설치본이라 지우면 재설치(도구 자체를
            // 다시 받는 일)가 필요하다. 재다운로드로 끝나는 캐시와는 결이 다르다:
            // ~/.nvm (node 버전 설치본), ~/.rustup (rustc/cargo 툴체인 설치본),
            // ~/Library/Android/sdk (Android SDK 본체).
            .packageCache: [
                "\(home)/Library/Caches/Homebrew",
                "\(home)/.npm/_cacache",
                "\(home)/Library/pnpm",
                "\(home)/Library/Caches/pnpm",
                "\(home)/Library/Caches/Yarn",
                "\(home)/.gradle/caches",
                "\(home)/Library/Caches/CocoaPods",
                "\(home)/Library/Caches/pip",
                "\(home)/.cache/uv",
                "\(home)/Library/Caches/ms-playwright",
                "\(home)/Library/Caches/ms-playwright-mcp",
                "\(home)/.cargo/registry/cache",
                "\(home)/.cocoapods",
                "\(home)/.yarn/berry/cache",
                "\(home)/.android/cache",
                "\(home)/.android/build-cache",
            ],
            // Caches 직속 항목은 .libraryCache가 구조로 잡는다 — 여기 남기면
            // 같은 경로가 두 종류로 두 번 뜬다. Logs는 Caches 밖이라 남긴다.
            .appCache: [
                "\(home)/Library/Logs",
            ],
            .nodeModules: [],
            .libraryCache: [],
        ]
    }

    /// Returns nil if `path` passes every safety rule for `kind`, otherwise
    /// the first refusal reason encountered.
    public func check(
        path: String,
        kind: ReclaimKind,
        lockfilePresent: Bool,
        ageDays: Int,
        isSymlink: Bool,
        resolvedPath: String,
        staleThresholdDays: Int
    ) -> ReclaimRefusal? {
        // 1. Symlinks are refused outright — never follow them into the trash.
        if isSymlink {
            return .symlink
        }

        // 2. Never trust the caller's word for it: normalize `path` ourselves
        // (lexically — this does not touch the filesystem) and refuse if any
        // remaining component is `..`. A caller-supplied `resolvedPath` is
        // still cross-checked below, but that alone would let a caller who
        // gets the resolution wrong (or lies) slip a `../`-laden path past us.
        if containsDotDotComponent(path) {
            return .escapesRoot
        }

        // 3. If normalization changed the path, the resolved path must still
        // land inside an allowed root. This defends against a symlink-free
        // but still-redirected path (e.g. via ../ segments) that the caller
        // resolved on our behalf.
        if resolvedPath != path {
            if containsDotDotComponent(resolvedPath)
                || !isPathSafe(resolvedPath, kind: kind, lockfilePresent: lockfilePresent,
                                ageDays: ageDays, staleThresholdDays: staleThresholdDays) {
                return .escapesRoot
            }
        }

        if let refusal = protectedOrOutOfBounds(path: path, kind: kind) {
            return refusal
        }

        // .git anywhere in the path is refused, regardless of kind.
        if containsGitComponent(path) {
            return .protectedLocation
        }

        if kind == .electronCache {
            return checkElectronCache(path: path)
        }

        if kind == .libraryCache {
            return checkLibraryCache(path: path)
        }

        if kind == .staleInstaller {
            return checkStaleDownload(path: path, ageDays: ageDays,
                                      staleThresholdDays: staleThresholdDays)
        }

        if kind == .oldScreenshot {
            return checkOldScreenshot(path: path, ageDays: ageDays,
                                      staleThresholdDays: staleThresholdDays)
        }

        if kind == .largeFile {
            return checkLargeFile(path: path)
        }

        if kind == .xcodeArchive {
            return checkXcodeArchive(path: path, ageDays: ageDays,
                                     staleThresholdDays: staleThresholdDays)
        }

        if kind == .nodeModules {
            return checkNodeModules(path: path, lockfilePresent: lockfilePresent,
                                     ageDays: ageDays, staleThresholdDays: staleThresholdDays)
        }

        let roots = Self.allowedRoots(home: home)[kind] ?? []
        if !roots.contains(where: { matchesRoot(path, root: $0) }) {
            return .outsideAllowedRoots
        }

        return nil
    }

    // MARK: - Helpers

    /// Component-anchored root match: `path` must equal `root` or have
    /// `root` as a full path-component prefix. A plain `hasPrefix(root)`
    /// would also match unrelated siblings like `root + "Backup"`.
    /// **대소문자를 무시해 비교한다.** APFS 기본 볼륨은 대소문자를 구분하지 않아
    /// `~/documents/...`가 실제로 열리는데(실측 2026-08-06), 대소문자를 구분해
    /// 비교하면 Documents 보호가 그대로 뚫린다. resolvingSymlinksInPath도 대소문자를
    /// 정규화하지 않으므로 실행 직전 재검증에서도 걸리지 않는다.
    private func matchesRoot(_ path: String, root: String) -> Bool {
        if path.compare(root, options: .caseInsensitive) == .orderedSame { return true }
        return path.lowercased().hasPrefix(root.lowercased() + "/")
    }

    private func containsDotDotComponent(_ path: String) -> Bool {
        path.split(separator: "/").contains("..")
    }

    /// 종류에 따라 보호 폴더 예외가 다르다. 설치 파일은 Downloads, 스크린샷은
    /// 저장 위치가 될 수 있는 폴더만 예외로 둔다 — 그 종류는 확장자·파일명·나이로
    /// 후보를 좁히므로 예외가 사용자 자료로 번지지 않는다.
    private func protectionExemptions(for kind: ReclaimKind) -> [String] {
        switch kind {
        case .staleInstaller: ["Downloads"]
        // 이름 규칙(접두어 + 날짜)이 구체적이라 어디에 있든 스크린샷이다.
        // 데스크탑만 예외로 두면 작업 폴더·문서로 옮겨둔 것을 전부 놓친다.
        case .oldScreenshot: ["Desktop", "Downloads", "Pictures", "Documents"]
        // 큰 파일은 **사용자가 넣어둔 곳**에 있다 — 그 폴더를 보지 않으면 기능이
        // 무력하다(실측: 보호 때문에 0개가 잡혔다). 대신 이 종류는 자동 선택에서
        // 빼고, 경로를 보여주고, 경고 문구를 붙여 사용자가 하나씩 고르게 한다.
        // Pictures는 사진 라이브러리(하나의 큰 묶음)라 예외에서 뺀다.
        case .largeFile: ["Documents", "Desktop", "Downloads", "Movies", "Music"]
        default: []
        }
    }

    private func protectedOrOutOfBounds(path: String,
                                        kind: ReclaimKind) -> ReclaimRefusal? {
        if path.compare(home, options: .caseInsensitive) == .orderedSame {
            return .homeItself
        }
        // 시스템 경로 비교도 대소문자를 무시한다 — "/system/..."도 같은 파일이다.
        let lower = path.lowercased()
        if path == "/" || lower.hasPrefix("/system") || lower.hasPrefix("/library")
            || lower.hasPrefix("/applications") {
            return .protectedLocation
        }
        if !matchesRoot(path, root: home) {
            // Not under home at all (e.g. another user's home) and not one of
            // the system roots checked above.
            return .protectedLocation
        }
        for prefix in Self.protectedPrefixes {
            if matchesRoot(path, root: "\(home)/\(prefix)") {
                // Downloads·Desktop은 설치 파일·스크린샷 종류에서만 예외다.
                // 그 종류는 파일명·확장자·나이로 후보를 좁히므로 이 예외가
                // 사용자 자료로 번지지 않는다.
                if protectionExemptions(for: kind).contains(prefix) { continue }
                return .protectedLocation
            }
        }
        for protected in extraProtected where matchesRoot(path, root: protected) {
            return .protectedLocation
        }
        return nil
    }

    private func containsGitComponent(_ path: String) -> Bool {
        path.split(separator: "/").contains(".git")
    }

    /// Electron 캐시의 허용 규칙. 이 종류만 고정 경로 대신 **구조**로 판정하므로,
    /// 경계를 최대한 좁게 잡는다:
    ///  1. `~/Library/Application Support/` 바로 아래의 앱 폴더 안이어야 한다
    ///  2. 마지막 컴포넌트가 Chromium이 만드는 **캐시 폴더 이름과 정확히 일치**해야 한다
    ///  3. 앱 폴더 아래 깊이가 3을 넘지 않아야 한다(Partitions/<이름>/Cache,
    ///     DesktopProfile/<버전>/Cache가 실측에서 확인된 가장 깊은 형태다)
    ///
    /// 이 규칙 덕에 앱 데이터 루트(로그인·로컬 DB·문서)는 구조적으로 후보가 될 수
    /// 없다 — 마지막 컴포넌트가 캐시 이름이어야 하기 때문이다.
    public static let chromiumCacheNames: Set<String> = [
        "Cache", "Code Cache", "GPUCache", "Service Worker",
        "DawnWebGPUCache", "DawnGraphiteCache", "Shared Dictionary",
    ]

    private func checkElectronCache(path: String) -> ReclaimRefusal? {
        let support = "\(home)/Library/Application Support"
        guard matchesRoot(path, root: support), path != support else {
            return .outsideAllowedRoots
        }
        let relative = String(path.dropFirst(support.count + 1))
        let parts = relative.split(separator: "/").map(String.init)
        // 앱 폴더 + 최소 한 단계(캐시 폴더). 최대 앱 폴더 + 3단계.
        guard parts.count >= 2, parts.count <= 4 else { return .outsideAllowedRoots }
        guard let last = parts.last, Self.chromiumCacheNames.contains(last) else {
            return .outsideAllowedRoots
        }
        return nil
    }

    /// 일반 앱 캐시의 허용 규칙. 두 자리만 본다:
    ///  - `~/Library/Caches/<앱 한 단계>`
    ///  - `~/Library/Containers/<번들ID>/Data/Library/Caches`
    ///
    /// Apple이 쓰는 이름(`com.apple.*`)은 제외한다 — 시스템이 스스로 관리하고,
    /// 우리가 지워서 얻을 것보다 잃을 위험이 크다.
    private func checkLibraryCache(path: String) -> ReclaimRefusal? {
        let caches = "\(home)/Library/Caches"
        if matchesRoot(path, root: caches), path != caches {
            let relative = String(path.dropFirst(caches.count + 1))
            let parts = relative.split(separator: "/").map(String.init)
            guard parts.count == 1, let name = parts.first else { return .outsideAllowedRoots }
            guard !name.lowercased().hasPrefix("com.apple.") else { return .protectedLocation }
            return nil
        }

        let containers = "\(home)/Library/Containers"
        if matchesRoot(path, root: containers), path != containers {
            let relative = String(path.dropFirst(containers.count + 1))
            let parts = relative.split(separator: "/").map(String.init)
            // <번들ID>/Data/Library/Caches 정확히 이 형태만
            guard parts.count == 4, parts[1] == "Data", parts[2] == "Library",
                  parts[3] == "Caches" else { return .outsideAllowedRoots }
            guard !parts[0].lowercased().hasPrefix("com.apple.") else { return .protectedLocation }
            return nil
        }

        return .outsideAllowedRoots
    }

    /// Downloads **직속 항목**(파일이든 폴더든)이 오래됐으면 후보다.
    ///
    /// 예전에는 설치 확장자(dmg·pkg·zip…)만 봤다. 그런데 Downloads에서 썩는
    /// 것의 태반이 설치 파일이 아니다(실측: 90일 넘은 1,878MB 중 동영상 210MB,
    /// 이미지 90MB, psd·pptx…). Downloads는 원래 **거쳐 가는 곳**이라 다 쓴 뒤
    /// 남는 것이 정상이고, 확장자로 가릴 이유가 없다.
    ///
    /// 직속만 후보인 것은 유지한다 — 하위 폴더는 그 폴더 **하나**로 제안해야
    /// 사용자가 알아보는 단위가 되고(파일 166개를 늘어놓으면 훑을 수 없다),
    /// 폴더는 안에 든 것이 **전부** 오래됐을 때만 후보다(스캐너가 확인한다).
    private func checkStaleDownload(path: String, ageDays: Int,
                                    staleThresholdDays: Int) -> ReclaimRefusal? {
        let downloads = "\(home)/Downloads"
        guard matchesRoot(path, root: downloads), path != downloads else {
            return .outsideAllowedRoots
        }
        let relative = String(path.dropFirst(downloads.count + 1))
        guard !relative.contains("/") else { return .outsideAllowedRoots }
        guard ageDays >= staleThresholdDays else { return .tooRecent(days: ageDays) }
        return nil
    }

    /// 스크린샷은 **파일명 형식으로** 판정한다. 데스크탑에는 작업 파일이 섞여
    /// 있어서 "png이고 오래됐다"만으로는 사용자 자료를 지울 수 있다.
    /// macOS가 붙이는 이름: "스크린샷 2026-03-01 오후 1.23.45.png",
    /// "Screenshot 2026-03-01 at 1.23.45 PM.png", 옛 버전 "Screen Shot ...".
    public static func isScreenshotName(_ name: String) -> Bool {
        let prefixes = ["스크린샷 ", "Screenshot ", "Screen Shot ", "スクリーンショット "]
        guard prefixes.contains(where: { name.hasPrefix($0) }) else { return false }
        guard name.lowercased().hasSuffix(".png") || name.lowercased().hasSuffix(".jpg") else {
            return false
        }
        // 날짜가 들어 있어야 한다 — "스크린샷.png"처럼 사용자가 바꿔 둔 이름은 제외.
        return name.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil
    }

    /// 보관본 하나(`*.xcarchive`)만 후보다. Archives 폴더나 날짜 폴더 자체를
    /// 대상으로 삼으면 여러 빌드를 한꺼번에 지우게 되고, 사용자가 무엇을 잃는지
    /// 알 수 없다 — 빌드 하나씩 보여주고 고르게 한다.
    private func checkXcodeArchive(path: String, ageDays: Int,
                                   staleThresholdDays: Int) -> ReclaimRefusal? {
        let root = "\(home)/Library/Developer/Xcode/Archives"
        guard matchesRoot(path, root: root), path != root else { return .outsideAllowedRoots }
        guard (path as NSString).pathExtension.lowercased() == "xcarchive" else {
            return .outsideAllowedRoots
        }
        guard ageDays >= staleThresholdDays else { return .tooRecent(days: ageDays) }
        return nil
    }

    /// 스크린샷에는 **한 달**을 쓴다(다른 종류의 "오래된 기준"과 별개).
    ///
    /// 스크린샷은 원래 한 번 쓰고 버리는 것이다 — 어딘가에 붙여넣으려고 찍고
    /// 그걸로 끝난다. 프로젝트 폴더(몇 달 뒤 다시 열 수 있다)나 설치 파일과
    /// 판단 기준이 다르다. 3개월을 기다리면 쌓인 것이 그냥 계속 쌓여 있고,
    /// 실제로 이 맥의 스크린샷은 둘 다 57·65일이라 하나도 걸리지 않았다.
    ///
    /// 사용자를 놀라게 하지 않으려고 항목 문구에 이 숫자를 그대로 적는다.
    public static let screenshotStaleDays = 30

    private func checkOldScreenshot(path: String, ageDays: Int,
                                    staleThresholdDays: Int) -> ReclaimRefusal? {
        let name = (path as NSString).lastPathComponent
        guard Self.isScreenshotName(name) else { return .outsideAllowedRoots }
        guard ageDays >= Self.screenshotStaleDays else { return .tooRecent(days: ageDays) }
        return nil
    }

    /// 큰 파일은 **사용자가 만든 것**을 찾는 기능이다. `~/Library` 안의 큰 것은
    /// 앱 데이터·캐시라 다른 종류가 이미 다루고, 여기서 보여주면 같은 것이 두 번
    /// 뜨거나 앱 데이터를 사용자 파일로 오인하게 만든다(테스트가 잡아냈다).
    /// 홈 안에서 사람이 만든 **파일 하나**만 후보다.
    ///
    /// 예전에는 위치만 봤다. 스캐너가 파일만 넘기니 사고는 없었지만, 가드는
    /// 스캐너를 믿으면 안 된다 — 이 함수는 홈 자체와 ~/Documents 같은 최상위
    /// 폴더를 통과시키고 있었다(적대적 테스트에서 드러났다). 그런 경로가 한 번만
    /// 들어와도 사용자의 문서 폴더가 통째로 휴지통으로 간다.
    private func checkLargeFile(path: String) -> ReclaimRefusal? {
        if matchesRoot(path, root: "\(home)/Library") { return .protectedLocation }

        let normalized = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        // 홈 자체
        if normalized.caseInsensitiveCompare(home) == .orderedSame { return .protectedLocation }
        // 홈 바로 아래의 표준 폴더들(이름이 같은 사용자 폴더도 함께 막는다)
        let parent = (normalized as NSString).deletingLastPathComponent
        if parent.caseInsensitiveCompare(home) == .orderedSame,
           Self.homeTopLevelFolders.contains(where: {
               (normalized as NSString).lastPathComponent.caseInsensitiveCompare($0) == .orderedSame
           }) {
            return .protectedLocation
        }
        // 실제로 폴더면 거부한다. 큰 "파일"을 지운다고 해놓고 폴더를 통째로
        // 옮기면 사용자가 무엇을 잃는지 알 수 없다.
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: normalized, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return .protectedLocation
        }
        return nil
    }

    /// 홈 바로 아래의 표준 폴더. 통째로 손대면 안 되는 것들이다.
    static let homeTopLevelFolders = [
        "Documents", "Desktop", "Downloads", "Movies", "Music", "Pictures",
        "Library", "Public", "Applications", "Sites", "Developer",
    ]

    private func checkNodeModules(
        path: String,
        lockfilePresent: Bool,
        ageDays: Int,
        staleThresholdDays: Int
    ) -> ReclaimRefusal? {
        if !path.hasSuffix("/node_modules") {
            return .notNodeModules
        }
        if !lockfilePresent {
            return .missingLockfile
        }
        if ageDays <= staleThresholdDays {
            return .tooRecent(days: ageDays)
        }
        return nil
    }

    /// Re-runs the core allowlist/protection checks against a resolved path,
    /// used only to validate that symlink resolution didn't escape the
    /// allowed roots. Does not recheck symlink-ness (the caller already knows
    /// the original path is not a symlink at this point).
    private func isPathSafe(
        _ path: String,
        kind: ReclaimKind,
        lockfilePresent: Bool,
        ageDays: Int,
        staleThresholdDays: Int
    ) -> Bool {
        if protectedOrOutOfBounds(path: path, kind: kind) != nil {
            return false
        }
        if containsGitComponent(path) {
            return false
        }
        if kind == .electronCache {
            return checkElectronCache(path: path) == nil
        }

        if kind == .libraryCache {
            return checkLibraryCache(path: path) == nil
        }

        if kind == .staleInstaller {
            return checkStaleDownload(path: path, ageDays: ageDays,
                                      staleThresholdDays: staleThresholdDays) == nil
        }

        if kind == .oldScreenshot {
            return checkOldScreenshot(path: path, ageDays: ageDays,
                                      staleThresholdDays: staleThresholdDays) == nil
        }

        if kind == .largeFile { return checkLargeFile(path: path) == nil }

        if kind == .xcodeArchive {
            return checkXcodeArchive(path: path, ageDays: ageDays,
                                     staleThresholdDays: staleThresholdDays) == nil
        }

        if kind == .nodeModules {
            return checkNodeModules(path: path, lockfilePresent: lockfilePresent,
                                     ageDays: ageDays, staleThresholdDays: staleThresholdDays) == nil
        }
        let roots = Self.allowedRoots(home: home)[kind] ?? []
        return roots.contains(where: { matchesRoot(path, root: $0) })
    }
}
