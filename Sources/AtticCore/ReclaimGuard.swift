import Foundation

/// `ReclaimGuard`가 후보를 거부한 이유. `check`가 nil을 주면 모든 안전 규칙을
/// 통과했다는 뜻이다.
public enum ReclaimRefusal: Sendable, Equatable {
    case outsideAllowedRoots
    case protectedLocation
    case notNodeModules
    case missingLockfile
    case tooRecent(days: Int)
    case symlink
    case escapesRoot
    case homeItself
    /// 실행 중인 앱·프로세스가 쓰고 있다. 무엇을 꺼야 할지 알 수 있게 이름을 담는다.
    case inUse(by: String)
}

/// 되찾을 수 있는 항목의 종류. 종류마다 허용 루트가 정해져 있고
/// (`ReclaimGuard.allowedRoots`), nodeModules만 락파일·나이·이름 규칙으로 판정한다.
public enum ReclaimKind: String, Sendable, CaseIterable, Codable {
    case buildCache
    case deviceSupport
    case packageCache
    case appCache
    case nodeModules
    /// Chromium 기반 앱이 만드는 웹 캐시. 앱 이름을 미리 알 수 없어 고정 경로가
    /// 아니라 구조로 판정한다.
    case electronCache
    /// 앱이 `~/Library/Caches`나 샌드박스 컨테이너 안에 두는 캐시. 고정 목록으로는
    /// 개발자 도구밖에 못 찾아서 구조로 판정한다.
    case libraryCache
    /// Downloads에서 오래 안 쓴 항목. 사용자 파일이라 되돌릴 수 없으므로 보여주기만
    /// 하고 자동 선택하지 않는다. case 이름이 저장된 스캔 결과의 키라 바꾸지 않는다.
    case staleInstaller
    /// 오래된 스크린샷. 파일명이 스크린샷 형식일 때만 후보다.
    case oldScreenshot
    /// 홈의 큰 파일. 무엇인지 앱이 판단할 수 없으므로 목록으로만 드러낸다.
    case largeFile
    /// Xcode가 배포용으로 만든 보관본(`*.xcarchive`). 캐시가 아니라 결과물이라 다시
    /// 만들려면 그 시점 소스로 빌드해야 하고, 배포한 빌드의 크래시 로그를 해석하는
    /// 데도 쓰인다. 자동 선택에서 빼고 경고를 붙인다.
    case xcodeArchive
}

/// 정리 기능의 유일한 안전 경계. 후보 경로는 스캔할 때와 실행할 때 모두 `check`를
/// 통과해야 `FileManager.trashItem`까지 갈 수 있다. 허용 목록 방식이라 아는 규칙에
/// 맞지 않으면 거부한다.
public struct ReclaimGuard: Sendable {
    public let home: String
    /// 사용자가 설정에서 지정한 보호 경로. 가드가 이걸 받지 않으면 사용자가
    /// 보호했다고 믿는 폴더의 node_modules가 휴지통으로 간다.
    public let extraProtected: [String]

