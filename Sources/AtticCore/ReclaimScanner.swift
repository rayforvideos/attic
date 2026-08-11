import Foundation

/// `ReclaimScanner`가 찾은 후보 하나. 이 타입이 되었다는 것은 이미 `ReclaimGuard`를
/// 통과했다는 뜻이다. 검증되지 않은 것은 호출자에게 나가지 않는다.
public struct ReclaimItem: Sendable, Equatable, Identifiable, Codable {
    public var id: String { path }
    public let path: String
    public let kind: ReclaimKind
    public let displayName: String
    public let bytes: UInt64
    public let lastUsedDays: Int?
    public let note: String

    public init(
        path: String,
        kind: ReclaimKind,
        displayName: String,
        bytes: UInt64,
        lastUsedDays: Int?,
        note: String
    ) {
        self.path = path
        self.kind = kind
        self.displayName = displayName
        self.bytes = bytes
        self.lastUsedDays = lastUsedDays
        self.note = note
    }
}

/// 스캔 진행 상황. `total`은 잴 대상 개수가 확정된 뒤에만 정직한 값을 갖고, 그 전에는
/// 0이다. `current`는 경로가 아니라 사람이 읽는 이름이다.
public struct ScanProgress: Sendable, Equatable {
    public let done: Int
    public let total: Int
    public let current: String

    public init(done: Int, total: Int, current: String) {
        self.done = done
        self.total = total
        self.current = current
    }
}

/// `scan()`의 결과. 찾은 항목과 함께 목록에서 빠진 것들도 보고한다. 빠진 것을 숨기면
/// "비울 게 없어요"가 거짓이 된다.
public struct ScanReport: Sendable, Equatable {
    public let items: [ReclaimItem]
    /// 크기를 재지 못해 뺀 항목의 이름.
    public let unmeasuredNames: [String]
    /// 목록에 올리지 않은 자잘한 앱 캐시의 개수와 합계. 수백 개를 다 늘어놓으면
    /// 훑어볼 수 없어 큰 것만 항목으로 내되 생략한 사실은 숨기지 않는다.
    public var smallCachesSkipped: Int = 0
    public var smallCachesBytes: UInt64 = 0
    /// 권한 거부·타임아웃으로 끝까지 훑지 못한 프로젝트 폴더 이름. 비어 있지 않으면
    /// 결과는 부분 결과이고 화면이 완전한 것처럼 말하면 안 된다.
    public var incompleteRoots: [String] = []
    /// 이번에 실제로 재본 (경로, 크기). 다음 스캔에서 다시 재지 않게 호출부가
    /// 저장한다. 캐시에서 재사용한 값은 들어가지 않는다.
    public var measured: [String: UInt64] = [:]
    /// 실행 중인 앱·프로세스가 쓰고 있어 뺀 항목. 누가 쓰는지 말해야 사용자가 끄고
    /// 다시 훑을 수 있다.
    public var skippedInUse: [InUseSkip] = []

    public struct InUseSkip: Sendable, Equatable {
        public let name: String     // 항목의 사람 이름
        public let process: String  // 쓰고 있는 앱·프로세스 이름

        public init(name: String, process: String) {
            self.name = name
            self.process = process
        }
    }

    public init(items: [ReclaimItem], unmeasuredNames: [String],
                incompleteRoots: [String] = [],
                measured: [String: UInt64] = [:],
                smallCachesSkipped: Int = 0, smallCachesBytes: UInt64 = 0,
                skippedInUse: [InUseSkip] = []) {
        self.measured = measured
        self.items = items
        self.unmeasuredNames = unmeasuredNames
        self.incompleteRoots = incompleteRoots
        self.smallCachesSkipped = smallCachesSkipped
        self.smallCachesBytes = smallCachesBytes
        self.skippedInUse = skippedInUse
    }
}

/// 비울 수 있는 캐시 디렉터리와 오래된 `node_modules`를 찾는다. 후보가 만들어지는
/// 유일한 자리이며, `scan()`이 돌려주는 항목은 전부 `ReclaimGuard`를 통과한 것이다.
public struct ReclaimScanner: Sendable {
    private let home: String
    private let projectRoots: [String]
    private let staleThresholdDays: Int

    /// 자식 프로세스를 Darwin 백그라운드로 내리면 CPU는 E 코어에 갇히고 디스크는
    /// 스로틀되므로, 사용자가 눌러 기다리는 스캔에는 쓰지 않는다. 보지 않을 때 도는
    /// 자동 스캔 전용이다.
    public let lowPriority: Bool

    /// 사용자가 설정에서 지정한 보호 경로. 가드에 그대로 넘긴다.
    private let extraProtected: [String]

