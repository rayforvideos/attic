import AppKit
import Foundation
import Observation
import AtticCore

@MainActor
@Observable
final class DiagnosticsModel {
    private(set) var isReaping = false
    var notifier = Notifier()

    private(set) var spaceItems: [ReclaimItem] = []
    /// 크기를 재지 못해 목록에서 빠진 항목. 부분 결과임을 화면이 밝히는 데 쓴다.
    private(set) var unmeasuredNames: [String] = []
    /// 끝까지 훑지 못한 프로젝트 폴더. 결과가 부분 결과임을 화면이 밝히는 데 쓴다.
    private(set) var incompleteRoots: [String] = []
    /// 목록에서 생략한 자잘한 앱 캐시(개수, 합계).
    private(set) var smallCaches: (count: Int, bytes: UInt64) = (0, 0)
    /// 실행 중인 앱·프로세스가 쓰고 있어 목록에서 뺀 항목.
    private(set) var skippedInUse: [ScanReport.InUseSkip] = []
    private(set) var isScanningSpace = false
    /// 한 번이라도 훑어봤는지. 뷰 로컬 상태로 두면 탭을 옮겼다 오거나 뷰가 다시
    /// 만들어질 때 결과가 있는데도 시작 화면이 뜬다.
    private(set) var hasScannedSpace = false
    /// 작업 결과 한 줄. 팝오버는 초점만 잃어도 닫히므로 닫을 때 지우면 실패 보고를
    /// 읽기 전에 사라진다. 다시 열 때 오래 묵은 것만 치운다.
    private(set) var spaceNote: UserNote? {
        didSet { spaceNoteAt = spaceNote == nil ? nil : Date() }
    }
    private var spaceNoteAt: Date?
    /// 전체 디스크 접근 여부. 없으면 macOS가 앱마다 따로 접근 허용을 묻는다.
    /// 캐시를 훑으려면 남의 앱 폴더를 봐야 하고, 그 프롬프트를 없애는 길은 이것뿐이다.
    private(set) var hasFullDiskAccess = FullDiskAccess.isGranted
    /// 한 번이라도 찾아본 적이 있나. 첫 실행에만 이 앱이 무엇을 하는지 알려준다.
    private(set) var hasEverScanned =
        UserDefaults.standard.bool(forKey: "hasEverScanned")
    /// 새 버전이 나왔으면 그 정보. 알려주기만 하고 내려받지는 않는다.
    private(set) var availableUpdate: AvailableUpdate?
    /// 업데이트 진행 상태. nil이면 진행 중이 아니다.
    private(set) var updateProgress: String?
    private(set) var updateNote: UserNote?
    /// 휴지통 내용. nil은 "읽을 수 없음"(전체 디스크 접근 없음)이고 0개와 다르다.
    private(set) var trash: TrashContents?
    private(set) var isEmptyingTrash = false
    /// 이번 실행에서 휴지통으로 옮긴 적이 있는지. 옮긴 직후에는 양과 무관하게
    /// 비우기를 권한다. 100MB 문턱만 쓰면 그보다 적게 옮긴 사람은 버튼을 못 본다.
    private(set) var hasMovedToTrash = false
    /// 휴지통으로 옮기는 중. 옮기는 동안 휴지통 비우기와 앱 교체를 막아야 하는데,
    /// 그 판단이 뷰에 흩어져 있으면 다른 경로로 들어올 때 뚫린다.
    private(set) var isMovingToTrash = false
    /// 스캔 진행 상황. 스캔 중이 아니면 nil.
    private(set) var scanProgress: ScanProgress?
    /// 경과 시간 표시를 위한 시작 시각. 스캔 중이 아니면 nil.
    private(set) var scanStartedAt: Date?
    /// 마지막으로 스캔이 끝난 시각. 디스크에서 불러왔든 방금 훑었든 채워진다.
    private(set) var spaceScanCompletedAt: Date?
    /// 디스크에서 불러온 결과를 아직 다시 훑지 않고 보여주고 있는지.
    private(set) var spaceResultsFromDisk = false
    private let spaceStore = SpaceStore(fileURL: DiagnosticsModel.supportDir.appending(path: "space.json"))
    /// 재본 크기를 다음 스캔까지 기억해, 바뀌지 않은 것을 다시 재지 않는다.
    private let sizeCacheURL = DiagnosticsModel.supportDir.appending(path: "sizes.json")
    /// 지금 디스크가 얼마나 차 있는지. 비울 수 있는 양은 여유 공간 옆에 놓아야
    /// 크기 감이 온다.
    private(set) var diskSpace: DiskSpace?
    /// purgeable 공간의 주범인 로컬 스냅샷 개수. 팝오버를 열 때 갱신한다.
    private(set) var localSnapshotCount = 0
    private let diskProbe = DiskSpaceProbe()