    public init(home: String, extraProtected: [String] = []) {
        // 끝의 슬래시를 떼어 아래 접두사 비교가 특수 경우를 두지 않게 한다.
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

    /// 종류와 무관하게 늘 보호하는 홈 기준 접두사.
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

    /// 종류별 허용 루트. 전부 `home` 아래다.
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
            // ~/.nvm, ~/.rustup, ~/Library/Android/sdk는 일부러 뺐다. 캐시가 아니라
            // 설치본이라 지우면 도구를 다시 설치해야 한다.
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
            // Caches 직속 항목은 .libraryCache가 구조로 잡으므로 여기 남기면 같은
            // 경로가 두 번 뜬다. Logs는 Caches 밖이라 남긴다.
            .appCache: [
                "\(home)/Library/Logs",
            ],
            .nodeModules: [],
            .libraryCache: [],
        ]
    }

    /// `path`가 `kind`의 모든 안전 규칙을 통과하면 nil, 아니면 처음 걸린 거부 사유.
    public func check(
        path: String,
        kind: ReclaimKind,
        lockfilePresent: Bool,
        ageDays: Int,
        isSymlink: Bool,
        resolvedPath: String,
        staleThresholdDays: Int
    ) -> ReclaimRefusal? {
        // 1. 심볼릭 링크는 따라가지 않고 바로 거부한다.
        if isSymlink {
            return .symlink
        }

        // 2. 호출자의 말을 믿지 않는다. `..` 컴포넌트는 우리가 직접 보고 거부한다.
        // 호출자가 준 resolvedPath만 믿으면 해석을 틀리거나 속인 경로가 통과한다.
        if containsDotDotComponent(path) {
            return .escapesRoot
        }

        // 3. 해석된 경로가 달라졌다면 그것도 허용 루트 안이어야 한다. 심볼릭 링크가
        // 아니면서 `../`로 방향이 틀어진 경로를 막는다.
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

        // 경로 어디에든 .git이 있으면 종류를 가리지 않고 거부한다.
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

    /// 경로 컴포넌트 단위로 루트를 비교한다. 단순 `hasPrefix(root)`는 `root + "Backup"`
    /// 같은 남남 폴더까지 맞는 것으로 본다.
    ///
    /// 대소문자를 무시한다. APFS 기본 볼륨은 대소문자를 구분하지 않아 `~/documents/...`가
    /// 실제로 열리므로, 구분해 비교하면 Documents 보호가 뚫린다. resolvingSymlinksInPath도
    /// 대소문자를 정규화하지 않아 실행 직전 재검증에서도 걸리지 않는다.
    private func matchesRoot(_ path: String, root: String) -> Bool {
        if path.compare(root, options: .caseInsensitive) == .orderedSame { return true }
        return path.lowercased().hasPrefix(root.lowercased() + "/")
    }

    private func containsDotDotComponent(_ path: String) -> Bool {
        path.split(separator: "/").contains("..")
    }

    /// 종류마다 보호 폴더 예외가 다르다. 예외를 두는 종류는 확장자·파일명·나이로
    /// 후보를 좁히므로 예외가 사용자 자료로 번지지 않는다.
    private func protectionExemptions(for kind: ReclaimKind) -> [String] {
        switch kind {
        case .staleInstaller: ["Downloads"]
        // 이름 규칙(접두어 + 날짜)이 구체적이라 어디에 있든 스크린샷이다.
        case .oldScreenshot: ["Desktop", "Downloads", "Pictures", "Documents"]
        // 큰 파일은 사용자가 넣어둔 곳에 있어 그 폴더를 보지 않으면 기능이 무력하다.
        // 대신 자동 선택에서 빼고 경로와 경고를 보여줘 하나씩 고르게 한다.
        // Pictures는 사진 라이브러리가 하나의 큰 묶음이라 예외에서 뺀다.
        case .largeFile: ["Documents", "Desktop", "Downloads", "Movies", "Music"]
        default: []
        }
    }

    private func protectedOrOutOfBounds(path: String,
                                        kind: ReclaimKind) -> ReclaimRefusal? {
        if path.compare(home, options: .caseInsensitive) == .orderedSame {
            return .homeItself
        }
        // 시스템 경로 비교도 대소문자를 무시한다. "/system/..."도 같은 파일이다.
        let lower = path.lowercased()
        if path == "/" || lower.hasPrefix("/system") || lower.hasPrefix("/library")
            || lower.hasPrefix("/applications") {
            return .protectedLocation
        }
        if !matchesRoot(path, root: home) {
            // 홈 아래가 전혀 아니고 위에서 본 시스템 루트도 아니다.
            return .protectedLocation
        }
        for prefix in Self.protectedPrefixes {
            if matchesRoot(path, root: "\(home)/\(prefix)") {
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

    /// Electron 캐시의 허용 규칙. 구조로 판정하는 종류라 경계를 좁게 잡는다.
    ///  1. `~/Library/Application Support/` 바로 아래 앱 폴더 안이어야 한다.
    ///  2. 마지막 컴포넌트가 Chromium 캐시 폴더 이름과 정확히 일치해야 한다.
    ///  3. 앱 폴더 아래 깊이가 3을 넘지 않아야 한다.
    ///
    /// 마지막 컴포넌트를 캐시 이름으로 못박은 덕에 앱 데이터 루트(로그인·로컬 DB)는
    /// 구조적으로 후보가 될 수 없다.
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

    /// 일반 앱 캐시의 허용 규칙. 두 자리만 본다.
    ///  - `~/Library/Caches/<앱 한 단계>`
    ///  - `~/Library/Containers/<번들ID>/Data/Library/Caches`
    ///
    /// `com.apple.*`은 시스템이 스스로 관리하므로 제외한다.
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

    /// Downloads 직속 항목이 오래됐으면 후보다. 확장자는 가리지 않는다.
    ///
    /// 직속만 후보인 이유는 하위 폴더를 폴더 하나로 제안해야 사용자가 알아보는
    /// 단위가 되기 때문이다. 폴더는 안에 든 것이 전부 오래됐을 때만 후보이고,
    /// 그 판정은 스캐너가 한다.
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

    /// 스크린샷은 파일명 형식으로 판정한다. "png이고 오래됐다"만으로는 데스크탑에
    /// 섞인 작업 파일까지 지울 수 있다.
    public static func isScreenshotName(_ name: String) -> Bool {
        let prefixes = ["스크린샷 ", "Screenshot ", "Screen Shot ", "スクリーンショット "]
        guard prefixes.contains(where: { name.hasPrefix($0) }) else { return false }
        guard name.lowercased().hasSuffix(".png") || name.lowercased().hasSuffix(".jpg") else {
            return false
        }
        // 날짜가 있어야 한다. "스크린샷.png"처럼 사용자가 바꿔 둔 이름은 제외한다.
        return name.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil
    }

    /// 보관본 하나(`*.xcarchive`)만 후보다. Archives 폴더나 날짜 폴더를 대상으로
    /// 삼으면 여러 빌드가 한꺼번에 사라져 사용자가 무엇을 잃는지 알 수 없다.
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

    /// 스크린샷만 한 달을 쓴다. 한 번 쓰고 버리는 것이라 몇 달 뒤 다시 여는 프로젝트
    /// 폴더나 설치 파일과 기준이 다르다. 항목 문구에도 이 숫자를 그대로 적는다.
    public static let screenshotStaleDays = 30

    private func checkOldScreenshot(path: String, ageDays: Int,
                                    staleThresholdDays: Int) -> ReclaimRefusal? {
        let name = (path as NSString).lastPathComponent
        guard Self.isScreenshotName(name) else { return .outsideAllowedRoots }
        guard ageDays >= Self.screenshotStaleDays else { return .tooRecent(days: ageDays) }
        return nil
    }

    /// 큰 파일은 사용자가 만든 것을 찾는 기능이다. 홈 안의 파일 하나만 후보다.
    ///
    /// `~/Library` 안의 큰 것은 앱 데이터라 다른 종류가 이미 다루고, 여기서 보여주면
    /// 같은 것이 두 번 뜬다. 홈 자체와 최상위 폴더를 따로 막는 이유는 가드가 스캐너를
    /// 믿으면 안 되기 때문이다. 그런 경로가 한 번만 들어와도 문서 폴더가 통째로
    /// 휴지통으로 간다.
    private func checkLargeFile(path: String) -> ReclaimRefusal? {
        if matchesRoot(path, root: "\(home)/Library") { return .protectedLocation }

        let normalized = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        if normalized.caseInsensitiveCompare(home) == .orderedSame { return .protectedLocation }
        // 홈 바로 아래 표준 폴더. 이름이 같은 사용자 폴더도 함께 막힌다.
        let parent = (normalized as NSString).deletingLastPathComponent
        if parent.caseInsensitiveCompare(home) == .orderedSame,
           Self.homeTopLevelFolders.contains(where: {
               (normalized as NSString).lastPathComponent.caseInsensitiveCompare($0) == .orderedSame
           }) {
            return .protectedLocation
        }
        // 큰 파일을 지운다고 해놓고 폴더를 통째로 옮기면 사용자가 무엇을 잃는지
        // 알 수 없다.
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

    /// 해석된 경로에 허용 목록·보호 검사를 다시 돌린다. 링크 해석이 허용 루트를
    /// 벗어나지 않았는지 확인하는 용도라 심볼릭 링크 여부는 다시 보지 않는다.
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