    /// 목록에 올릴 앱 캐시의 최소 크기. 이보다 작은 것은 골라 지울 가치가 없고 개수만
    /// 늘려 큰 항목을 묻는다. 테스트가 20MB 파일을 만들지 않아도 되게 주입할 수 있다.
    public static let defaultSmallCacheThreshold: UInt64 = 20 << 20   // 20MB
    private let smallCacheThreshold: UInt64
    /// 큰 파일로 볼 최소 크기.
    private let largeFileThreshold: UInt64
    /// 사용자 파일(설치 파일·스크린샷·큰 파일)을 찾을지. 끄면 캐시만 본다.
    private let includeUserFiles: Bool

    /// 지난 스캔에서 재본 크기. 바뀌지 않은 것을 다시 재지 않는다.
    private let sizeCache: SizeCache
    /// 실행 중 판정의 주입 자리. nil이면 스캔 시점의 실제 프로세스 목록을 쓴다.
    private let inUse: ReclaimInUse?

    public init(home: String, projectRoots: [String], staleThresholdDays: Int,
                lowPriority: Bool = false, extraProtected: [String] = [],
                smallCacheThreshold: UInt64 = ReclaimScanner.defaultSmallCacheThreshold,
                largeFileThreshold: UInt64 = ReclaimScanner.defaultLargeFileThreshold,
                includeUserFiles: Bool = true,
                sizeCache: SizeCache = SizeCache(),
                inUse: ReclaimInUse? = nil) {
        self.inUse = inUse
        self.sizeCache = sizeCache
        self.smallCacheThreshold = smallCacheThreshold
        self.largeFileThreshold = largeFileThreshold
        self.includeUserFiles = includeUserFiles
        self.lowPriority = lowPriority
        self.home = home
        self.projectRoots = projectRoots
        self.staleThresholdDays = staleThresholdDays
        self.extraProtected = extraProtected
    }