    /// 디스크 여유 부족 감시. 스팸 방지 판정은 DiskAlertJudge가 맡는다.
    private var diskAlertJudge: DiskAlertJudge?
    private var diskAlertThresholdBytes: UInt64 = 0

    /// 화면 언어. 값이 바뀌면 이걸 읽는 뷰가 새 로케일로 다시 그려진다.
    /// SwiftUI의 Text(LocalizedStringKey)는 environment의 locale을 보기 때문이다.
    private(set) var languageCode: String?

    func setLanguage(_ language: AppLanguage) {
        languageCode = language == .system ? nil : language.rawValue
        // 이미 만들어 둔 결과 문구는 옛 언어로 굳어 있고 다시 만들 수 없어 치운다.
        spaceNote = nil
    }

    /// 사용자 도메인 상주 에이전트(~/Library/LaunchAgents). 진실 소스는 launchd라
    /// 앱은 상태를 따로 기록하지 않는다.
    private(set) var launchAgents: [LaunchAgent] = []
    /// 로그인 항목을 한 번이라도 읽었는지. 조회 전의 빈 목록을 "없어요"라고
    /// 단정하면 거짓이 된다.
    private(set) var launchAgentsLoaded = false
    /// 부팅·로그인할 때 올라오는 항목 전체(시스템 도메인 포함, 읽기 전용).
    /// 끄고 켜는 것은 사용자 도메인에서만 한다.
    private(set) var startupItems: [StartupItem] = []
    private let launchAgentManager = LaunchAgentManager()

    /// 팝오버가 닫혀 있는 동안 스캔이 끝났고 아직 공간 탭을 보지 않았는지.
    /// 배너를 놓쳤거나 꺼 둔 사용자를 위해 메뉴바 아이콘도 이걸로 강조한다.
    private(set) var spaceResultUnseen = false
    /// 팝오버가 열려 있는지의 근사치. 보고 있는 사람에게 알림과 완료음은 소음이라
    /// 닫혀 있을 때만 울린다.
    private(set) var isPopoverOpen = false

    /// 창은 닫혔는데 아직 돌고 있는 개발 프로세스.
    private(set) var residueGroups: [ResidueGroup] = []

    private var samplingTask: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?
    private var previousCPUTimes: [ProcIdentity: UInt64] = [:]
    private var previousObservedAt: Date?
    /// 마지막으로 프로세스를 훑은 시각. 닫혀 있을 때 주기를 늦추는 데 쓴다.
    private var lastProcessSampleAt: Date?
    /// 마지막 정밀 샘플링 결과. 가벼운 갱신은 이 값을 재사용해 ProcessSampler를
    /// 다시 돌리지 않는다.
    private var lastSamples: [ProcessSample] = []

    /// 메뉴바에 띄울 심볼 이름.
    var menuBarSymbolName: String {
        spaceResultUnseen ? "internaldrive.fill" : "internaldrive"
    }

    /// 앱 전체가 공유하는 인스턴스.
    static let shared = DiagnosticsModel()

    static let supportDir = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Attic")

    init() {
        try? FileManager.default.createDirectory(at: Self.supportDir,
                                                 withIntermediateDirectories: true)

        // 매번 다시 훑지 않게 지난 스캔 결과를 먼저 보여준다. 휴지통 이동은 실행
        // 직전 ReclaimGuard가 재검증하므로 결과가 오래돼도 안전하다.
        if let record = spaceStore.load() {
            spaceItems = record.items
            spaceScanCompletedAt = record.completedAt
            hasScannedSpace = true
            hasEverScanned = true
            spaceResultsFromDisk = true
        }
        diskSpace = diskProbe.snapshot()
        languageCode = AppLanguage.current == .system ? nil : AppLanguage.current.rawValue
    }

