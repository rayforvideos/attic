import Foundation

/// A candidate reclaimable item discovered by `ReclaimScanner`. By the time
/// an item reaches this type it has already passed `ReclaimGuard` — nothing
/// unvalidated is ever surfaced to callers.
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

/// `ReclaimScanner.scan(onProgress:)`가 보고하는 진행 상황. `total`은 실제로 잴
/// 대상 개수가 확정된 뒤에만 정직한 값을 갖는다 — 그 전(node_modules 탐색 중)에는
/// 0으로 둔다. `current`는 지금 재고 있는 것의 사람 이름이지 경로가 아니다.
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

/// `scan()`의 결과. 부분 결과를 완전한 것처럼 보여주지 않기 위해, 찾은 항목과
/// 함께 **크기를 재지 못해 목록에서 빠진 것들의 이름**을 보고한다 — du 실패/타임아웃
/// 항목이 조용히 사라지면 "비울 게 없어요"가 거짓이 된다.
public struct ScanReport: Sendable, Equatable {
    public let items: [ReclaimItem]
    public let unmeasuredNames: [String]
    /// 목록에 올리지 않은 자잘한 앱 캐시의 개수와 합계. 176개를 다 늘어놓으면
    /// 훑어볼 수 없어 큰 것만 항목으로 내지만, 생략했다는 사실은 숨기지 않는다.
    public var smallCachesSkipped: Int = 0
    public var smallCachesBytes: UInt64 = 0
    /// 권한 거부·타임아웃으로 **끝까지 훑지 못한** 프로젝트 폴더 이름. 비어 있지
    /// 않으면 결과는 부분 결과다 — 화면이 완전한 것처럼 말하면 안 된다.
    public var incompleteRoots: [String] = []
    /// 이번에 실제로 재본 (경로, 크기). 다음 스캔에서 다시 재지 않기 위해
    /// 호출부가 저장한다 — 캐시에서 재사용한 값은 여기 들어가지 않는다.
    public var measured: [String: UInt64] = [:]

    public init(items: [ReclaimItem], unmeasuredNames: [String],
                incompleteRoots: [String] = [],
                measured: [String: UInt64] = [:],
                smallCachesSkipped: Int = 0, smallCachesBytes: UInt64 = 0) {
        self.measured = measured
        self.items = items
        self.unmeasuredNames = unmeasuredNames
        self.incompleteRoots = incompleteRoots
        self.smallCachesSkipped = smallCachesSkipped
        self.smallCachesBytes = smallCachesBytes
    }
}

/// Scans the filesystem for reclaimable cache directories and stale
/// `node_modules` trees. Every item returned by `scan()` has already been
/// validated by `ReclaimGuard` — this is the only place scan candidates are
/// produced, and nothing that fails the guard is ever included.
public struct ReclaimScanner: Sendable {
    private let home: String
    private let projectRoots: [String]
    private let staleThresholdDays: Int

    /// 사용자가 직접 눌러 기다리는 스캔은 정상 우선순위로 돌려야 한다. 자식(find·du)을
    /// Darwin 백그라운드로 내리면 CPU는 E 코어에 갇히고 디스크는 3.5배 스로틀되므로,
    /// 보고 있는 사람의 대기 시간만 늘어난다(실측: 진행이 20초 넘게 "훑는 중"에 머물렀다).
    /// 뒤로 미는 것은 사용자가 보지 않을 때 도는 자동 스캔에만 쓴다.
    public let lowPriority: Bool

    /// 사용자가 설정에서 지정한 보호 경로 — 가드에 그대로 넘긴다.
    private let extraProtected: [String]

    /// 목록에 올릴 앱 캐시의 최소 크기. 이보다 작은 것은 골라 지울 가치가 없고,
    /// 개수만 늘려 큰 항목을 묻는다(실측: 176개 중 대부분이 자잘했다).
    /// 테스트가 20MB 파일을 만들지 않아도 되게 주입 가능하게 둔다.
    public static let defaultSmallCacheThreshold: UInt64 = 20 << 20   // 20MB
    private let smallCacheThreshold: UInt64
    /// 큰 파일로 볼 최소 크기.
    private let largeFileThreshold: UInt64
    /// 사용자 파일(설치 파일·스크린샷·큰 파일)을 찾을지. 끄면 캐시만 본다 —
    /// "내 파일은 건드리지 마"라는 사람에게 필요한 스위치다.
    private let includeUserFiles: Bool