    /// `onProgress`는 잴 대상이 확정된 뒤에만 `total > 0`을 보고한다. 그 전에는
    /// `total: 0`이다.
    ///
    /// `onItem`은 항목이 확정될 때마다 불린다. 전부 재고 한꺼번에 보여주면 몇 분을
    /// 기다려야 하므로 먼저 끝난 것부터 화면에 올린다.
    public func scan(onProgress: (@Sendable (ScanProgress) -> Void)? = nil,
                     onItem: (@Sendable (ReclaimItem) -> Void)? = nil) async -> ScanReport {
        let guardian = ReclaimGuard(home: home, extraProtected: extraProtected)
        var items: [ReclaimItem] = []
        var unmeasuredNames: [String] = []
        var smallCaches: [ReclaimItem] = []

        onProgress?(ScanProgress(done: 0, total: 0, current: L("프로젝트 훑는 중")))

        let fm = FileManager.default
        var cacheRoots: [(path: String, kind: ReclaimKind)] = []
        for kind in ReclaimKind.allCases where kind != .nodeModules {
            let roots = ReclaimGuard.allowedRoots(home: home)[kind] ?? []
            for root in roots {
                var isDirectory: ObjCBool = false
                if fm.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue {
                    cacheRoots.append((root, kind))
                }
            }
        }

        let electronCaches = findElectronCaches()
        let archives = findXcodeArchives()
        let libraryCaches = findLibraryCaches()

        var nodeModulesPaths: [String] = []
        var incompleteRoots: [String] = []
        for root in projectRoots {
            let found = await findNodeModules(under: root, maxDepth: 4)
            nodeModulesPaths.append(contentsOf: found.paths)
            // 부분 결과를 완전한 것처럼 보여주지 않는 것이 이 스캐너의 계약이다.
            if !found.complete { incompleteRoots.append((root as NSString).lastPathComponent) }
        }
        // 중첩 루트나 중복 입력으로 같은 경로가 두 번 들어오면 합계가 이중 계산된다.
        nodeModulesPaths = Array(Set(nodeModulesPaths)).sorted()

        var done = 0

        // 순차로 재면 큰 항목 하나에서 수십 초 멈춰 진행이 움직이지 않는다. du는 I/O
        // 병목이라 동시 실행 이득이 크지 않지만 작은 항목이 먼저 끝나 진행이 살아
        // 움직인다. 동시 개수를 더 늘려도 디스크만 더 다투고 총 시간은 그대로다.
        let work: [WorkUnit] =
            cacheRoots.map { WorkUnit(path: $0.path, kind: $0.kind,
                                      name: humanName(forCacheRoot: $0.path)) }
            + libraryCaches.map { WorkUnit(path: $0, kind: .libraryCache,
                                           name: humanName(forLibraryCache: $0)) }
            + electronCaches.map { WorkUnit(path: $0, kind: .electronCache,
                                            name: humanName(forElectronCache: $0)) }
            + archives.map { WorkUnit(path: $0, kind: .xcodeArchive,
                                      name: (($0 as NSString).lastPathComponent as NSString)
                                          .deletingPathExtension) }
            + nodeModulesPaths.map { WorkUnit(path: $0, kind: nil,
                                              name: humanName(forNodeModules: $0)) }

        // 가드를 먼저 통과시키고 살아남은 것만 잰다. 거부될 것을 재는 것은 낭비이고,
        // node_modules는 파일 수가 많아 du가 특히 느리다.
        onProgress?(ScanProgress(done: 0, total: 0, current: L("훑는 중")))
        // 지금 쓰이는 중인 것은 옮겨봐야 휴지통에서 "사용 중"으로 되돌아오므로 뺀다.
        // 누가 쓰는지와 함께 보고해야 사용자가 끄고 다시 훑을 수 있다.
        let running = inUse ?? ReclaimInUse(samples: ProcessSampler().sample())
        var skippedInUse: [ScanReport.InUseSkip] = []
        let admitted = work.filter { unit in
            let kind = unit.kind ?? .nodeModules
            let passes = unit.kind.map { passesGuard(unit.path, kind: $0, guardian: guardian) }
                ?? passesNodeModulesGuard(unit.path, guardian: guardian)
            guard passes else { return false }
            // 가드에 어차피 거부될 것까지 "실행 중이라 뺌"으로 보고하지 않는다.
            if let process = running.culprit(path: unit.path, kind: kind, home: home) {
                skippedInUse.append(.init(name: unit.name, process: process))
                return false
            }
            return true
        }

        // 사용자 파일은 크기를 이미 알아 바로 항목이 된다. 같은 파일이 두 종류로
        // 잡히면 목록에 두 줄이 뜨고 합계가 이중 계산되므로 먼저 잡은 종류만 남긴다.
        var claimedPaths = Set<String>()
        for candidate in includeUserFiles ? findUserFiles() : [] {
            guard !claimedPaths.contains(candidate.path) else { continue }
            let resolved = URL(fileURLWithPath: candidate.path)
                .resolvingSymlinksInPath().path
            guard guardian.check(path: candidate.path, kind: candidate.kind,
                                 lockfilePresent: false, ageDays: candidate.ageDays,
                                 isSymlink: isSymlinkPath(candidate.path),
                                 resolvedPath: resolved,
                                 staleThresholdDays: staleThresholdDays) == nil else { continue }
            let floor = candidate.kind == .largeFile
                ? largeFileThreshold : Self.minimumUserFileBytes(candidate.kind)
            guard candidate.bytes >= floor else { continue }
            let item = ReclaimItem(path: candidate.path, kind: candidate.kind,
                                   displayName: (candidate.path as NSString).lastPathComponent,
                                   bytes: candidate.bytes,
                                   lastUsedDays: candidate.ageDays,
                                   note: Self.note(for: candidate.kind, path: candidate.path))
            claimedPaths.insert(candidate.path)
            items.append(item)
            onItem?(item)
        }

        let total = admitted.count
        onProgress?(ScanProgress(done: 0, total: total, current: admitted.first?.name ?? ""))

        // 항목별로 재고 끝나는 즉시 내보낸다. 여러 경로를 묶어 재면 du 호출 수는
        // 줄지만 묶음에 무거운 항목이 하나 섞이면 그 묶음 전체가 늦어져 화면에
        // 아무것도 못 올린다.
        var freshlyMeasured: [String: UInt64] = [:]
        await withTaskGroup(of: (WorkUnit, Evaluation, UInt64?).self) { group in
            var next = 0
            let limit = min(8, admitted.count)

            func submit(_ index: Int) {
                let unit = admitted[index]
                group.addTask { [self] in
                    // 옮기기 직전에 Reclaimer가 다시 재므로 목록의 숫자는 지난 값을
                    // 써도 된다. 캐시는 지금도 자라니 짧게, 오래된 프로젝트는 길게 본다.
                    // (unit.kind == nil이 node_modules다)
                    let reused = sizeCache.reusableBytes(
                        for: unit.path,
                        maxAge: unit.kind == nil ? SizeCache.staleProjectMaxAge
                                                 : SizeCache.volatileCacheMaxAge)
                    let measured: UInt64?
                    if let reused {
                        measured = reused
                    } else {
                        measured = await DirectorySize.measure(unit.path,
                                                              lowPriority: lowPriority)
                    }
                    let evaluation: Evaluation
                    if let kind = unit.kind {
                        evaluation = evaluateCacheRoot(unit.path, kind: kind,
                                                       guardian: guardian, bytes: measured)
                    } else {
                        evaluation = evaluateNodeModules(unit.path, guardian: guardian,
                                                         bytes: measured)
                    }
                    // 재사용한 값은 mtime도 그대로라 다시 저장할 필요가 없다.
                    return (unit, evaluation, reused == nil ? measured : nil)
                }
            }

            while next < limit { submit(next); next += 1 }

            while let (unit, evaluation, fresh) = await group.next() {
                if let fresh { freshlyMeasured[unit.path] = fresh }
                switch evaluation {
                case .item(let item):
                    if item.kind == .electronCache || item.kind == .libraryCache,
                       item.bytes < smallCacheThreshold {
                        smallCaches.append(item)
                    } else {
                        items.append(item)
                        onItem?(item)
                    }
                case .unmeasured: unmeasuredNames.append(unit.name)
                case .skipped: break
                }
                done += 1
                onProgress?(ScanProgress(done: done, total: total,
                                         current: next < admitted.count
                                             ? admitted[next].name : L("마무리 중")))
                if next < admitted.count { submit(next); next += 1 }
            }
        }

        // 동시 실행이라 완료 순서가 뒤섞이므로 종류, 크기 순으로 고정한다.
        items.sort { a, b in
            if a.kind != b.kind {
                return (ReclaimKind.allCases.firstIndex(of: a.kind) ?? 0)
                    < (ReclaimKind.allCases.firstIndex(of: b.kind) ?? 0)
            }
            return a.bytes > b.bytes
        }

        onProgress?(ScanProgress(done: total, total: total, current: L("완료")))
        return ScanReport(items: items, unmeasuredNames: unmeasuredNames.sorted(),
                          incompleteRoots: incompleteRoots,
                          measured: freshlyMeasured,
                          smallCachesSkipped: smallCaches.count,
                          smallCachesBytes: smallCaches.reduce(0) { $0 + $1.bytes },
                          skippedInUse: skippedInUse)
    }


