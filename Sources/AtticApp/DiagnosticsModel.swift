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
    /// 이번 스캔에서 크기를 재지 못해 목록에서 빠진 것들의 사람 이름. 부분 결과를
    /// 완전한 것처럼 보여주지 않기 위해 화면에 함께 표시한다. 세션 한정(영속 안 함).
    private(set) var unmeasuredNames: [String] = []
    /// 끝까지 훑지 못한 프로젝트 폴더 — 결과가 부분 결과임을 화면이 말해야 한다.
    private(set) var incompleteRoots: [String] = []
    /// 목록에서 생략한 자잘한 앱 캐시(개수, 합계).
    private(set) var smallCaches: (count: Int, bytes: UInt64) = (0, 0)
    private(set) var isScanningSpace = false
    /// 한 번이라도 훑어봤는지. 뷰가 아니라 모델이 기억해야 한다 — 뷰 로컬 상태로 두면
    /// 탭을 옮겼다 오거나 뷰가 다시 만들어질 때 결과가 있는데도 시작 화면이 뜬다.
    private(set) var hasScannedSpace = false
    private(set) var spaceNote: UserNote?
    /// 휴지통 내용. nil은 "읽을 수 없음"(전체 디스크 접근 없음)이고 0개와 다르다.
    /// 전체 디스크 접근 여부. 없으면 macOS가 **앱마다 따로** "다른 앱의 데이터에
    /// 접근하려고 합니다"를 묻는다(캐시를 훑으려면 남의 앱 폴더를 봐야 한다).
    /// 이 권한 하나면 그 프롬프트가 전부 사라진다 — 유일한 방법이다.
    private(set) var hasFullDiskAccess = FullDiskAccess.isGranted
    /// 한 번이라도 찾아본 적이 있나. 첫 실행에만 이 앱이 무엇을 하는지 알려주고,
    /// 그 뒤로는 방해하지 않는다(재설치해도 결과가 남아 있으면 첫 실행이 아니다).
    private(set) var hasEverScanned =
        UserDefaults.standard.bool(forKey: "hasEverScanned")
    private(set) var trash: TrashContents?
    private(set) var isEmptyingTrash = false
    /// 스캔 도중의 정직한 진행 상황. 무한 스피너 대신 몇 개 중 몇 개째, 지금 뭘 재는지를
    /// 보여주기 위함이다. 스캔 중이 아니면 nil.
    private(set) var scanProgress: ScanProgress?
    /// 경과 시간 표시("N초 지났어요")를 위한 시작 시각. 스캔 중이 아니면 nil.
    private(set) var scanStartedAt: Date?
    /// 마지막으로 스캔이 끝난 시각. `space.json`에서 불러왔든 방금 훑었든 채워진다 —
    /// 결과의 "나이"를 보여주기 위함이다.
    private(set) var spaceScanCompletedAt: Date?
    /// 이번 실행에서 아직 다시 훑지 않고 디스크에서 불러온 결과를 그대로 보여주고
    /// 있는지. true면 화면이 "N 전에 확인한 결과예요 · 다시 찾아보기"를 보여줘야 한다.
    private(set) var spaceResultsFromDisk = false
    private let spaceStore = SpaceStore(fileURL: DiagnosticsModel.supportDir.appending(path: "space.json"))
    /// 재본 크기를 다음 스캔까지 기억한다 — 바뀌지 않은 것을 다시 재지 않는다.
    private let sizeCacheURL = DiagnosticsModel.supportDir.appending(path: "sizes.json")
    /// 지금 디스크가 얼마나 차 있는지. 비울 수 있는 양(74GB 등)만 보여주면 그게
    /// 큰 값인지 감이 오지 않는다 — 여유 공간 옆에 놓아야 비교가 된다.
    private(set) var diskSpace: DiskSpace?
    /// purgeable 공간의 주범(로컬 스냅샷) 개수 — 팝오버를 열 때 갱신.
    private(set) var localSnapshotCount = 0
    private let diskProbe = DiskSpaceProbe()

    /// 디스크 여유 부족 감시. 판정(스팸 방지 규칙)은 DiskAlertJudge가 담당하고,
    /// 여기서는 30초 샘플링 루프에서 값싼 프로브만 물린다.
    private var diskAlertJudge: DiskAlertJudge?
    private var diskAlertThresholdBytes: UInt64 = 0

    /// 사용자 도메인 상주 에이전트(~/Library/LaunchAgents). 팝오버를 열 때 갱신.
    /// 진실 소스는 launchd(print-disabled/print)라 앱은 상태를 따로 기록하지 않는다.
    /// 화면 언어. 값이 바뀌면 이걸 읽는 뷰가 새 로케일로 다시 그려진다 —
    /// SwiftUI의 Text(LocalizedStringKey)는 environment의 locale을 보기 때문이다.
    private(set) var languageCode: String?

    func setLanguage(_ language: AppLanguage) {
        languageCode = language == .system ? nil : language.rawValue
        // 이미 만들어 둔 결과 문구는 옛 언어로 얼어붙어 있다 — 다시 만들 수
        // 없으니 치운다. 그 자리에서 읽는 한 줄이라 사라져도 잃는 것이 없다.
        spaceNote = nil
    }

    private(set) var launchAgents: [LaunchAgent] = []
    /// 부팅·로그인할 때 올라오는 항목 전체(시스템 도메인 포함, 읽기 전용).
    /// 끄고 켜는 것은 여전히 사용자 도메인에서만 한다 — 안전 경계는 그대로다.
    private(set) var startupItems: [StartupItem] = []
    private let launchAgentManager = LaunchAgentManager()

    /// 팝오버가 닫혀 있는 동안 스캔이 끝났고, 아직 공간 탭을 보지 않았는지.
    /// 배너 알림(안정 서명으로 동작)과 별개로, 메뉴바 아이콘도 이걸로 강조해
    /// 배너를 놓쳤거나 꺼 둔 사용자에게 이중 안전망이 된다.
    private(set) var spaceResultUnseen = false
    /// `startLiveRefresh`/`stopLiveRefresh`가 팝오버 표시 여부의 근사치로 쓰인다 —
    /// 팝오버가 열려 있는 동안만 1초 갱신이 돌기 때문이다. 보고 있는 사람에게
    /// 완료음은 불필요하므로, 팝오버가 닫혀 있을 때만 소리를 울린다.
    private(set) var isPopoverOpen = false

    /// 창은 닫혔는데 아직 돌고 있는 개발 프로세스. 이 앱이 찾아내는 "숨은 것" 절반이다.
    private(set) var residueGroups: [ResidueGroup] = []

    private var samplingTask: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?
    private var previousCPUTimes: [ProcIdentity: UInt64] = [:]
    private var previousObservedAt: Date?
    /// 마지막으로 프로세스를 훑은 시각 — 닫혀 있을 때 주기를 늦추는 데 쓴다.
    private var lastProcessSampleAt: Date?
    /// 마지막 30초 정밀 샘플링 결과. 1초 가벼운 갱신은 이 값을 그대로 재사용해서
    /// ProcessSampler(argv·cwd·fd 훑기)를 다시 돌리지 않는다.
    private var lastSamples: [ProcessSample] = []

    /// 메뉴바 라벨은 반드시 순수 Image여야 한다(아래 설명 참고). 그래서 표시할 심볼 이름은
    /// 모델이 계산해 주고, 샘플링 시작은 AppDelegate가 맡는다. 심볼은 디스크다 —
    /// 이 앱이 지켜보는 것이 메모리가 아니라 저장 공간이기 때문이다.
    var menuBarSymbolName: String {
        spaceResultUnseen ? "internaldrive.fill" : "internaldrive"
    }

    /// 앱 전체가 공유하는 인스턴스. AppDelegate가 실행 직후 샘플링을 시작하고,
    /// 화면은 같은 인스턴스를 읽는다.
    static let shared = DiagnosticsModel()

    static let supportDir = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Attic")

    init() {
        try? FileManager.default.createDirectory(at: Self.supportDir,
                                                 withIntermediateDirectories: true)

        // 매번 다시 훑지 않게, 지난 스캔 결과를 그대로 먼저 보여준다. 휴지통 이동은
        // 실행 직전 ReclaimGuard가 재검증하므로 결과가 오래돼도 안전하다.
        if let record = spaceStore.load() {
            // 저장된 항목의 안내 문구를 현재 규칙으로 다시 만든다 — 안 그러면
            // 문구를 고쳐도 지난 스캔 결과가 옛말을 그대로 보여준다.
            spaceItems = record.items.map { item in
                ReclaimItem(path: item.path, kind: item.kind,
                            displayName: item.displayName, bytes: item.bytes,
                            lastUsedDays: item.lastUsedDays,
                            note: ReclaimScanner.note(for: item.kind, path: item.path))
            }
            // 색인 개수는 조회해야 아는 값이라 저장하지 않는다 — 팝오버를 열면
            // 다시 조회한다(0.37초라 기다릴 일이 없다).
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

    /// 프로세스를 훑지 않고 넘어갈 수 있는 최대 간격. 팝오버가 닫혀 있으면
    /// 이만큼에 한 번만 훑는다.
    private static let idleSamplingInterval: TimeInterval = 300

    /// 30초마다 도는 한 바퀴. **디스크 확인과 프로세스 훑기를 분리한다.**
    ///
    /// 프로세스 훑기는 이 맥에서 372ms가 걸리고(프로세스 355개, 실측),
    /// 그 결과는 정리 탭에서만 쓴다 — 알림에는 쓰이지 않는다. 팝오버가 닫혀
    /// 있는데 30초마다 372ms를 태우면, 남의 배터리를 갉아먹는 상주 앱을 찾아주는
    /// 앱이 정작 자기가 그 짓을 하는 셈이다.
    ///
    /// 디스크 확인은 7.7ms라 매번 해도 된다(알림이 늦으면 안 되는 쪽이다).
    private func tick() async {
        await checkDiskThreshold()

        let due = lastProcessSampleAt.map {
            Date().timeIntervalSince($0) >= Self.idleSamplingInterval
        } ?? true
        // 닫혀 있어도 가끔은 훑는다 — 열었을 때 비교할 직전 관측이 없으면
        // "CPU를 안 쓰고 있다"를 판정할 수 없다(5분 간격이 30초보다 오히려
        // 정확한 신호가 된다).
        if isPopoverOpen || due {
            await sampleOnce()
        }
    }

    /// 팝오버를 열 때 한 번 도는 갱신. 1초 루프는 CPU%·부하를 살아 움직이게
    /// 하려던 것이었고, 새 포지션에서는 초 단위로 변하는 값이 없다 — 열 때
    /// 스냅샷 하나면 충분하다.
    func startLiveRefresh() {
        isPopoverOpen = true
        // 팝오버를 열 때마다 한 번이면 충분하다 — 1초 루프에 넣을 만큼 자주 변하지 않는다.
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
        }
        Task { [weak self] in
            let items = await Task.detached { StartupInventory().scan() }.value
            self?.startupItems = items
        }
        // 닫혀 있는 동안에는 5분에 한 번만 훑으므로, 열었을 때 정리 탭이 최대
        // 5분 낡아 있다 — 보러 온 순간에 한 번 새로 훑는다(372ms).
        Task { [weak self] in await self?.sampleOnce() }
        refreshTrash()
        hasFullDiskAccess = FullDiskAccess.isGranted
    }

    /// 사용자가 시스템 설정에서 방금 허용했는지 다시 본다.
    func recheckFullDiskAccess() {
        hasFullDiskAccess = FullDiskAccess.isGranted
    }

    /// 휴지통 크기를 다시 읽는다. 열 때·옮긴 뒤·비운 뒤 세 시점 모두 필요하다 —
    /// 화면에 남은 옛 숫자는 "이미 비웠나?"라는 혼란을 만든다.
    func refreshTrash() {
        Task { [weak self] in
            let contents = await Trash().inspect()
            self?.trash = contents
        }
    }

    /// 휴지통을 영구 삭제한다. **화면에서 확인을 받은 뒤에만** 불러야 한다.
    ///
    /// 비운 뒤 게이지를 다시 읽어 「여유」가 실제로 늘어난 것을 보여주는 것이
    /// 이 기능의 핵심이다 — 숫자가 움직이는 걸 봐야 정리했다는 감각이 생긴다.
    func emptyTrash() async {
        guard !isEmptyingTrash else { return }
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
            return
        }
        // 늘어난 여유를 확인할 수 있을 때만 숫자를 말한다. 시스템이 여유를 뒤늦게
        // 반영하는 경우가 있어(purgeable 회계) 단정하면 거짓말이 된다.
        let gained = (diskSpace?.free).flatMap { after in
            freeBefore.map { before in after > before ? after - before : 0 }
        } ?? 0
        let leftover = outcome.failed > 0
            ? L(" · %lld개는 사용 중이라 남았어요", Int64(outcome.failed)) : ""
        spaceNote = .ok(gained > 0
            ? L("휴지통을 비웠어요 · 여유가 %@ 늘었어요%@",
                SizeText.compact(gained), leftover)
            : L("휴지통을 비웠어요 · %lld개를 지웠어요%@", Int64(outcome.removed), leftover))
    }

    func stopLiveRefresh() {
        isPopoverOpen = false
        // 결과 한 줄은 그 자리에서 읽는 물건이다 — 팝오버를 닫으면 치운다.
        spaceNote = nil
        liveTask?.cancel()
        liveTask = nil
    }

    /// 스캔 중 도착한 항목을 목록에 끼워 넣는다. 화면 순서(종류 → 크기)를 그대로
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

    /// 공간 탭이 화면에 나타났을 때 호출한다 — 확인하지 않은 결과 표시를 지운다.
    func markSpaceResultsSeen() {
        spaceResultUnseen = false
    }

    /// 30초마다 도는 수집. 새 포지션에서 필요한 것은 두 가지뿐이다:
    /// **창 없이 남아 있는 개발 프로세스**를 찾고, **디스크 여유**를 지켜보는 것.
    /// CPU·메모리 진단은 이 앱의 일이 아니게 되어 걷어냈다.
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

    /// 디스크 여유가 임계치 아래로 떨어지면, 스캔 결과가 낡았을 때 저우선순위로
    /// 조용히 다시 훑은 뒤 "여유 N — M 비울 수 있어요" 배너 하나로 알린다.
    /// 사용자가 신경 쓰기 전에 앱이 먼저 아는 것이 목적이다.
    private func checkDiskThreshold() async {
        guard let snapshot = diskProbe.snapshot() else { return }
        diskSpace = snapshot

        guard (UserDefaults.standard.object(forKey: "diskAlertEnabled") as? Bool) ?? true else {
            return
        }
        // defaults write로 큰 값이 들어오면 << 가 상위 비트를 버리고 이후 덧셈이
        // 오버플로 트랩을 낸다 — 물리적으로 의미 있는 범위로 조인다.
        let thresholdGB = (UserDefaults.standard.object(forKey: "diskAlertThresholdGB") as? Int) ?? 20
        let threshold = UInt64(min(max(1, thresholdGB), 100_000)) << 30
        if diskAlertJudge == nil || diskAlertThresholdBytes != threshold {
            // 마지막 알림 시각을 이월한다 — 새로 만들면 임계치를 한 칸 움직일
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

        // **알림을 스캔 뒤로 미루지 않는다.** 예전에는 여기서 전체 스캔을 기다린
        // 뒤에 알렸는데, 콜드 스캔이 160초이고 저우선순위면 더 걸린다(디스크가
        // 3.5배 스로틀된다) — "공간이 부족해요"는 몇 분 늦으면 쓸모가 없다.
        // 게다가 이 함수는 30초 샘플링 루프 안에서 불리므로, 기다리는 동안
        // 프로세스 관찰까지 통째로 멈춰 있었다.
        if stale && !scanningAlready {
            Task { [weak self] in await self?.scanSpace(lowPriority: true, quiet: true) }
        }

        // 낡은 숫자를 사실처럼 말하지 않는다 — 확인 중이라고 말하고, 결과는
        // 메뉴바 아이콘이 알려준다(조용한 스캔이 끝나면 표시가 바뀐다).
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
    /// 성공 판정은 launchctl 상태 재조회 — rc=0을 증거로 쓰지 않는다.
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

    /// 그룹 정리 실행 + 실제 회수량 측정 (설계 §7)
    /// 창은 닫혔는데 남아 있는 개발 프로세스를 끝낸다. 회수량은 재지 않는다 —
    /// 이 앱의 가치는 "숨어 있던 것을 찾아 치웠다"이고, 메모리 숫자를 덧붙이면
    /// 성능 도구처럼 읽힌다(그리고 그 숫자는 잡음과 구분하기 어려웠다).
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
        await sampleOnce()   // 목록 즉시 갱신
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

    /// 큰 파일로 볼 기준(GB). 무엇을 크다고 볼지는 사람마다 다르다.
    var largeFileMB: Int { UserSettings.largeFileMB }

    /// 사용자 파일(설치 파일·스크린샷·큰 파일)도 찾을지.
    var includeUserFiles: Bool {
        (UserDefaults.standard.object(forKey: "includeUserFiles") as? Bool) ?? true
    }

    /// 스캔할 프로젝트 루트. 설정에서 직접 지정할 수 있다 — 기본 목록만 믿으면
    /// ~/code 같은 폴더를 쓰는 사람은 node_modules가 하나도 안 잡히는 이유를
    /// 알 길이 없다(검수에서 확인). 비워 두면 기본 후보를 쓴다.
    static let defaultProjectRootNames = ["workspace", "Developer", "src", "Projects"]

    /// 설정의 "보호할 프로젝트 경로" — 프로세스 탐지와 **공간 정리 가드 양쪽**에
    /// 같은 값을 넘긴다. 한쪽만 반영하면 설정이 거짓말을 하게 된다.
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
        // 홈 밖은 거부한다 — `/`나 네트워크 마운트를 적으면 스캔이 끝나지 않고
        // 남의 파일까지 훑는다. 중첩·중복 루트도 접어야 같은 항목이 두 번 잡히지
        // 않는다(같은 node_modules가 두 줄로 뜨고 합계가 이중 계산된다).
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

    /// 캐시·오래된 node_modules·사용자 파일을 훑는다. 수십 초가
    /// 걸리므로(du를 항목마다 실행) 30초 샘플링 루프에는 넣지 않는다 — 사용자가
    /// [찾아보기]를 눌렀을 때(정상 우선순위), 또는 디스크 임계치 감시가 결과를
    /// 갱신해야 할 때(lowPriority+quiet: 자식 du/find를 Darwin BG로 내리고
    /// 완료 배너·소리를 내지 않는다 — 임계치 배너가 그 자리를 대신한다)만 돈다.
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

        // 스캔 중에는 목록을 비우고 도착하는 대로 채운다 — 140초를 기다린 뒤
        // 한꺼번에 보여주면 그동안 사용자가 볼 것이 없다(실측).
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
        diskSpace = diskProbe.snapshot()
        hasScannedSpace = true
        spaceResultsFromDisk = false
        let completedAt = Date()
        spaceScanCompletedAt = completedAt
        spaceStore.save(SpaceScanRecord(items: spaceItems, completedAt: completedAt))
        saveSizeCache(measured: scanReport.measured)

        // 보고 있는 사람에게 완료 알림은 불필요하다 — 팝오버가 닫혀 있을 때만
        // 배너(Apple Development 서명 빌드에서 동작 확인)와 완료음으로 알린다.
        // 배너가 거부돼 있으면 Notifier가 폴백(메뉴바 아이콘 강조)을 세운다.
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

    /// 이번에 **실제로 재본 것만** 더한다. 재사용한 값은 이미 들어 있다.
    private func saveSizeCache(measured: [String: UInt64]) {
        guard !measured.isEmpty else { return }
        var cache = loadSizeCache()
        for (path, bytes) in measured { cache.record(path: path, bytes: bytes) }
        cache.forgetMissing()
        JSONFileStore.update(at: sizeCacheURL, default: cache) { $0 = cache }
    }

    /// 선택한 항목만 휴지통으로 옮긴다 — 삭제하지 않는다. 결과는 사람 말로 `spaceNote`에.
    /// 재스캔하지 않는다: 옮긴 직후 60~90초짜리 전체 스캔이 돌면 결과 화면이 통째로
    /// "훑는 중"으로 바뀌어 옮기기가 오래 걸리는 것처럼 보인다(검수에서 확인).
    /// 옮겨진 항목만 목록에서 빼고, 나머지는 그대로 둔다.
    func moveToTrash(_ items: [ReclaimItem]) async {
        // 빈 선택은 실패가 아니다 — "옮기지 못했어요"라고 하면 거짓 경고가 된다.
        guard !items.isEmpty else {
            spaceNote = .fail(L("먼저 비울 항목을 골라주세요"))
            return
        }
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
        }

        // 누적 성과에는 **실측된 값만** 넣는다 — 재측정에 실패한 값이 섞이면
        // "지금까지 N GB 비움"이 추정치가 되어 이 앱의 원칙과 어긋난다.
        // 방금 옮긴 만큼 휴지통이 커졌다 — 그 자리에서 "비우기"를 권할 수 있어야 한다.
        refreshTrash()

        // "이미 없는 경로"는 다시 눌러도 같은 실패다 — 목록에서 뺀다. 문구를 비교하면
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

    /// 거부 이유를 사람 말로. 실행기(Reclaimer)가 재검증에서 거른 항목이 왜
    /// 건너뛰어졌는지 최소한 대표 하나는 설명해야 한다.
    private func refusalText(_ reason: ReclaimRefusal) -> String {
        switch reason {
        case .outsideAllowedRoots: L("허용된 경로 밖이에요")
        case .symlink: L("심볼릭 링크로 바뀌어 있어요")
        case .tooRecent: L("최근에 쓴 프로젝트예요")
        case .missingLockfile: L("잠금 파일이 없는 프로젝트예요")
        case .protectedLocation: L("보호 경로로 지정돼 있어요")
        case .notNodeModules, .escapesRoot, .homeItself: L("안전 검증에서 걸렸어요")
        }
    }





    /// 잔여 프로세스 판정에 필요한 것만 뜬다. same-uid 샘플과 **전 uid 조상 맵**이
    /// 둘 다 필요하다 — 조상 맵을 same-uid 샘플로 만들면 root 소유 조상에서 끊겨
    /// fail-closed 판정이 오작동한다(ResidueDetector 주석 참고).
    nonisolated static func collect() async -> (samples: [ProcessSample],
                                                ancestry: [pid_t: AncestorInfo]) {
        let sampler = ProcessSampler()
        return (sampler.sample(), sampler.ancestrySnapshot())
    }
}
