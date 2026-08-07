import SwiftUI
import AtticCore

/// 공간 탭 — 캐시·오래된 node_modules를 찾아 **선택한 것만 휴지통으로** 옮긴다.
/// "회수"라는 말은 쓰지 않는다("비우다" 어휘만 쓴다). 선택 상태는 이 화면이 직접 들고
/// 있는다(모델은 스캔 결과와 진행 상태만 안다).
struct SpacePane: View {
    /// **L()로 만든 문자열은 locale을 읽지 않는다.** SwiftUI는 환경값을 읽는
    /// 뷰만 다시 그리므로, 이 선언이 없으면 언어를 바꿨을 때 Text("한글 리터럴")은
    /// 바뀌는데 L()로 조립한 설명문은 옛 언어로 남는다(사용자 신고).
    @Environment(\.locale) private var locale

    /// 한 번이라도 훑어봤는지. 모델이 기억한다 — 뷰 로컬 상태로 두면 탭을 옮겼다
    /// 돌아올 때 결과가 있는데도 시작 화면이 뜬다(실측으로 확인).
    let hasScanned: Bool
    /// 지금 디스크 상태. "74GB 비울 수 있어요"는 여유 공간 옆에 있어야 크기 감이 온다.
    let diskSpace: DiskSpace?
    var localSnapshotCount: Int = 0
    let items: [ReclaimItem]
    /// 크기를 재지 못해 목록에서 빠진 것들 — 부분 결과를 완전한 것처럼 보여주지 않는다.
    var unmeasuredNames: [String] = []
    /// 끝까지 훑지 못한 폴더 — 있으면 "비울 게 없어요"가 거짓일 수 있다.
    var incompleteRoots: [String] = []
    /// 목록에서 생략한 자잘한 앱 캐시 — 생략했다는 사실을 숨기지 않는다.
    var smallCaches: (count: Int, bytes: UInt64) = (0, 0)
    let isScanning: Bool
    let scanProgress: ScanProgress?
    let scanStartedAt: Date?
    let spaceScanCompletedAt: Date?
    let spaceResultsFromDisk: Bool
    let isMoving: Bool
    let note: UserNote?
    /// 휴지통 내용. nil이면 읽을 수 없다는 뜻이라 크기를 말하지 않는다.
    var hasFullDiskAccess: Bool = true
    /// 한 번도 찾아본 적이 없나. 이 앱을 처음 보는 사람에게만 무엇을 하는지 말한다.
    var isFirstRun: Bool = false
    var onRecheckAccess: () -> Void = {}
    var trash: TrashContents?
    var isEmptyingTrash: Bool = false
    let onScan: () -> Void
    let onMoveToTrash: ([ReclaimItem]) -> Void
    var onEmptyTrash: () -> Void = {}
    /// 이 탭이 화면에 나타났을 때 호출한다 — 모델이 "확인하지 않은 스캔 결과"
    /// 표시(메뉴바 아이콘)를 지울 수 있게.
    var onAppear: () -> Void = {}

    @State private var selected: Set<String> = []
    /// 되돌릴 수 없는 삭제라 확인을 한 번 받는다. 팝오버에서는 별도 창(alert)이
    /// 초점을 가져가며 팝오버를 닫아버릴 수 있어 같은 자리에서 확인한다.
    @State private var confirmingEmpty = false

    var body: some View {
        // 읽어야 의존성이 생긴다 — L()로 만든 문구가 언어 변경을 따라가게 하는 유일한 고리다.
        let _ = locale
        pane().onAppear(perform: onAppear)
    }

    private static let kindOrder: [ReclaimKind] = [
        .buildCache, .deviceSupport, .packageCache, .appCache, .libraryCache, .electronCache, .nodeModules,
        .staleInstaller, .oldScreenshot, .largeFile,
    ]
    private static let kindTitles: [ReclaimKind: String] = [
        .buildCache: "빌드 캐시",
        .deviceSupport: "기기 지원 파일",
        .packageCache: "패키지 캐시",
        .appCache: "앱 캐시",
        .nodeModules: "안 쓰는 node_modules",
        .electronCache: "앱이 받아둔 웹 캐시",
        .libraryCache: "앱 캐시",
        .staleInstaller: "받아두고 잊은 다운로드",
        .oldScreenshot: "오래된 스크린샷",
        .largeFile: "큰 파일 — 직접 확인하세요",
    ]