    /// 측정 단위. 클로저 경계를 넘으므로 Sendable 구조체로 둔다.
    private struct WorkUnit: Sendable {
        let path: String
        let kind: ReclaimKind?
        let name: String
    }

    /// 항목의 나이(일). 캐시 루트에는 의미가 없어 0을 쓰지만, 보관본은 오래된 것만
    /// 후보라 실제 나이를 재야 한다. 안 재면 가드가 항상 거부한다.
    private func ageDays(of path: String, kind: ReclaimKind) -> Int {
        guard kind == .xcodeArchive else { return 0 }
        return FileAge.days(ofItemAt: path) ?? 0
    }

    private func passesGuard(_ path: String, kind: ReclaimKind,
                             guardian: ReclaimGuard) -> Bool {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return guardian.check(path: path, kind: kind, lockfilePresent: false,
                              ageDays: ageDays(of: path, kind: kind),
                              isSymlink: isSymlinkPath(path), resolvedPath: resolved,
                              staleThresholdDays: staleThresholdDays) == nil
    }

    private func passesNodeModulesGuard(_ path: String, guardian: ReclaimGuard) -> Bool {
        let projectDir = (path as NSString).deletingLastPathComponent
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return guardian.check(path: path, kind: .nodeModules,
                              lockfilePresent: hasLockfile(inDirectory: projectDir),
                              ageDays: ageInDays(ofPath: projectDir) ?? 0,
                              isSymlink: isSymlinkPath(path), resolvedPath: resolved,
                              staleThresholdDays: staleThresholdDays) == nil
    }

    /// 항목 하나의 평가 결과. 정상 제외(skipped)와 사용자에게 보고해야 할 측정
    /// 실패(unmeasured)를 구분한다.
    private enum Evaluation: Sendable {
        case item(ReclaimItem)
        case skipped
        case unmeasured
    }

    /// 진행 표시용 사람 이름. 크기를 아직 모르는 동안에도 무엇을 재는지는 경로가
    /// 아니라 사람 말로 보여준다.
    private func humanName(forCacheRoot path: String) -> String {
        Self.name(forCacheRoot: path)
    }

    static func name(forCacheRoot path: String) -> String {
        // 표에는 번역 키인 한국어 원문을 두고 꺼낼 때 기기 언어로 옮긴다.
        for (suffix, name) in Self.knownCacheNames where path.hasSuffix(suffix) {
            return L(name)
        }
        return (path as NSString).lastPathComponent
    }

    private func humanName(forNodeModules path: String) -> String {
        let projectDir = (path as NSString).deletingLastPathComponent
        return (projectDir as NSString).lastPathComponent
    }