    func startSampling(interval: Duration = .seconds(30)) {
        samplingTask?.cancel()
        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: interval, tolerance: .seconds(5))
            }
        }
    }

    /// 팝오버가 닫혀 있을 때 프로세스를 훑는 간격.
    private static let idleSamplingInterval: TimeInterval = 300

    /// 30초마다 도는 한 바퀴. 디스크 확인과 프로세스 훑기를 분리한다.
    ///
    /// 프로세스 훑기는 수백 ms가 걸리고 그 결과는 정리 탭에서만 쓴다. 팝오버가
    /// 닫혀 있는데 30초마다 태우면 이 앱이 잡으려는 배터리 낭비를 스스로 하게 된다.
    /// 디스크 확인은 값싸고 알림이 늦으면 안 되므로 매번 한다.
    private func tick() async {
        await checkDiskThreshold()

        let due = lastProcessSampleAt.map {
            Date().timeIntervalSince($0) >= Self.idleSamplingInterval
        } ?? true
        // 닫혀 있어도 가끔은 훑는다. 열었을 때 비교할 직전 관측이 없으면 CPU를
        // 쓰고 있는지 판정할 수 없다.
        if isPopoverOpen || due {
            await sampleOnce()
        }
    }

    /// 팝오버를 열 때 한 번 도는 갱신. 초 단위로 변하는 값이 없어 스냅샷 하나면 된다.
    func startLiveRefresh() {
        isPopoverOpen = true
        // 결과 한 줄은 닫았다 열어도 남긴다. 며칠 전 결과가 새 소식처럼 보이면
        // 안 되니 오래 묵은 것만 치운다.
        if let spaceNoteAt, Date().timeIntervalSince(spaceNoteAt) > 300 {
            spaceNote = nil
        }
        diskSpace = diskProbe.snapshot()
        let homeForSnapshots = homePath
        Task { [weak self] in
            let count = await Task.detached {
                LocalSnapshots.count(volumePath: homeForSnapshots)
            }.value
            self?.localSnapshotCount = count
        }
        Task { [weak self, launchAgentManager] in
            let agents = await Task.detached { launchAgentManager.list() }.value
            self?.launchAgents = agents
            self?.launchAgentsLoaded = true
        }
        Task { [weak self] in
            let items = await Task.detached { StartupInventory().scan() }.value
            self?.startupItems = items
        }
        // 닫혀 있는 동안 5분에 한 번만 훑으므로 정리 탭이 최대 5분 낡아 있다.
        Task { [weak self] in await self?.sampleOnce() }
        refreshTrash()
        hasFullDiskAccess = FullDiskAccess.isGranted
        checkForUpdate()
    }

    /// 팝오버를 열 때의 확인 간격. 하루로 두면 릴리스 직전에 확인이 돌았을 때
    /// 최대 24시간 새 버전을 모른다.
    private static let updateCheckInterval: TimeInterval = 6 * 3600

    /// 사용자가 직접 누르는 확인. 간격을 무시한다.
    func checkForUpdateNow() { checkForUpdate(force: true) }

    private func checkForUpdate(force: Bool = false) {
        guard (UserDefaults.standard.object(forKey: "updateCheckEnabled") as? Bool) ?? true
        else { return }
        let last = UserDefaults.standard.object(forKey: "updateCheckedAt") as? Date
        if !force, let last, Date().timeIntervalSince(last) < Self.updateCheckInterval,
           availableUpdate == nil { return }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "0"
        Task { [weak self] in
            let found = await UpdateChecker(currentVersion: version).check()
            UserDefaults.standard.set(Date(), forKey: "updateCheckedAt")
            self?.availableUpdate = found
        }
    }

    /// 사용자가 시스템 설정에서 방금 허용했는지 다시 본다.
    func recheckFullDiskAccess() {
        hasFullDiskAccess = FullDiskAccess.isGranted
    }

    /// 휴지통 크기를 다시 읽는다. 열 때·옮긴 뒤·비운 뒤 세 시점 모두 필요하다.
    func refreshTrash() {
        Task { [weak self] in
            let contents = await Trash().inspect()
            self?.trash = contents
        }
    }

    /// 휴지통을 영구 삭제한다. 화면에서 확인을 받은 뒤에만 불러야 한다.
    func emptyTrash() async {
        guard !isEmptyingTrash else { return }
        // 옮기는 중에 비우면 방금 옮긴 것이 확인할 새도 없이 영구 삭제된다.
        guard !isMovingToTrash else {
            spaceNote = .fail(L("옮기는 중이에요 · 끝난 뒤에 비워주세요"))
            return
        }
        isEmptyingTrash = true
        defer { isEmptyingTrash = false }

        let freeBefore = diskProbe.snapshot()?.free
        let outcome = await Trash().empty()
        diskSpace = diskProbe.snapshot()
        refreshTrash()

        guard outcome.removed > 0 else {
            spaceNote = outcome.failed > 0
                ? .fail(L("휴지통을 비우지 못했어요 — 사용 중인 파일이 있어요"))
                : .fail(L("휴지통이 이미 비어 있어요"))
            // 성공 제목으로 실패를 배달하면 제목만 본 사용자가 비워졌다고 믿는다.
            await notifyResultIfClosed(title: outcome.failed > 0
                ? L("휴지통을 비우지 못했어요")
                : L("휴지통이 이미 비어 있어요"))
            return
        }
        // 늘어난 여유를 확인할 수 있을 때만 숫자를 말한다. purgeable 회계 탓에
        // 시스템이 여유를 뒤늦게 반영하는 경우가 있다.
        let gained = (diskSpace?.free).flatMap { after in
            freeBefore.map { before in after > before ? after - before : 0 }
        } ?? 0
        let leftover = outcome.failed > 0
            ? L(" · %lld개는 사용 중이라 남았어요", Int64(outcome.failed)) : ""
        spaceNote = .ok(gained > 0
            ? L("휴지통을 비웠어요 · 여유가 %@ 늘었어요%@",
                SizeText.compact(gained), leftover)
            : L("휴지통을 비웠어요 · %lld개를 지웠어요%@", Int64(outcome.removed), leftover))
        await notifyResultIfClosed(title: L("휴지통 비우기가 끝났어요"))
    }

    /// 작업이 끝났는데 팝오버가 닫혀 있으면 결과 한 줄을 알림으로 배달한다.
    private func notifyResultIfClosed(title: String) async {
        guard !isPopoverOpen, let note = spaceNote else { return }
        await notifier.notify(title: title, body: note.text)
    }

    func stopLiveRefresh() {
        isPopoverOpen = false
        // 결과 한 줄은 여기서 지우지 않는다. 초점만 잃어도 닫히는 팝오버라 닫을 때
        // 지우면 결과를 읽을 기회가 사라진다. 정리는 startLiveRefresh가 맡는다.
        liveTask?.cancel()
        liveTask = nil
    }

    /// 스캔 중 도착한 항목을 목록에 끼워 넣는다. 화면 순서(종류 → 크기)를
    /// 유지해야 항목이 튀어 오르지 않는다.
    private func appendScannedItem(_ item: ReclaimItem) {
        spaceItems.append(item)
        spaceItems.sort { a, b in
            if a.kind != b.kind {
                return (ReclaimKind.allCases.firstIndex(of: a.kind) ?? 0)
                    < (ReclaimKind.allCases.firstIndex(of: b.kind) ?? 0)
            }
            return a.bytes > b.bytes
        }
    }

    /// 공간 탭이 화면에 나타났을 때 호출한다. 확인하지 않은 결과 표시를 지운다.
    func markSpaceResultsSeen() {
        spaceResultUnseen = false
    }

    /// 창 없이 남아 있는 개발 프로세스를 찾는 수집 한 바퀴.
    func sampleOnce() async {
        lastProcessSampleAt = Date()
        let collected = await Self.collect()
        let samples = collected.samples
        lastSamples = samples

        let defaults = UserDefaults.standard
        let context = DetectionContext(
            now: Date(),
            ancestry: collected.ancestry,
            protectedPaths: defaults.stringArray(forKey: "protectedPaths") ?? [],
            previousCPUTimes: previousCPUTimes,
            previousObservedAt: previousObservedAt,
            projectMTime: { path in
                (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            })
        residueGroups = ResidueDetector(context: context).detect(samples)

        previousCPUTimes = Dictionary(uniqueKeysWithValues:
            samples.map { ($0.identity, $0.cpuTimeNanos) })
        previousObservedAt = Date()

    }

    /// 디스크 여유가 임계치 아래로 떨어지면, 결과가 낡았을 때 조용히 다시 훑고
    /// 배너 하나로 알린다.
    private func checkDiskThreshold() async {
        guard let snapshot = diskProbe.snapshot() else { return }
        diskSpace = snapshot

        guard (UserDefaults.standard.object(forKey: "diskAlertEnabled") as? Bool) ?? true else {
            return
        }
        // defaults write로 큰 값이 들어오면 << 가 상위 비트를 버리고 이후 덧셈이
        // 오버플로 트랩을 낸다. 물리적으로 의미 있는 범위로 조인다.
        let thresholdGB = (UserDefaults.standard.object(forKey: "diskAlertThresholdGB") as? Int) ?? 20
        let threshold = UInt64(min(max(1, thresholdGB), 100_000)) << 30
        if diskAlertJudge == nil || diskAlertThresholdBytes != threshold {
            // 마지막 알림 시각을 이월한다. 새로 만들면 임계치를 한 칸 움직일
            // 때마다, 앱을 켤 때마다 즉시 또 알리게 된다.
            let carried = diskAlertJudge?.lastAlertAt
                ?? UserDefaults.standard.object(forKey: "diskAlertLastAt") as? Date
            diskAlertJudge = DiskAlertJudge(
                thresholdBytes: threshold,
                lastAlertAt: carried,
                recoveredSinceLastAlert: diskAlertJudge?.recoveredSinceLastAlert ?? false)
            diskAlertThresholdBytes = threshold
        }
        guard diskAlertJudge?.shouldAlert(freeBytes: snapshot.free, at: Date()) == true else {
            return
        }
        UserDefaults.standard.set(diskAlertJudge?.lastAlertAt, forKey: "diskAlertLastAt")

        // 6시간 넘게 낡은 결과로는 "비울 수 있는 양"을 말할 수 없다.
        let stale = spaceScanCompletedAt.map { Date().timeIntervalSince($0) > 6 * 3600 } ?? true
        let scanningAlready = isScanningSpace

        // 알림을 스캔 뒤로 미루지 않는다. 저우선순위 콜드 스캔은 몇 분이 걸리는데
        // "공간이 부족해요"는 그만큼 늦으면 쓸모가 없고, 이 함수는 샘플링 루프
        // 안에서 불려서 기다리는 동안 프로세스 관찰까지 멈춘다.
        if stale && !scanningAlready {
            Task { [weak self] in await self?.scanSpace(lowPriority: true, quiet: true) }
        }

        // 낡은 숫자를 사실처럼 말하지 않는다. 확인 중이라고 말하고, 결과는
        // 조용한 스캔이 끝날 때 메뉴바 아이콘이 알려준다.
        let body: String
        if stale || scanningAlready {
            body = L("지금 무엇을 비울 수 있는지 확인하는 중이에요")
        } else {
            let reclaimable = spaceItems.reduce(UInt64(0)) { $0 + $1.bytes }
            body = reclaimable > 0
                ? L("%@는 바로 비울 수 있어요", SizeText.compact(reclaimable))
                : L("훑어봤지만 안전하게 비울 만한 게 없었어요")
        }
        await notifier.notify(
            title: L("디스크 여유가 %@ 남았어요", SizeText.compact(snapshot.free)),
            body: body)
    }





    /// 상주 에이전트를 끄거나(bootout+disable) 되돌린다(enable+bootstrap).
    /// 성공 판정은 launchctl 상태 재조회로 한다. rc=0은 증거가 되지 않는다.
    func toggleLaunchAgent(_ agent: LaunchAgent) async -> UserNote {
        let manager = launchAgentManager
        let ok = await Task.detached {
            agent.isDisabled ? manager.enable(agent) : manager.disable(agent)
        }.value
        let agents = await Task.detached { manager.list() }.value
        launchAgents = agents
        let name = agent.programName ?? agent.label
        if agent.isDisabled {
            return ok ? .ok(L("%@ — 다시 켰어요 · 로그인하면 자동 실행돼요", name))
                      : .fail(L("%@ — 켜지 못했어요", name))
        }
        return ok ? .ok(L("%@ — 껐어요 · 다시 로그인해도 실행되지 않아요", name))
                  : .fail(L("%@ — 끄지 못했어요", name))
    }

    /// 창은 닫혔는데 남아 있는 개발 프로세스를 끝낸다. 회수한 메모리는 재지 않는다.
    /// 잡음과 구분하기 어려운 숫자이고, 이 앱을 성능 도구처럼 읽히게 만든다.
    func reap(_ group: ResidueGroup) async -> UserNote {
        guard !isReaping else { return .fail(L("정리가 이미 진행 중이에요")) }
        isReaping = true
        defer { isReaping = false }

        let reaper = ResidueReaper()
        var terminated = 0
        for candidate in group.candidates {
            let result = await reaper.reap(candidate.sample.identity)
            if result == .terminated || result == .killed { terminated += 1 }
        }
        await sampleOnce()
        guard terminated > 0 else {
            return .fail(L("정리하지 못했어요 — 프로세스가 이미 바뀌었을 수 있어요"))
        }
        return .ok(L("%lld개 프로세스 정리됨", Int64(terminated)))
    }

    // MARK: - 공간 탭

    private var homePath: String { FileManager.default.homeDirectoryForCurrentUser.path }

    /// 오래된 것으로 볼 기준(일). 설치 파일·스크린샷·node_modules 모두 이 값을 쓴다.
    static let defaultStaleDays = 90
    var staleDays: Int {
        (UserDefaults.standard.object(forKey: "staleDays") as? Int) ?? Self.defaultStaleDays
    }

    /// 큰 파일로 볼 기준(MB).
    var largeFileMB: Int { UserSettings.largeFileMB }

    /// 사용자 파일(설치 파일·스크린샷·큰 파일)도 찾을지.
    var includeUserFiles: Bool {
        (UserDefaults.standard.object(forKey: "includeUserFiles") as? Bool) ?? true
    }

    /// 설정에서 프로젝트 루트를 비워 뒀을 때 쓰는 기본 후보.
    static let defaultProjectRootNames = ["workspace", "Developer", "src", "Projects"]

    /// 설정의 "보호할 프로젝트 경로". 프로세스 탐지와 공간 정리 가드 양쪽에 같은
    /// 값을 넘긴다. 한쪽만 반영하면 설정이 거짓말을 하게 된다.
    private var protectedPaths: [String] {
        (UserDefaults.standard.stringArray(forKey: "protectedPaths") ?? [])
            .map { ($0 as NSString).expandingTildeInPath }
            .filter { !$0.isEmpty }
    }

    private var reclaimGuard: ReclaimGuard {
        ReclaimGuard(home: homePath, extraProtected: protectedPaths)
    }

    private var projectRoots: [String] {
        let fm = FileManager.default
        let custom = (UserDefaults.standard.stringArray(forKey: "projectRoots") ?? [])
            .map { ($0 as NSString).expandingTildeInPath }
            .filter { !$0.isEmpty }
        let candidates = custom.isEmpty
            ? Self.defaultProjectRootNames.map { "\(homePath)/\($0)" }
            : custom
        // 홈 밖은 거부한다. `/`나 네트워크 마운트를 적으면 스캔이 끝나지 않는다.
        // 중첩·중복 루트도 접어야 같은 항목이 두 줄로 뜨고 합계가 이중 계산되지 않는다.
        let underHome = candidates
            .map { ($0 as NSString).standardizingPath }
            .filter { $0.lowercased() == homePath.lowercased()
                || $0.lowercased().hasPrefix(homePath.lowercased() + "/") }
            .filter { fm.fileExists(atPath: $0) }
        let sorted = Set(underHome).sorted { $0.count < $1.count }
        var kept: [String] = []
        for root in sorted {
            let nested = kept.contains { root.lowercased().hasPrefix($0.lowercased() + "/") }
            if !nested { kept.append(root) }
        }
        return kept
    }

    /// 캐시·오래된 node_modules·사용자 파일을 훑는다. 항목마다 du를 돌려 수십 초가
    /// 걸리므로 샘플링 루프에 넣지 않고, 사용자가 눌렀을 때나 디스크 임계치 감시가
    /// 결과를 갱신할 때만 돈다. lowPriority는 자식 프로세스를 Darwin BG로 내리고,
    /// quiet은 임계치 배너가 대신하므로 완료 배너와 소리를 내지 않는다.
    func scanSpace(lowPriority: Bool = false, quiet: Bool = false) async {
        guard !isScanningSpace else { return }
        isScanningSpace = true
        scanStartedAt = Date()
        defer {
            isScanningSpace = false
            scanProgress = nil
            scanStartedAt = nil
        }

        let home = homePath
        let roots = projectRoots

        // 스캔 중에는 목록을 비우고 도착하는 대로 채운다. 끝까지 기다렸다 한꺼번에
        // 보여주면 몇 분 동안 볼 것이 없다.
        spaceItems = []
        if !hasEverScanned {
            hasEverScanned = true
            UserDefaults.standard.set(true, forKey: "hasEverScanned")
        }
        async let report = ReclaimScanner(home: home, projectRoots: roots,
                                          staleThresholdDays: staleDays,
                                          lowPriority: lowPriority,
                                          extraProtected: protectedPaths,
                                          largeFileThreshold:
                                            UInt64(max(50, largeFileMB)) << 20,
                                          includeUserFiles: includeUserFiles,
                                          sizeCache: loadSizeCache())
            .scan(onProgress: { [weak self] progress in
                Task { @MainActor in self?.scanProgress = progress }
            }, onItem: { [weak self] item in
                Task { @MainActor in self?.appendScannedItem(item) }
            })
        let scanReport = await report
        spaceItems = scanReport.items
        unmeasuredNames = scanReport.unmeasuredNames
        incompleteRoots = scanReport.incompleteRoots
        smallCaches = (scanReport.smallCachesSkipped, scanReport.smallCachesBytes)
        skippedInUse = scanReport.skippedInUse
        diskSpace = diskProbe.snapshot()
        hasScannedSpace = true
        spaceResultsFromDisk = false
        let completedAt = Date()
        spaceScanCompletedAt = completedAt
        spaceStore.save(SpaceScanRecord(items: spaceItems, completedAt: completedAt))
        saveSizeCache(measured: scanReport.measured)

        // 보고 있는 사람에게 완료 알림은 소음이라 닫혀 있을 때만 알린다. 배너가
        // 거부돼 있으면 Notifier가 메뉴바 아이콘 강조로 대신한다.
        guard !isPopoverOpen else { return }
        spaceResultUnseen = true
        guard !quiet else { return }
        let total = spaceItems.reduce(UInt64(0)) { $0 + $1.bytes }
        await notifier.notify(
            title: L("공간 스캔이 끝났어요"),
            body: total > 0 ? L("%@ 비울 수 있어요", SizeText.compact(total))
                            : L("비울 게 없어요 — 깔끔합니다"))
        if (UserDefaults.standard.object(forKey: "spaceScanSound") as? Bool) ?? true {
            NSSound(named: "Glass")?.play()
        }
    }

    private func loadSizeCache() -> SizeCache {
        guard let data = try? Data(contentsOf: sizeCacheURL),
              let cache = try? JSONDecoder().decode(SizeCache.self, from: data)
        else { return SizeCache() }
        return cache
    }

    /// 이번에 실제로 재본 것만 더한다. 재사용한 값은 이미 들어 있다.
    private func saveSizeCache(measured: [String: UInt64]) {
        guard !measured.isEmpty else { return }
        var cache = loadSizeCache()
        for (path, bytes) in measured { cache.record(path: path, bytes: bytes) }
        cache.forgetMissing()
        JSONFileStore.update(at: sizeCacheURL, default: cache) { $0 = cache }
    }

    /// 새 버전을 내려받아 교체하고 다시 시작한다. 서명(팀 ID)·공증·버전을 모두
    /// 확인한 뒤에만 교체하고, 옛 버전은 지우지 않고 휴지통으로 보낸다.
    func installUpdate() async {
        guard let update = availableUpdate, updateProgress == nil else { return }
        // 파일을 옮기거나 지우는 중에 프로세스가 죽으면 사용자는 무엇이 끝났고
        // 무엇이 안 끝났는지 알 수 없다.
        guard !isMovingToTrash, !isEmptyingTrash else {
            updateNote = .fail(L("정리가 끝난 뒤에 업데이트해주세요"))
            return
        }
        guard let dmg = update.downloadURL else {
            // 받을 파일을 모르면 손으로 받을 수 있게 페이지를 열어준다.
            NSWorkspace.shared.open(update.pageURL)
            return
        }
        updateNote = nil
        updateProgress = L("받는 중")
        do {
            _ = try await Updater().install(from: dmg) { [weak self] step in
                Task { @MainActor in self?.updateProgress = L(step) }
            }
            updateProgress = nil
            restartForUpdate()
        } catch {
            updateProgress = nil
            let reason = (error as? Updater.Failure).map(Self.describe) ?? L("받지 못했어요")
            updateNote = .fail(L("업데이트하지 못했어요 — %@", reason))
        }
    }

    static func describe(_ failure: Updater.Failure) -> String {
        switch failure {
        case .downloadFailed: L("받지 못했어요")
        case .mountFailed, .appNotFoundInImage: L("받은 파일을 열 수 없어요")
        case .signatureMismatch(let why), .notNotarized(let why): why
        case .notNewer(let why): why
        case .replaceFailed(let why): why
        }
    }

    /// 새 인스턴스를 띄운 뒤에 자신을 끝낸다.
    private func restartForUpdate() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL,
                                           configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    /// 선택한 항목만 휴지통으로 옮긴다. 옮긴 것만 목록에서 빼고 재스캔은 하지
    /// 않는다. 여기서 전체 스캔이 돌면 화면이 통째로 "훑는 중"으로 바뀐다.
    func moveToTrash(_ items: [ReclaimItem]) async {
        guard !isMovingToTrash else { return }
        // 빈 선택은 실패가 아니다. "옮기지 못했어요"라고 하면 거짓 경고가 된다.
        guard !items.isEmpty else {
            spaceNote = .fail(L("먼저 비울 항목을 골라주세요"))
            return
        }
        isMovingToTrash = true
        defer { isMovingToTrash = false }
        let result = await Reclaimer().moveToTrash(items, guard: reclaimGuard,
                                                    staleThresholdDays: staleDays)
        let skipped = result.refused.count + result.failed.count
        if result.movedCount == 0 {
            let reason = result.refused.first.map { refusalText($0.reason) }
                ?? result.failed.first?.message
            spaceNote = .fail(reason.map { L("옮기지 못했어요 — %@", $0) }
                              ?? L("옮기지 못했어요"))
        } else {
            // 재측정에 실패한 항목이 섞였으면 숫자를 단정하지 않는다.
            let size = result.remeasured
                ? SizeText.compact(result.movedBytes)
                : L("약 %@", SizeText.compact(result.movedBytes))
            let note = skipped > 0
                ? L("%@를 휴지통으로 옮겼어요 · 비우면 공간이 확보돼요 · %lld개는 건너뜀",
                    size, Int64(skipped))
                : L("%@를 휴지통으로 옮겼어요 · 비우면 공간이 확보돼요", size)
            spaceNote = .ok(note)
            hasMovedToTrash = true
        }
        await notifyResultIfClosed(title: L("휴지통으로 옮기기가 끝났어요"))

        // 방금 옮긴 만큼 휴지통이 커졌다. 그 자리에서 비우기를 권할 수 있어야 한다.
        refreshTrash()

        // 이미 없는 경로는 다시 눌러도 같은 실패라 목록에서 뺀다. 문구를 비교하면
        // 번역된 언어에서 매칭이 깨지므로 Reclaimer가 구조로 알려준 목록을 쓴다.
        let goneAnyway = Set(result.alreadyGone)
        let untouched = Set(result.refused.map(\.path)
                            + result.failed.map(\.path)).subtracting(goneAnyway)
        let requested = Set(items.map(\.path)).subtracting(untouched)
        spaceItems.removeAll { requested.contains($0.path) }
        if let completedAt = spaceScanCompletedAt {
            spaceStore.save(SpaceScanRecord(items: spaceItems, completedAt: completedAt))
        }
        diskSpace = diskProbe.snapshot()
    }

    /// Reclaimer가 재검증에서 거른 이유를 사람 말로 옮긴다.
    private func refusalText(_ reason: ReclaimRefusal) -> String {
        switch reason {
        case .outsideAllowedRoots: L("허용된 경로 밖이에요")
        case .inUse(let process): L("%@이(가) 쓰고 있어요 · 끄면 정리할 수 있어요", process)
        case .symlink: L("심볼릭 링크로 바뀌어 있어요")
        case .tooRecent: L("최근에 쓴 프로젝트예요")
        case .missingLockfile: L("잠금 파일이 없는 프로젝트예요")
        case .protectedLocation: L("보호 경로로 지정돼 있어요")
        case .notNodeModules, .escapesRoot, .homeItself: L("안전 검증에서 걸렸어요")
        }
    }





    /// same-uid 샘플과 전 uid 조상 맵이 둘 다 필요하다. 조상 맵을 same-uid 샘플로
    /// 만들면 root 소유 조상에서 끊겨 fail-closed 판정이 오작동한다.
    nonisolated static func collect() async -> (samples: [ProcessSample],
                                                ancestry: [pid_t: AncestorInfo]) {
        let sampler = ProcessSampler()
        return (sampler.sample(), sampler.ancestrySnapshot())
    }
}