    @ViewBuilder
    private func pane() -> some View {
        VStack(alignment: .leading, spacing: 9) {
            if let diskSpace {
                diskGauge(diskSpace)
            }
            if !hasFullDiskAccess { accessBanner }
            if !hasScanned && !isScanning {
                notScannedYet
            } else if isScanning {
                scanningNote
            } else {
                if items.isEmpty {
                    // 결과가 비면 [다시 찾아보기]가 summaryCard와 함께 사라져 탭이
                    // 재스캔 불가 상태로 굳는다(감사에서 확인) — 진입점을 여기 둔다.
                    HStack(spacing: 8) {
                        EmptyNote(symbol: "sparkles", text: "비울 게 없어요. 지금은 깔끔해요")
                        Spacer(minLength: 0)
                        Button("다시 찾아보기", action: onScan)
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                } else {
                    summaryCard
                    resultList
                }
                if !incompleteRoots.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10)).foregroundStyle(Palette.over)
                        Text(L("끝까지 훑지 못한 폴더: %@ — 권한을 확인해주세요",
                               incompleteRoots.joined(separator: ", ")))
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                if smallCaches.count > 0 {
                    Text(L("자잘한 앱 캐시 %lld개(%@)는 목록에서 생략했어요",
                           smallCaches.count, SizeText.compact(smallCaches.bytes)))
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                if !unmeasuredNames.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10)).foregroundStyle(Palette.over)
                        Text(L("크기를 재지 못해 빠짐: %@", unmeasuredNames.joined(separator: ", ")))
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            if let note {
                UserNoteLine(note: note)
            }
        }
    }

    // MARK: - 디스크 게이지

    /// 탭 맨 위에 항상 보이는 한 줄: 지금 얼마나 차 있고 얼마가 남았는지.
    /// 스캔 결과의 "N GB 비울 수 있어요"를 이 옆에서 읽어야 값의 크기가 와닿는다.
    private func diskGauge(_ disk: DiskSpace) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: min(1, disk.usedRatio))
                .tint(disk.usedRatio >= 0.9 ? Palette.over : Palette.apps)
                .controlSize(.small)
            HStack(spacing: 3) {
                Text("여유").font(.system(size: 10.5)).foregroundStyle(.secondary)
                Text(SizeText.compact(disk.free))
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(L("전체 %@", SizeText.compact(disk.total)))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            // "Finder와 df가 다른 여유를 말하는" 영역에 이름을 붙인다. 앱이 지우는
            // 것이 아니라 시스템이 필요할 때 스스로 비우는 공간이다 — 1GB 미만이면
            // 언급할 가치가 없어 숨긴다.
            if disk.purgeable >= 1 << 30 {
                Text(localSnapshotCount > 0
                     ? L("여유 중 %@는 시스템이 필요하면 스스로 비워요 · 로컬 스냅샷 %lld개",
                         SizeText.compact(disk.purgeable), localSnapshotCount)
                     : L("여유 중 %@는 시스템이 필요하면 스스로 비워요",
                         SizeText.compact(disk.purgeable)))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.bottom, 2)
    }

    // MARK: - 스캔 전 / 스캔 중

    private var notScannedYet: some View {
        VStack(spacing: 9) {
            if isFirstRun {
                // 처음 여는 사람이 가장 먼저 알아야 하는 것은 기능이 아니라
                // **이 앱이 무엇을 하지 않는지**다. 낯선 사람에게 디스크를
                // 맡기라고 하는 셈이니, 안전 약속을 첫 줄에 둔다.
                VStack(alignment: .leading, spacing: 6) {
                    Text("쓰지 않는데 자리만 차지하는 파일을 찾아드려요")
                        .font(.system(size: 12, weight: .semibold))
                    introLine("hand.raised", "고른 것만 휴지통으로 옮겨요 — 앱이 알아서 지우지 않아요")
                    introLine("magnifyingglass", "앱이 만든 캐시, 오래된 빌드 파일, 받아두고 잊은 다운로드를 찾아요")
                    introLine("scalemass", "옮기기 직전에 크기를 다시 재서 실제로 얼마가 비는지 알려줘요")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("무엇을 비울 수 있는지 찾아볼까요?")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Button(isFirstRun ? LocalizedStringKey("찾아보기 시작")
                              : LocalizedStringKey("찾아보기"), action: onScan)
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            if isFirstRun {
                Text("한 번 훑는 데 1~2분 걸릴 수 있어요")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, isFirstRun ? 12 : 20)
    }

    private func introLine(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 10)).foregroundStyle(Palette.apps)
                .frame(width: 13)
            Text(text)
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 무한 스피너 대신 정직한 진행을 보여준다: 몇 개 중 몇 개째, 지금 뭘 재는지,
    /// 얼마나 지났는지. `du`가 느려서 60~90초씩 걸릴 수 있으니, 사용자가 멈춘 건지
    /// 궁금해하지 않게 하는 것이 목적이다.
    private var scanningNote: some View {
        let total = scanProgress?.total ?? 0
        let done = scanProgress?.done ?? 0
        let current = scanProgress?.current ?? L("프로젝트 훑는 중")
        return VStack(alignment: .leading, spacing: 6) {
            if total > 0 {
                ProgressView(value: Double(done), total: Double(total))
                    .controlSize(.small)
            } else {
                ProgressView().controlSize(.small)
            }
            HStack(spacing: 3) {
                if total > 0 {
                    Text("\(done)").font(.system(size: 10.5, design: .monospaced))
                    Text("/").font(.system(size: 10.5))
                    Text("\(total)").font(.system(size: 10.5, design: .monospaced))
                    Text("·").font(.system(size: 10.5))
                }
                Text(current).font(.system(size: 10.5))
            }
            .foregroundStyle(.secondary)
            if let scanStartedAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    elapsedText(since: scanStartedAt, now: context.date)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            // 사용자가 직접 누른 스캔은 이제 정상 우선순위로 돈다(ReclaimScanner.lowPriority
            // 참조) — "낮은 우선순위" 안내는 사실이 아니게 되어 뺐다.
            Text("디스크를 훑는 중이라 시간이 걸려요. 다른 일 하셔도 돼요")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    /// "N분/N시간/N일 전에 확인한 결과예요 · 다시 찾아보기". 재시작해도 매번 다시
    /// 훑지 않도록 디스크에서 불러온 결과에만 붙는다 — 결과가 얼마나 오래됐는지
    /// 정직하게 보여주기 위함이다.
    /// 숫자만 고정폭으로 강조하던 중첩 Text 조립을 버리고 한 문장으로 만든다 —
    /// 언어마다 어순이 달라 조각을 이어 붙이면 번역할 수 없다.
    private func ageSubtitle(since date: Date) -> Text {
        let minutes = max(0, Int(Date().timeIntervalSince(date) / 60))
        let age: String
        if minutes < 60 {
            age = L("%lld분", minutes)
        } else if minutes / 60 < 24 {
            age = L("%lld시간", minutes / 60)
        } else {
            age = L("%lld일", minutes / 60 / 24)
        }
        return Text(L("%@ 전에 확인한 결과예요", age))
    }

    private func elapsedText(since start: Date, now: Date) -> Text {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        if seconds < 60 { return Text(L("%lld초 지났어요", seconds)) }
        return Text(L("%lld분 %lld초 지났어요", seconds / 60, seconds % 60))
    }

    // MARK: - 결과 요약

    /// 종류가 캐시인 항목 — 다시 만들어지는 것들만 한꺼번에 고를 수 있다.
    private var safeToSelectAll: [ReclaimItem] {
        items.filter { !Self.userFileKinds.contains($0.kind) }
    }

    /// 되돌릴 수 없는 종류. 자동 선택에서 빼고, 행에 경로를 함께 보여준다.
    static let userFileKinds: Set<ReclaimKind> = [.staleInstaller, .oldScreenshot, .largeFile]

    private var totalBytes: UInt64 {
        items.reduce(UInt64(0)) { $0 + $1.bytes }
    }

    private var selectedBytes: UInt64 {
        items.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.bytes }
    }

    private var summaryCard: some View {
        let selectedItems = items.filter { selected.contains($0.id) }
        return Card(tint: Palette.apps) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(SizeText.compact(totalBytes))
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                Text("비울 수 있어요")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
            }
            // 버튼을 여기 두면 아래 [캐시 모두 선택]과 파란 링크 두 개가 2pt
            // 간격으로 겹쳐 보인다 — 문장만 남기고 버튼은 액션 줄로 내렸다.
            if spaceResultsFromDisk, let spaceScanCompletedAt {
                ageSubtitle(since: spaceScanCompletedAt)
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .padding(.top, 1)
            }
            HStack(spacing: 6) {
                // 삼항의 한쪽만 L()이면 다른 쪽은 String 오버로드로 붙어 번역되지 않는다.
                Text(selectedItems.isEmpty
                     ? L("선택한 것만 휴지통으로 옮겨요")
                     : L("%lld개 선택 · %@", selectedItems.count, SizeText.compact(selectedBytes)))
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                // 33개를 하나씩 누르게 하지 않는다
                // **사용자 파일은 "모두 선택"에서 뺀다.** 캐시는 다시 만들어지지만
                // 설치 파일·스크린샷·큰 파일은 지우면 끝이다 — 한 번의 클릭으로
                // 그것까지 고르게 만들면 안 된다.
                Button(selected.count == safeToSelectAll.count && !safeToSelectAll.isEmpty
                       ? LocalizedStringKey("선택 해제") : LocalizedStringKey("캐시 모두 선택")) {
                    if selected.count == safeToSelectAll.count { selected.removeAll() }
                    else { selected = Set(safeToSelectAll.map(\.id)) }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.apps)
            }
            .padding(.top, 2)
            HStack(spacing: 8) {
                Button("휴지통으로 옮기기") {
                    onMoveToTrash(selectedItems)
                    // 거부된 항목이 선택 상태로 남으면 같은 실패를 반복하게 된다.
                    selected.removeAll()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(selectedItems.isEmpty || isMoving)
                if isMoving {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                }
                // 오래된 결과를 보고 있을 때만. 방금 훑었으면 누를 이유가 없다.
                if spaceResultsFromDisk {
                    Button("다시 찾아보기", action: onScan)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isMoving)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 8)
            trashLine
        }
    }

    /// 캐시를 훑으려면 남의 앱 폴더(Application Support·Containers)를 봐야 하고,
    /// macOS는 그걸 **앱마다 따로** 묻는다 — 앱 6개면 프롬프트 6개다. 전체 디스크
    /// 접근 하나면 전부 사라진다. 설정 안에 숨겨두면 아무도 못 찾으므로 스캔하는
    /// 자리에서 보여준다.
    private var accessBanner: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "lock.open")
                    .font(.system(size: 11)).foregroundStyle(Palette.over)
                Text("접근 허용을 계속 묻는다면")
                    .font(.system(size: 11, weight: .semibold))
            }
            Text("캐시를 찾으려면 다른 앱의 폴더를 봐야 해서, macOS가 앱마다 따로 물어봐요. 전체 디스크 접근을 한 번 허용하면 그 뒤로는 묻지 않아요.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(L("한 번만 허용하기")) {
                    NSWorkspace.shared.open(FullDiskAccess.settingsURL)
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
                Button(L("허용했어요")) { onRecheckAccess() }
                    .buttonStyle(.bordered).controlSize(.small)
                Spacer(minLength: 0)
            }
        }
        .padding(8)
        .background(Palette.over.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
    }

    /// 정리의 마지막 한 걸음. 여기까지 오지 않으면 「여유」는 1바이트도 늘지 않는다.
    @ViewBuilder
    private var trashLine: some View {
        if let trash, trash.isWorthEmptying {
            Divider().padding(.vertical, 2)
            if confirmingEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L("%@를 완전히 지워요 · 되돌릴 수 없어요",
                           SizeText.compact(trash.bytes)))
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Palette.over)
                    HStack(spacing: 8) {
                        Button(L("영구 삭제")) {
                            confirmingEmpty = false
                            onEmptyTrash()
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small).tint(Palette.over)
                        Button(L("취소")) { confirmingEmpty = false }
                            .buttonStyle(.bordered).controlSize(.small)
                        // 지우기 전에 무엇이 들었는지 직접 볼 수 있어야 한다.
                        Button(L("휴지통 열기")) { NSWorkspace.shared.open(Trash().openURL) }
                            .buttonStyle(.borderless).controlSize(.small)
                            .font(.system(size: 10.5))
                        Spacer(minLength: 0)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L("휴지통에 %@ 있어요", SizeText.compact(trash.bytes)))
                            .font(.system(size: 11, weight: .semibold))
                        Text("비우면 그만큼 여유가 늘어나요")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if isEmptyingTrash {
                        ProgressView().controlSize(.small).scaleEffect(0.6)
                    } else {
                        Button(L("휴지통 비우기")) { confirmingEmpty = true }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
        } else if trash == nil {
            // 크기를 읽지 못했다(전체 디스크 접근 없음) — 숫자를 지어내지 않고
            // 갈 곳만 알려준다.
            HStack(spacing: 8) {
                Text("휴지통을 비워야 공간이 실제로 확보돼요")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Palette.over)
                Spacer(minLength: 0)
                Button(L("휴지통 열기")) { NSWorkspace.shared.open(Trash().openURL) }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            .padding(.top, 4)
        }
    }

    // MARK: - 결과 목록

    private var resultList: some View {
        let presentKinds = Self.kindOrder.filter { kind in items.contains { $0.kind == kind } }
        return VStack(alignment: .leading, spacing: 9) {
            ForEach(presentKinds, id: \.self) { kind in
                VStack(alignment: .leading, spacing: 1) {
                    Eyebrow(text: LocalizedStringKey(Self.kindTitles[kind] ?? kind.rawValue))
                    if Self.userFileKinds.contains(kind) {
                        Text("여기서부터는 사용자 파일이에요 — 하나씩 확인하고 고르세요")
                            .font(.system(size: 10)).foregroundStyle(Palette.over)
                            .padding(.horizontal, 7).padding(.bottom, 2)
                    }
                    ForEach(items.filter { $0.kind == kind }) { item in
                        row(for: item)
                    }
                }
            }
        }
    }

    private func row(for item: ReclaimItem) -> some View {
        let isOn = selected.contains(item.id)
        return MetricRow(symbol: symbol(for: item.kind), symbolTint: tint(for: item.kind),
                         title: L(displayName(for: item)), subtitle: subtitle(for: item),
                         value: SizeText.compact(item.bytes),
                         subtitleLines: Self.userFileKinds.contains(item.kind) ? 3 : 2) {
            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15, weight: isOn ? .regular : .medium))
                .foregroundStyle(isOn ? Palette.apps : Palette.muted)
        }
        .contentShape(Rectangle())
        .onTapGesture { toggle(item) }
        // 체크 표시가 이미지뿐이라 VoiceOver로는 상태를 알 수 없다 — 행 전체를
        // 하나의 토글 버튼으로 노출한다.
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(L("%@, %@, %@", L(displayName(for: item)),
                              SizeText.compact(item.bytes),
                              isOn ? L("선택됨") : L("선택 안 됨")))
    }

    private func toggle(_ item: ReclaimItem) {
        if selected.contains(item.id) { selected.remove(item.id) }
        else { selected.insert(item.id) }
    }

    /// 스캐너가 주는 이름은 경로의 마지막 조각이라 "cacache", "caches"처럼
    /// 무엇인지 알 수 없는 것이 섞인다. 알려진 경로는 사람이 아는 이름으로 바꿔 준다.
    private func displayName(for item: ReclaimItem) -> String {
        for (suffix, name) in Self.knownNames where item.path.hasSuffix(suffix) {
            return name
        }
        // 저장된 displayName은 스캔한 순간의 언어로 굳어 있다 — 종류·경로로
        // 다시 만든다(언어를 바꾸면 "Yarn (앱 캐시)"만 한국어로 남았다).
        return ReclaimScanner.displayName(for: item.kind, path: item.path,
                                          fallback: item.displayName)
    }

    private static let knownNames: [(String, String)] = [
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

    private func subtitle(for item: ReclaimItem) -> String {
        // **저장된 item.note를 쓰지 않는다.** 그 문자열은 스캔한 순간의 언어로
        // 굳어 있어서, 언어를 바꿔도 "다음 빌드 때 다시 만들어져요"가 한국어로
        // 남는다(사용자 신고). 종류와 경로만 있으면 언제든 다시 만들 수 있으므로
        // 그릴 때 만든다 — 문구를 고쳐도 옛 결과가 옛말을 하지 않는 효과도 있다.
        let note = ReclaimScanner.note(for: item.kind, path: item.path)
        let sentence = item.lastUsedDays.map {
            L("%@ · %lld일째 그대로", note, Int64($0))
        } ?? note
        // 되돌릴 수 없는 종류에는 **어느 폴더에 있는지**를 함께 보여준다.
        // 파일명만 보이면 같은 이름의 다른 파일을 구별할 수 없다 — 이 맥에서
        // 연말정산 증빙 스크린샷과 그냥 스크린샷이 화면에서 똑같이 보였다.
        guard Self.userFileKinds.contains(item.kind) else { return sentence }
        return PathDisplay.folder(of: item.path) + "\n" + sentence
    }

    private func symbol(for kind: ReclaimKind) -> String {
        switch kind {
        case .buildCache: "hammer.fill"
        case .deviceSupport: "iphone"
        case .packageCache: "shippingbox.fill"
        case .appCache: "app.badge"
        case .nodeModules: "cube.box.fill"
        case .electronCache: "globe"
        case .libraryCache: "shippingbox"
        case .staleInstaller: "arrow.down.circle"
        case .oldScreenshot: "camera"
        case .largeFile: "doc.badge.ellipsis"
        }
    }

    private func tint(for kind: ReclaimKind) -> Color {
        switch kind {
        case .buildCache: Palette.locked
        case .deviceSupport: Palette.locked
        case .packageCache: Palette.apps
        case .appCache: Palette.apps
        case .nodeModules: Palette.over
        case .electronCache: Palette.apps
        case .libraryCache: Palette.apps
        case .staleInstaller: Palette.over
        case .oldScreenshot: Palette.over
        case .largeFile: Palette.alarm
        }
    }

}