    private static let knownCacheNames: [(String, String)] = [
        ("/Library/Developer/Xcode/DerivedData", "Xcode 빌드 산출물"),
        ("/Library/Developer/Xcode/iOS DeviceSupport", "iOS 기기 지원 파일"),
        ("/Library/Developer/Xcode/watchOS DeviceSupport", "watchOS 기기 지원 파일"),
        ("/Library/Developer/Xcode/tvOS DeviceSupport", "tvOS 기기 지원 파일"),
        ("/Library/Caches/Homebrew", "Homebrew 캐시"),
        ("/.npm/_cacache", "npm 캐시"),
        ("/Library/Caches/Yarn", "Yarn 캐시"),
        ("/Library/Caches/pnpm", "pnpm 캐시"),
        ("/Library/pnpm", "pnpm 저장소"),
        ("/.gradle/caches", "Gradle 캐시"),
        ("/Library/Caches/CocoaPods", "CocoaPods 캐시"),
        ("/Library/Caches/pip", "pip 캐시"),
        ("/.cache/uv", "uv 캐시"),
        ("/Library/Caches/ms-playwright", "Playwright 브라우저"),
        ("/Library/Caches/ms-playwright-mcp", "Playwright(MCP) 브라우저"),
        ("/.cargo/registry/cache", "Cargo 캐시"),
        ("/Library/Caches/JetBrains", "JetBrains 캐시"),
        ("/Library/Caches/Google", "Chrome 캐시"),
        (".cocoapods", "CocoaPods 저장소"),
        ("/.yarn/berry/cache", "Yarn Berry 캐시"),
        ("/.android/cache", "Android 캐시"),
        ("/.android/build-cache", "Android 빌드 캐시"),
        ("/Library/Logs", "앱 로그"),
    ]

    // MARK: - Cache roots

    private func evaluateCacheRoot(
        _ path: String,
        kind: ReclaimKind,
        guardian: ReclaimGuard,
        bytes measured: UInt64?
    ) -> Evaluation {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .skipped
        }

        let isSymlink = isSymlinkPath(path)
        let resolvedPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path

        let refusal = guardian.check(
            path: path, kind: kind, lockfilePresent: false,
            ageDays: ageDays(of: path, kind: kind),
            isSymlink: isSymlink, resolvedPath: resolvedPath,
            staleThresholdDays: staleThresholdDays
        )
        guard refusal == nil else { return .skipped }

        guard let bytes = measured else { return .unmeasured }
        guard bytes > 0 else { return .skipped }