    /// 지난 스캔에서 재본 크기. **바뀌지 않은 것을 다시 재지 않는다** — 스캔
    /// 시간의 거의 전부가 측정이고(실측 75초 중 탐색은 0.77초), 우리가 제안하는
    /// node_modules는 90일 넘게 손대지 않은 것이라 변할 일이 없다.
    private let sizeCache: SizeCache
    /// 실행 중 판정의 주입 자리 — nil이면 스캔 시점의 실제 프로세스 목록을 쓴다.
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

    /// `onProgress`는 총량이 정직하게 확정된 뒤에만 `total > 0`을 보고한다: 먼저
    /// (빠른) node_modules 탐색과 캐시 루트 존재 확인을 끝내고, 그 개수를 합쳐
    /// `total`을 확정한 다음에야 항목별 진행을 보고하기 시작한다. 탐색 중에는
    /// `total: 0`, `current: "프로젝트 훑는 중"`으로 보고한다.
    /// `onItem`은 항목이 확정될 때마다 불린다. 전부 재고 나서 한꺼번에 보여주면
    /// 이 맥에서 140초를 기다려야 했다(실측) — 먼저 끝난 것부터 화면에 올려야
    /// 사용자가 무언가를 보고 판단할 수 있다.
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
            // 권한 거부·타임아웃으로 일부만 훑었으면 그 사실을 보고해야 한다 —
            // 부분 결과를 완전한 것처럼 보여주지 않는 것이 이 스캐너의 계약이다.
            if !found.complete { incompleteRoots.append((root as NSString).lastPathComponent) }
        }
        // 중첩 루트나 중복 입력으로 같은 경로가 두 번 들어오면 합계가 이중 계산된다.
        nodeModulesPaths = Array(Set(nodeModulesPaths)).sorted()

        var done = 0

        // 순차로 재면 첫 항목(DerivedData 13GB)에서 20초 넘게 멈춰 진행이 0에서
        // 움직이지 않는다(실측). du는 I/O 병목이라 동시 실행 이득이 크지 않지만
        // (6개 동시 84초 vs 순차 118초), 작은 항목들이 먼저 끝나 **진행이 살아 움직인다**.
        // 동시 개수를 5로 제한한다 — 더 늘리면 디스크만 더 다투고 총 시간은 그대로다.
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

        // **가드를 먼저 통과시키고 살아남은 것만 잰다.** 거부될 것을 재는 것은
        // 낭비이고, node_modules는 파일 수가 많아 du가 압도적으로 느리다
        // (실측: 84개 du 92초 vs 캐시 85개 23초).
        onProgress?(ScanProgress(done: 0, total: 0, current: L("훑는 중")))
        // 실행 중인 앱의 캐시·살아 있는 프로세스가 물고 있는 node_modules는
        // 후보에서 뺀다. 옮겨봐야 휴지통에서 "사용 중"으로 되돌아온다.
        let running = inUse ?? ReclaimInUse(samples: ProcessSampler().sample())
        let admitted = work.filter { unit in
            let kind = unit.kind ?? .nodeModules
            if running.isInUse(path: unit.path, kind: kind, home: home) { return false }
            if let kind = unit.kind {
                return passesGuard(unit.path, kind: kind, guardian: guardian)
            }
            return passesNodeModulesGuard(unit.path, guardian: guardian)
        }

        // 사용자 파일은 크기를 이미 알아 바로 항목이 된다 — 기다릴 이유가 없다.
        // 같은 파일이 두 종류로 잡히면(설치 파일이면서 큰 파일) 목록에 두 줄이
        // 뜨고 합계가 이중 계산된다 — 먼저 잡은 종류만 남긴다(실측으로 확인).
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

        // **항목별로 재고 끝나는 즉시 방출한다.** 여러 경로를 한 번에 묶어 재면
        // du 호출 수는 줄지만, 묶음에 무거운 항목 하나가 섞이면 그 묶음 전체가
        // 늦어져 화면에 아무것도 못 올린다(실측: 6개 묶음에서 20초 뒤에도 0개).
        // 총 시간은 어차피 디스크에 묶여 있으니, 먼저 끝난 것을 바로 보여준다.
        var freshlyMeasured: [String: UInt64] = [:]
        await withTaskGroup(of: (WorkUnit, Evaluation, UInt64?).self) { group in
            var next = 0
            let limit = min(8, admitted.count)

            func submit(_ index: Int) {
                let unit = admitted[index]
                group.addTask { [self] in
                    // 캐시에 쓸 수 있는 값이 있으면 재지 않는다. 지우기 직전에는
                    // 어차피 다시 재므로(Reclaimer), 목록의 숫자는 "언제 확인한
                    // 결과"라는 맥락 안에서 지난 값을 써도 된다.
                    // 캐시는 지금도 자라므로 짧게, 오래된 프로젝트는 길게.
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
                    // 재사용한 값은 다시 저장할 필요가 없다(mtime도 그대로다).
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

        // 화면에 보이는 순서는 종류 → 크기 순으로 고정한다(동시 실행이라 완료 순서가 뒤섞인다)
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
                          smallCachesBytes: smallCaches.reduce(0) { $0 + $1.bytes })
    }


    /// 측정 단위. 클로저 경계를 넘으므로 Sendable 구조체로 둔다.
    private struct WorkUnit: Sendable {
        let path: String
        let kind: ReclaimKind?
        let name: String
    }

    /// 측정 전 가드 통과 여부. `evaluateCacheRoot`와 **같은 근거**를 써야
    /// 한다 — 다르면 여기서 통과한 것이 뒤에서 거부되어 진행 표시가 어긋난다.
    /// 항목의 나이(일). 캐시 루트에는 의미가 없어 0을 쓰지만, 보관본은 **오래된
    /// 것만** 후보라 실제 나이가 필요하다 — 안 재면 가드가 항상 거부한다.
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

    /// 항목 하나의 평가 결과. "가드가 거부/비어 있음"(skipped — 정상 제외)과
    /// "크기 측정 실패"(unmeasured — 사용자에게 보고할 누락)를 구분한다.
    private enum Evaluation: Sendable {
        case item(ReclaimItem)
        case skipped
        case unmeasured
    }

    /// 진행 표시용 사람 이름. `SpacePane`의 결과 목록 라벨과 같은 알려진 이름
    /// 테이블을 (부분적으로) 공유한다 — du가 아직 돌고 있어 바이트를 모르는
    /// 시점에도 "지금 뭘 재는지"는 경로가 아니라 사람 말로 보여줘야 한다.
    private func humanName(forCacheRoot path: String) -> String {
        Self.name(forCacheRoot: path)
    }

    static func name(forCacheRoot path: String) -> String {
        // 표에는 한국어 원문(= 번역 키)을 두고, 꺼낼 때 기기 언어로 옮긴다.
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
            // 캐시는 나이가 판단 근거가 아니지만 보관본은 **오래된 것만** 후보다 —
            // 화면이 그 근거를 보여줄 수 있게 나이를 담는다.
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
        // Fail closed: if we can't determine the project's age, treat it as
        // freshly modified (age 0) so the guard's staleness rule refuses it,
        // rather than treating unreadable metadata as "infinitely old" and
        // letting it through.
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

    /// find가 끝날 때까지 파이프를 동기로 읽는다(수 초). 협력 스레드 풀의
    /// 스레드를 그 시간 동안 잡아두지 않도록 measureBytes처럼 detached로 뺀다.
    /// 사용자 파일 후보를 찾는다: Downloads의 오래된 설치 파일, 오래된 스크린샷,
    /// 홈의 큰 파일. **파일이라 크기를 stat으로 즉시 알 수 있어** du를 부르지
    /// 않는다 — 이 종류는 스캔을 느리게 만들지 않는다.
    ///
    /// 결과는 (경로, 종류, 크기, 나이). 가드는 나이·확장자·파일명을 보므로 여기서
    /// 미리 재서 넘긴다.
    private func findUserFiles() -> [(path: String, kind: ReclaimKind,
                                      bytes: UInt64, ageDays: Int)] {
        let fm = FileManager.default
        var found: [(String, ReclaimKind, UInt64, Int)] = []

        func attributes(_ path: String) -> (bytes: UInt64, ageDays: Int)? {
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  (attrs[.type] as? FileAttributeType) == .typeRegular,
                  let size = attrs[.size] as? UInt64,
                  // 나이는 FileAge 한 곳에서만 잰다 — 실행 직전 재검증도 같은
                  // 함수를 쓴다. 각자 재다가 어긋나서 "오래됐다고 올려놓고
                  // 최근이라 거부하는" 상태가 됐던 적이 있다.
                  let days = FileAge.daysOfFile(path) else { return nil }
            return (size, days)
        }

        // 1. Downloads 직속에서 오래 안 쓴 것 — 파일이든 폴더든.
        //    확장자로 가리지 않는다: 썩는 것의 태반이 설치 파일이 아니다.
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

        // 2. 스크린샷을 설정된 저장 위치에서 찾는다. 그 위치가 홈 밖이거나
        //    홈 훑기의 깊이를 넘을 수 있어 따로 본다 — 홈 안이면 3번이 또 찾지만
        //    같은 경로는 뒤에서 한 번만 남긴다.
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

        // 3. 홈을 한 번 훑어 큰 파일과 스크린샷을 함께 찾는다.
        //    스크린샷을 데스크탑에서만 찾던 것이 문제였다: 실제로는 사람들이
        //    작업 폴더로 끌어다 놓고 잊는다(이 맥의 스크린샷 2개가 모두 데스크탑
        //    밖에 있었다). 이름 규칙(접두어 + 날짜)이 충분히 구체적이라 어디에
        //    있든 스크린샷은 스크린샷이다.
        //    설치 파일·스크린샷이 먼저 잡도록 큰 파일을 **뒤에** 넣는다.
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
    /// **안에 든 것이 전부 오래됐을 때만** 후보다 — 폴더를 지우는 것은 파일
    /// 하나보다 결과가 크므로, 최근에 쓴 파일이 하나라도 섞여 있으면 제안하지
    /// 않는다. 그래서 나이는 **가장 최근** 파일 기준이다.
    ///
    /// 끝까지 훑지 못했으면(권한 등) nil이다: "전부 오래됐다"를 증명할 수 없는데
    /// 제안하면 안 된다.
    private func staleFolderInfo(_ path: String) -> (bytes: UInt64, ageDays: Int)? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        var total: UInt64 = 0
        let complete = DirectoryWalk.walk(root: path, maxDepth: 6, onFile: { _, bytes, _ in
            total += bytes
        })
        // 나이는 FileAge가 잰다(가장 최근 파일 기준) — 실행 직전 재검증과 같은 함수다.
        guard complete, total > 0, let days = FileAge.daysOfFolder(path) else { return nil }
        return (total, days)
    }

    /// 종류별 최소 크기. 1MB 미만 설치 파일은 화면에 "0"으로 뜨고(실측) 골라
    /// 지울 가치도 없다.
    static func minimumUserFileBytes(_ kind: ReclaimKind) -> UInt64 {
        switch kind {
        case .largeFile: 1
        case .staleInstaller: 1 << 20        // 1MB
        // 스크린샷은 1MB부터. 100KB짜리를 목록에 올려봤더니 이 맥에서는 연말정산
        // 증빙으로 폴더에 모아둔 120~210KB 파일 6개가 올라왔다 — 공간은 1MB도
        // 안 되면서, 일부러 보관한 기록을 지우라고 권하는 셈이 된다.
        // 정말 자리를 먹는 스크린샷(Retina 전체 화면)은 2~10MB다.
        case .oldScreenshot: 1 << 20         // 1MB
        default: 1
        }
    }

    /// 큰 파일로 볼 최소 크기의 기본값. 사용자가 설정에서 바꿀 수 있다 —
    /// 무엇을 "크다"고 볼지는 디스크 크기와 쓰는 방식에 따라 다르다.
    /// 값은 UserSettings에만 둔다: 여기와 설정 화면에 각자 적었더니 어긋났다
    /// (화면 최소값 1GB vs 여기 300MB → 코드가 의도한 기준을 고를 수 없었다).
    public static var defaultLargeFileThreshold: UInt64 {
        UInt64(UserSettings.defaultLargeFileMB) << 20
    }

    typealias FileHit = (path: String, bytes: UInt64, ageDays: Int)

    /// 홈을 **한 번만** 훑어 큰 파일과 스크린샷을 함께 모은다. 종류마다 따로
    /// 훑으면 같은 디스크를 두 번 읽는다.
    ///
    /// **앱 안에서 훑는다** — 여기가 데스크탑·문서·다운로드를 지나가는 자리이고,
    /// 자식 프로세스(find)로 훑으면 허용이 우리 앱에 기록되지 않아 스캔할 때마다
    /// 프롬프트가 다시 뜬다(사용자 신고). 가지치기(숨김·Library·깊이 4)는 같다.
    /// 배포용 보관본(`*.xcarchive`)을 찾는다. Archives/<날짜>/<이름>.xcarchive
    /// 구조라 깊이 3까지 본다 — 빌드 하나씩 보여줘야 무엇을 잃는지 알 수 있다.
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

    /// `~/Library/Caches` 직속과 샌드박스 컨테이너의 같은 자리를 훑는다. 고정
    /// 목록으로는 개발자 도구만 잡혀서(실측: 목록 밖 147개) 구조로 찾는다.
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

    /// 화면 이름. 번들 ID(`com.kakao.KakaoTalkMac`)는 사람이 읽기 어려우니 앱
    /// 이름으로 바꾼다 — 알려진 이름 표가 있으면 그것을, 없으면 마지막 조각을 쓴다.
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

    /// Application Support 아래 Chromium 캐시 폴더를 찾는다. 앱 이름을 미리 알 수
    /// 없으니 구조로 찾는다 — 앱 폴더 아래 1~3단계에서 정해진 이름만 고른다.
    /// 가드(`checkElectronCache`)와 같은 구조를 보므로 여기서 찾은 것은 모두
    /// 가드를 통과하고, 반대로 가드가 거부할 것은 애초에 찾지 않는다.
    private func findElectronCaches() -> [String] {
        let support = "\(home)/Library/Application Support"
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: support, isDirectory: &isDirectory),
              isDirectory.boolValue else { return [] }
        let names = ReclaimGuard.chromiumCacheNames
        let supportDepth = support.split(separator: "/").count

        // 앱 안에서 훑는다. find를 자식으로 띄우면 **남의 앱 데이터 접근 동의**가
        // 그 자식에게 귀속되어 우리 앱에 기록되지 않는다 — 스캔할 때마다 같은
        // 프롬프트가 다시 뜨는 원인이다(사용자 신고: 연속 6번).
        var found: [String] = []
        DirectoryWalk.walk(root: support, maxDepth: 4, onDirectory: { path in
            guard names.contains((path as NSString).lastPathComponent) else { return false }
            // Application Support 직속은 어느 앱 것인지 특정할 수 없어 대상이
            // 아니다(가드와 같은 규칙) — 앱 폴더 아래여야 한다.
            guard path.split(separator: "/").count >= supportDepth + 2 else { return false }
            found.append(path)
            return true     // 캐시 안쪽은 더 볼 필요가 없다
        })
        return found
    }

    /// 화면 이름: "앱 이름 (캐시 종류)". 앱 이름 없이 "Cache"만 뜨면 어느 앱
    /// 것인지 알 수 없다.
    private func humanName(forElectronCache path: String) -> String {
        Self.name(forElectronCache: path, home: home)
    }

    static func name(forElectronCache path: String, home: String) -> String {
        let support = "\(home)/Library/Application Support/"
        let relative = path.hasPrefix(support) ? String(path.dropFirst(support.count)) : path
        let parts = relative.split(separator: "/").map(String.init)
        guard let app = parts.first, let cache = parts.last else { return relative }
        // 앱 하나에 프로필·파티션이 여러 개면 같은 이름이 여러 줄 뜬다(실측:
        // Google Service Worker 두 개) — 중간 컴포넌트로 구별한다.
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
        // Fail closed: if we can't stat the path at all, treat it as a
        // symlink (refuse) rather than assuming it's a plain file/directory.
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return true
        }
        return (attrs[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    /// 항목의 안내 문구. **저장된 결과에도 현재 문구가 보이도록** 표시 시점에
    /// 다시 만들 수 있게 static으로 노출한다(문구를 고쳐도 옛 결과가 옛말을 하던 문제).
    /// 문구를 고르는 데만 쓴다 — 후보 판정에는 쓰지 않는다(확장자로 가리지 않는다).
    /// 설치 파일은 만든 곳에서 다시 받을 수 있고, 나머지는 그렇지 않다.
    static let installerExtensions: Set<String> = ["dmg", "pkg", "iso", "xip"]

    /// 화면에 쓸 이름을 **그릴 때** 만든다.
    ///
    /// 저장된 `displayName`을 믿으면 안 된다: 스캔한 순간의 언어로 굳어 있어서
    /// 언어를 바꿔도 "Yarn (앱 캐시)"만 한국어로 남는다(사용자 신고). 종류와
    /// 경로만 있으면 언제든 다시 만들 수 있다.
    public static func displayName(for kind: ReclaimKind, path: String,
                                   fallback: String,
                                   home: String = NSHomeDirectory()) -> String {
        switch kind {
        case .libraryCache: name(forLibraryCache: path, home: home)
        case .electronCache: name(forElectronCache: path, home: home)
        case .buildCache, .deviceSupport, .packageCache, .appCache:
            name(forCacheRoot: path)
        // 보관본은 파일명이 곧 빌드 이름이다 — 확장자는 군더더기라 뗀다.
        case .xcodeArchive: (fallback as NSString).deletingPathExtension
        // node_modules·사용자 파일은 경로에서 바로 만든 이름이라 번역이 없다.
        case .nodeModules, .staleInstaller, .oldScreenshot, .largeFile: fallback
        }
    }

    public static func note(for kind: ReclaimKind, path: String) -> String {
        // ~/Library/Logs는 다른 캐시와 성격이 다르다 — "문제가 생겼을 때 보려던
        // 로그"가 여기 있을 수 있어, 재생성 안내 대신 잃는 것을 경고한다.
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
            // "필요하면 다시 받을 수 있어요"는 **설치 파일에만** 참이다. 이 종류를
            // Downloads 전체로 넓히면서 그 문구를 그대로 뒀었는데, 카톡 사진이나
            // 받은 pptx·동영상은 다시 받을 수 없다(대화가 지워지고 링크가 만료된다).
            // 되돌릴 수 없는 것을 "다시 받을 수 있다"고 말하면 안 된다.
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
            // 캐시가 아니라 결과물이다. 배포한 빌드의 크래시 로그를 해석할 때
            // 쓰이므로, 다시 만들 수 있다고 말하면 안 된다.
            return L("배포용 보관본이에요 · 지우면 그 빌드의 크래시 로그를 해석할 수 없어요")
        case .libraryCache:
            return L("앱이 다시 만들어요 · 다음 실행이 조금 느릴 수 있어요")
        case .electronCache:
            // 로그인이 날아갈까 걱정하는 것이 이 항목의 첫 반응이다 — 먼저 답한다.
            return L("로그인은 그대로예요 · 앱을 다시 열면 다시 만들어져요")
        }
    }

}