        return .item(ReclaimItem(
            path: path,
            kind: kind,
            displayName: displayName(for: path, kind: kind),
            bytes: bytes,
            // 보관본은 오래된 것만 후보라 화면이 그 근거를 보여줄 수 있게 담는다.
            lastUsedDays: kind == .xcodeArchive ? ageDays(of: path, kind: kind) : nil,
            note: Self.note(for: kind, path: path)
        ))
    }

    // MARK: - node_modules

    private func evaluateNodeModules(
        _ path: String,
        guardian: ReclaimGuard,
        bytes measured: UInt64?
    ) -> Evaluation {
        let projectDir = (path as NSString).deletingLastPathComponent
        let lockfilePresent = hasLockfile(inDirectory: projectDir)
        // fail-closed. 나이를 못 읽으면 방금 고친 것으로 보아 가드가 거부하게 한다.
        let ageDays = ageInDays(ofPath: projectDir) ?? 0

        let isSymlink = isSymlinkPath(path)
        let resolvedPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path

        let refusal = guardian.check(
            path: path, kind: .nodeModules, lockfilePresent: lockfilePresent,
            ageDays: ageDays, isSymlink: isSymlink, resolvedPath: resolvedPath,
            staleThresholdDays: staleThresholdDays
        )
        guard refusal == nil else { return .skipped }

        guard let bytes = measured else { return .unmeasured }
        guard bytes > 0 else { return .skipped }

        return .item(ReclaimItem(
            path: path,
            kind: .nodeModules,
            displayName: (projectDir as NSString).lastPathComponent,
            bytes: bytes,
            lastUsedDays: ageDays,
            note: Self.note(for: .nodeModules, path: path)
        ))
    }

    private func hasLockfile(inDirectory dir: String) -> Bool {
        let lockfiles = ["package-lock.json", "yarn.lock", "pnpm-lock.yaml"]
        let fm = FileManager.default
        return lockfiles.contains { fm.fileExists(atPath: "\(dir)/\($0)") }
    }

    private func ageInDays(ofPath path: String) -> Int? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date else {
            return nil
        }
        let seconds = Date().timeIntervalSince(mtime)
        return max(0, Int(seconds / 86_400))
    }

    /// 사용자 파일 후보를 찾는다. Downloads에서 오래 안 쓴 것, 오래된 스크린샷,
    /// 홈의 큰 파일이다. 크기를 stat으로 바로 알 수 있어 du를 부르지 않는다.
    ///
    /// 결과는 (경로, 종류, 크기, 나이). 가드가 나이를 보므로 여기서 미리 재서 넘긴다.
    private func findUserFiles() -> [(path: String, kind: ReclaimKind,
                                      bytes: UInt64, ageDays: Int)] {
        let fm = FileManager.default
        var found: [(String, ReclaimKind, UInt64, Int)] = []

        func attributes(_ path: String) -> (bytes: UInt64, ageDays: Int)? {
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  (attrs[.type] as? FileAttributeType) == .typeRegular,
                  let size = attrs[.size] as? UInt64,
                  // 나이는 FileAge 한 곳에서만 잰다. 실행 직전 재검증도 같은 함수를
                  // 써야 스캔과 실행의 답이 어긋나지 않는다.
                  let days = FileAge.daysOfFile(path) else { return nil }
            return (size, days)
        }

        // 1. Downloads 직속에서 오래 안 쓴 것. 파일이든 폴더든 확장자로 가리지 않는다.
        let downloads = "\(home)/Downloads"
        for name in (try? fm.contentsOfDirectory(atPath: downloads)) ?? [] {
            guard !name.hasPrefix(".") else { continue }
            let path = "\(downloads)/\(name)"
            if let info = attributes(path) {
                found.append((path, .staleInstaller, info.bytes, info.ageDays))
            } else if let folder = staleFolderInfo(path) {
                found.append((path, .staleInstaller, folder.bytes, folder.ageDays))
            }
        }

        // 2. 스크린샷 저장 위치는 홈 밖이거나 홈 훑기의 깊이를 넘을 수 있어 따로 본다.
        //    홈 안이면 3번이 또 찾지만 같은 경로는 뒤에서 한 번만 남긴다.
        if let custom = UserDefaults(suiteName: "com.apple.screencapture")?
            .string(forKey: "location") {
            let dir = (custom as NSString).expandingTildeInPath
            for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
                guard ReclaimGuard.isScreenshotName(name) else { continue }
                let path = "\(dir)/\(name)"
                guard let info = attributes(path) else { continue }
                found.append((path, .oldScreenshot, info.bytes, info.ageDays))
            }
        }

        // 3. 홈을 한 번 훑어 큰 파일과 스크린샷을 함께 찾는다. 같은 파일이 두 종류로
        //    잡히면 먼저 잡은 쪽이 이기므로 큰 파일을 뒤에 넣는다.
        let swept = sweepHome()
        found.append(contentsOf: swept.screenshots.map {
            ($0.path, ReclaimKind.oldScreenshot, $0.bytes, $0.ageDays)
        })
        found.append(contentsOf: swept.largeFiles.map {
            ($0.path, ReclaimKind.largeFile, $0.bytes, $0.ageDays)
        })

        return found.map { (path: $0.0, kind: $0.1, bytes: $0.2, ageDays: $0.3) }
    }

    /// Downloads 안의 폴더 하나를 항목으로 낼지 판단한다.
    ///
    /// 안에 든 것이 전부 오래됐을 때만 후보다. 그래서 나이는 가장 최근 파일 기준이다.
    /// 권한 등으로 끝까지 훑지 못했으면 nil이다. 전부 오래됐다는 것을 증명할 수 없는데
    /// 제안하면 안 된다.
    private func staleFolderInfo(_ path: String) -> (bytes: UInt64, ageDays: Int)? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        var total: UInt64 = 0
        let complete = DirectoryWalk.walk(root: path, maxDepth: 6, onFile: { _, bytes, _ in
            total += bytes
        })
        // 나이는 실행 직전 재검증과 같은 함수인 FileAge로 잰다.
        guard complete, total > 0, let days = FileAge.daysOfFolder(path) else { return nil }
        return (total, days)
    }

    /// 종류별 최소 크기. 너무 작은 것은 골라 지울 가치가 없다.
    static func minimumUserFileBytes(_ kind: ReclaimKind) -> UInt64 {
        switch kind {
        case .largeFile: 1
        case .staleInstaller: 1 << 20        // 1MB
        // 수백 KB짜리는 일부러 보관해 둔 기록일 때가 많고, 자리를 실제로 먹는
        // 스크린샷(Retina 전체 화면)은 2~10MB다.
        case .oldScreenshot: 1 << 20         // 1MB
        default: 1
        }
    }

    /// 큰 파일로 볼 최소 크기의 기본값. 실제 값은 UserSettings 한 곳에만 둔다.
    /// 여기와 설정 화면에 각자 적으면 조용히 어긋난다.
    public static var defaultLargeFileThreshold: UInt64 {
        UInt64(UserSettings.defaultLargeFileMB) << 20
    }

    typealias FileHit = (path: String, bytes: UInt64, ageDays: Int)

    /// 배포용 보관본(`*.xcarchive`)을 찾는다. Archives/<날짜>/<이름>.xcarchive
    /// 구조라 깊이 3까지 본다.
    private func findXcodeArchives() -> [String] {
        var found: [String] = []
        DirectoryWalk.walk(root: "\(home)/Library/Developer/Xcode/Archives",
                           maxDepth: 3, onDirectory: { path in
            guard (path as NSString).pathExtension.lowercased() == "xcarchive" else { return false }
            found.append(path)
            return true     // 보관본 안쪽은 더 볼 필요가 없다
        })
        return found
    }

    /// 홈을 한 번만 훑어 큰 파일과 스크린샷을 함께 모은다. 종류마다 따로 훑으면 같은
    /// 디스크를 두 번 읽는다. 여기가 데스크탑·문서·다운로드를 지나가는 자리라 자식
    /// 프로세스로 훑으면 허용이 앱에 기록되지 않아 프롬프트가 매번 다시 뜬다.
    private func sweepHome() -> (largeFiles: [FileHit], screenshots: [FileHit]) {
        var large: [FileHit] = []
        var shots: [FileHit] = []
        let threshold = largeFileThreshold
        let now = Date()
        DirectoryWalk.walk(root: home, maxDepth: 4, pruneNames: ["Library"],
                           onFile: { path, bytes, at in
            let days = max(0, Int(now.timeIntervalSince(at) / 86_400))
            if ReclaimGuard.isScreenshotName((path as NSString).lastPathComponent) {
                shots.append((path, bytes, days))
                return      // 스크린샷은 큰 파일로 또 세지 않는다
            }
            guard bytes >= threshold else { return }
            large.append((path, bytes, days))
        })
        return (large, shots)
    }

    /// `~/Library/Caches` 직속과 샌드박스 컨테이너의 같은 자리를 훑는다. 고정 목록으로는
    /// 개발자 도구만 잡혀 구조로 찾는다.
    private func findLibraryCaches() -> [String] {
        let fm = FileManager.default
        var found: [String] = []

        let caches = "\(home)/Library/Caches"
        for name in (try? fm.contentsOfDirectory(atPath: caches)) ?? [] {
            guard !name.lowercased().hasPrefix("com.apple."), !name.hasPrefix(".") else { continue }
            let path = "\(caches)/\(name)"
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            found.append(path)
        }

        let containers = "\(home)/Library/Containers"
        for bundleID in (try? fm.contentsOfDirectory(atPath: containers)) ?? [] {
            guard !bundleID.lowercased().hasPrefix("com.apple."), !bundleID.hasPrefix(".") else {
                continue
            }
            let path = "\(containers)/\(bundleID)/Data/Library/Caches"
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            found.append(path)
        }
        return found
    }

    /// 종류에 따라 화면 이름을 고른다.
    private func displayName(for path: String, kind: ReclaimKind) -> String {
        switch kind {
        case .electronCache: return humanName(forElectronCache: path)
        case .libraryCache: return humanName(forLibraryCache: path)
        default: return (path as NSString).lastPathComponent
        }
    }

    /// 화면 이름. 번들 ID는 사람이 읽기 어려우니 알려진 이름 표가 있으면 그것을,
    /// 없으면 마지막 조각을 쓴다.
    private func humanName(forLibraryCache path: String) -> String {
        Self.name(forLibraryCache: path, home: home)
    }

    static func name(forLibraryCache path: String, home: String) -> String {
        let containers = "\(home)/Library/Containers/"
        if path.hasPrefix(containers) {
            let bundleID = path.dropFirst(containers.count).split(separator: "/").first.map(String.init) ?? ""
            let readable = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
            return L("%@ (앱 캐시)", readable)
        }
        return name(forCacheRoot: path)
    }

    /// Application Support 아래 Chromium 캐시 폴더를 찾는다. 앱 이름을 미리 알 수 없어
    /// 구조로 찾고, 가드(`checkElectronCache`)와 같은 구조를 보므로 여기서 찾은 것은
    /// 모두 가드를 통과한다.
    private func findElectronCaches() -> [String] {
        let support = "\(home)/Library/Application Support"
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: support, isDirectory: &isDirectory),
              isDirectory.boolValue else { return [] }
        let names = ReclaimGuard.chromiumCacheNames
        let supportDepth = support.split(separator: "/").count

        var found: [String] = []
        DirectoryWalk.walk(root: support, maxDepth: 4, onDirectory: { path in
            guard names.contains((path as NSString).lastPathComponent) else { return false }
            // Application Support 직속은 어느 앱 것인지 특정할 수 없어 대상이 아니다.
            guard path.split(separator: "/").count >= supportDepth + 2 else { return false }
            found.append(path)
            return true     // 캐시 안쪽은 더 볼 필요가 없다
        })
        return found
    }

    /// 화면 이름은 "앱 이름 (캐시 종류)"다. "Cache"만 뜨면 어느 앱 것인지 알 수 없다.
    private func humanName(forElectronCache path: String) -> String {
        Self.name(forElectronCache: path, home: home)
    }

    static func name(forElectronCache path: String, home: String) -> String {
        let support = "\(home)/Library/Application Support/"
        let relative = path.hasPrefix(support) ? String(path.dropFirst(support.count)) : path
        let parts = relative.split(separator: "/").map(String.init)
        guard let app = parts.first, let cache = parts.last else { return relative }
        // 앱 하나에 프로필·파티션이 여러 개면 같은 이름이 여러 줄 뜨므로 중간
        // 컴포넌트로 구별한다.
        let middle = parts.dropFirst().dropLast()
            .filter { $0 != "Partitions" && $0 != "DesktopProfile" }
        let scope = middle.isEmpty ? app : "\(app)/\(middle.joined(separator: "/"))"
        return "\(scope) (\(cache))"
    }

    private func findNodeModules(under root: String,
                                 maxDepth: Int) async -> NodeModulesFinder.Result {
        let lowPriority = self.lowPriority
        return await Task.detached {
            NodeModulesFinder.find(under: root, maxDepth: maxDepth, lowPriority: lowPriority)
        }.value
    }

    private func isSymlinkPath(_ path: String) -> Bool {
        // fail-closed. stat조차 못 하면 심볼릭 링크로 보아 거부한다.
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return true
        }
        return (attrs[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    /// 안내 문구를 고르는 데만 쓴다. 후보 판정에는 쓰지 않는다. 설치 파일은 만든
    /// 곳에서 다시 받을 수 있고 나머지는 그렇지 않다.
    static let installerExtensions: Set<String> = ["dmg", "pkg", "iso", "xip"]

    /// 화면에 쓸 이름은 그릴 때 만든다. 저장된 `displayName`은 스캔한 순간의 언어로
    /// 굳어 있어 언어를 바꿔도 그 부분만 옛 언어로 남는다.
    public static func displayName(for kind: ReclaimKind, path: String,
                                   fallback: String,
                                   home: String = NSHomeDirectory()) -> String {
        switch kind {
        case .libraryCache: name(forLibraryCache: path, home: home)
        case .electronCache: name(forElectronCache: path, home: home)
        case .buildCache, .deviceSupport, .packageCache, .appCache:
            name(forCacheRoot: path)
        // 보관본은 파일명이 곧 빌드 이름이라 확장자만 뗀다.
        case .xcodeArchive: (fallback as NSString).deletingPathExtension
        // node_modules와 사용자 파일은 경로에서 바로 만든 이름이라 번역이 없다.
        case .nodeModules, .staleInstaller, .oldScreenshot, .largeFile: fallback
        }
    }

    public static func note(for kind: ReclaimKind, path: String) -> String {
        // ~/Library/Logs에는 문제가 생겼을 때 보려던 로그가 있을 수 있어 재생성
        // 안내 대신 잃는 것을 경고한다.
        if path.hasSuffix("/Library/Logs") {
            return L("최근 문제를 진단할 로그도 함께 사라져요 — 확인하고 비우세요")
        }
        switch kind {
        case .buildCache:
            return L("다음 빌드 때 다시 만들어져요")
        case .deviceSupport:
            return L("필요할 때 Xcode가 다시 내려받아요")
        case .packageCache:
            return L("패키지를 설치하면 다시 만들어져요")
        case .appCache:
            return L("다음 실행 때 다시 만들어져요")
        case .nodeModules:
            return L("설치 명령을 다시 실행하면 만들어져요")
        case .staleInstaller:
            // "다시 받을 수 있다"는 설치 파일에만 참이다. 받은 사진이나 문서는
            // 대화가 지워지고 링크가 만료되면 되돌릴 수 없다.
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return L("받은 뒤로 안 쓴 폴더예요 · 안에 든 것까지 사라져요")
            }
            if installerExtensions.contains((path as NSString).pathExtension.lowercased()) {
                return L("설치 파일이에요 · 만든 곳에서 다시 받을 수 있어요")
            }
            return L("받은 뒤로 안 쓴 파일이에요 · 지우면 되돌릴 수 없어요")
        case .oldScreenshot:
            return L("찍고 %lld일 넘게 안 본 스크린샷이에요 · 지우면 되돌릴 수 없어요",
                     Int64(ReclaimGuard.screenshotStaleDays))
        case .largeFile:
            return L("무엇인지 확인하고 직접 고르세요 · 지우면 되돌릴 수 없어요")
        case .xcodeArchive:
            // 캐시가 아니라 결과물이라 다시 만들 수 있다고 말하면 안 된다.
            return L("배포용 보관본이에요 · 지우면 그 빌드의 크래시 로그를 해석할 수 없어요")
        case .libraryCache:
            return L("앱이 다시 만들어요 · 다음 실행이 조금 느릴 수 있어요")
        case .electronCache:
            // 로그인이 날아갈까 걱정하는 것이 첫 반응이라 먼저 답한다.
            return L("로그인은 그대로예요 · 앱을 다시 열면 다시 만들어져요")
        }
    }

}
