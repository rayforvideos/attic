import SwiftUI
import AppKit
import AtticCore

/// 환경(모델)과 화면을 잇는 얇은 껍데기. 화면 자체는 PopoverBody가 값만 받아 그린다
/// — 그래야 실제 시스템 상태 없이도 디자인을 그대로 띄워 볼 수 있다.
struct PopoverView: View {

    @Environment(DiagnosticsModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var reapNote: UserNote?
    @State private var reaping: Set<String> = []
    @State private var togglingAgents: Set<String> = []

    var body: some View {
        PopoverBody(
            residueGroups: model.residueGroups,
            reapingPaths: reaping,
            reapBlocked: model.isReaping,
            reapNote: reapNote,
            hasScannedSpace: model.hasScannedSpace,
            diskSpace: model.diskSpace,
            localSnapshotCount: model.localSnapshotCount,
            spaceItems: model.spaceItems,
            unmeasuredNames: model.unmeasuredNames,
            incompleteRoots: model.incompleteRoots,
            smallCaches: model.smallCaches,
            skippedInUse: model.skippedInUse,
            isScanningSpace: model.isScanningSpace,
            scanProgress: model.scanProgress,
            scanStartedAt: model.scanStartedAt,
            spaceScanCompletedAt: model.spaceScanCompletedAt,
            spaceResultsFromDisk: model.spaceResultsFromDisk,
            isMovingToTrash: model.isMovingToTrash,
            spaceNote: model.spaceNote,
            notificationsUnavailable: model.notifier.fallbackActive,
            launchAgents: model.launchAgents,
            launchAgentsLoaded: model.launchAgentsLoaded,
            startupItems: model.startupItems,
            togglingAgents: togglingAgents,
            onToggleAgent: { agent in
                reapNote = nil
                togglingAgents.insert(agent.label)
                Task {
                    reapNote = await model.toggleLaunchAgent(agent)
                    togglingAgents.remove(agent.label)
                }
            },
            onReap: { group in
                reapNote = nil
                reaping.insert(group.projectPath)
                Task {
                    reapNote = await model.reap(group)
                    reaping.remove(group.projectPath)
                }
            },
            onScanSpace: { Task { await model.scanSpace() } },
            onMoveToTrash: { items in
                // 진행 상태는 모델이 들고 있다 — 뷰와 모델 두 곳에 두면 다른
                // 경로로 들어올 때 한쪽만 잠긴다.
                Task { await model.moveToTrash(items) }
            },
            onSpaceTabAppear: { model.markSpaceResultsSeen() },
            hasFullDiskAccess: model.hasFullDiskAccess,
            isFirstRun: !model.hasEverScanned,
            onRecheckAccess: { model.recheckFullDiskAccess() },
            availableUpdate: model.availableUpdate,
            updateProgress: model.updateProgress,
            updateNote: model.updateNote,
            onInstallUpdate: { Task { await model.installUpdate() } },
            trash: model.trash,
            hasMovedToTrash: model.hasMovedToTrash,
            isEmptyingTrash: model.isEmptyingTrash,
            onEmptyTrash: { Task { await model.emptyTrash() } },
            onQuit: { NSApp.terminate(nil) },
            onAppearLive: { model.startLiveRefresh() },
            // reapNote를 여기서 지우지 않는다 — 초점만 잃어도 닫히는 팝오버라,
            // 닫을 때 지우면 종료·끄기의 결과를 읽을 기회가 사라진다.
            onDisappearLive: { model.stopLiveRefresh() }
        )
    }
}

/// 탭 → 내용 → 바닥.
///
/// 이 앱은 **숨어 있는 것을 찾아 치우는** 도구다. 성능 진단(판정문·부하·메모리)은
/// 걷어냈다 — 리서치가 결론 낸 대로 어떤 프로세스도 빠르게 만들 수는 없고, 이 앱이
/// 실제로 해낸 일은 숨은 용량과 숨은 프로세스를 드러낸 것이었다.
struct PopoverBody: View {
    var residueGroups: [ResidueGroup] = []
    let reapingPaths: Set<String>
    let reapBlocked: Bool
    let reapNote: UserNote?
    let hasScannedSpace: Bool
    let diskSpace: DiskSpace?
    var localSnapshotCount: Int = 0
    let spaceItems: [ReclaimItem]
    var unmeasuredNames: [String] = []
    var incompleteRoots: [String] = []
    var smallCaches: (count: Int, bytes: UInt64) = (0, 0)
    var skippedInUse: [ScanReport.InUseSkip] = []
    let isScanningSpace: Bool
    let scanProgress: ScanProgress?
    let scanStartedAt: Date?
    let spaceScanCompletedAt: Date?
    let spaceResultsFromDisk: Bool
    let isMovingToTrash: Bool
    let spaceNote: UserNote?
    var notificationsUnavailable: Bool = false
    var launchAgents: [LaunchAgent] = []
    var launchAgentsLoaded: Bool = true
    var startupItems: [StartupItem] = []
    var togglingAgents: Set<String> = []
    var onToggleAgent: (LaunchAgent) -> Void = { _ in }
    let onReap: (ResidueGroup) -> Void
    let onScanSpace: () -> Void
    let onMoveToTrash: ([ReclaimItem]) -> Void
    let onSpaceTabAppear: () -> Void
    let hasFullDiskAccess: Bool
    let isFirstRun: Bool
    let onRecheckAccess: () -> Void
    var availableUpdate: AvailableUpdate?
    var updateProgress: String?
    var updateNote: UserNote?
    var onInstallUpdate: () -> Void = {}
    let trash: TrashContents?
    var hasMovedToTrash: Bool = false
    let isEmptyingTrash: Bool
    let onEmptyTrash: () -> Void
    let onQuit: () -> Void
    let onAppearLive: () -> Void
    let onDisappearLive: () -> Void
    var initialTab: Tab = .space

    enum Tab: String, CaseIterable, Identifiable {
        case space, cleanup
        var id: String { rawValue }
    }

    @State private var tab: Tab?
    /// ⌘R 직후 잠깐 "새로 읽었어요"를 보여준다. 재조회는 조용히 끝나서,
    /// 반응이 없으면 단축키가 고장난 것처럼 보인다(사용자 신고).
    @State private var refreshFlash = false
    /// ⌘R을 받는 키 이벤트 모니터. 숨은 버튼 + .keyboardShortcut는 MenuBarExtra
    /// 창에서 발화하지 않았다(실측 2026-08-11: 스크린샷으로 확인) — 메뉴 키
    /// 등가 경로를 타는데 메뉴바 앱 창에는 그 경로가 없다. 앱에 배달되는
    /// keyDown을 직접 받는다.
    @State private var keyMonitor: Any?
    /// 이 뷰를 담은 창. 열릴 때 키로 만들어야 키 입력이 여기로 온다.
    @State private var hostWindow: NSWindow?
    /// 팝오버는 내용 크기로 창을 만든다. ScrollView는 고유 높이가 없어서 상한만 주면
    /// 0으로 붕괴한다(실측: 팝오버가 386×154로 뜨고 내용 영역이 비었다).
    /// 그래서 내용 높이를 재서 그만큼 주고, 길어지면 상한에서 자른다.
    @State private var paneHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            TabSwitcher(tabs: [
                (.space, "공간", spaceBadge),
                (.cleanup, "숨은 프로세스", residueBadge),
            ], selection: Binding(get: { tab ?? initialTab }, set: { tab = $0 }))

            if let reapNote {
                UserNoteLine(note: reapNote)
            }

            ScrollView {
                Group {
                    switch tab ?? initialTab {
                    case .space:
                        SpacePane(
                            hasScanned: hasScannedSpace,
                            diskSpace: diskSpace,
                            localSnapshotCount: localSnapshotCount,
                            items: spaceItems,
                            unmeasuredNames: unmeasuredNames,
                            incompleteRoots: incompleteRoots,
                            smallCaches: smallCaches,
                            skippedInUse: skippedInUse,
                            isScanning: isScanningSpace,
                            scanProgress: scanProgress, scanStartedAt: scanStartedAt,
                            spaceScanCompletedAt: spaceScanCompletedAt,
                            spaceResultsFromDisk: spaceResultsFromDisk,
                            isMoving: isMovingToTrash,
                            note: spaceNote,
                            hasFullDiskAccess: hasFullDiskAccess,
                            isFirstRun: isFirstRun,
                            onRecheckAccess: onRecheckAccess,
                            trash: trash, hasMovedToTrash: hasMovedToTrash,
                            isEmptyingTrash: isEmptyingTrash,
                            onScan: onScanSpace,
                            onMoveToTrash: onMoveToTrash,
                            onEmptyTrash: onEmptyTrash,
                            onAppear: onSpaceTabAppear)
                    case .cleanup:
                        CleanupPane(residueGroups: residueGroups,
                                    reapingPaths: reapingPaths,
                                    reapBlocked: reapBlocked,
                                    launchAgents: launchAgents,
                                    launchAgentsLoaded: launchAgentsLoaded,
                                    startupItems: startupItems,
                                    togglingAgents: togglingAgents,
                                    onToggleAgent: onToggleAgent,
                                    onReap: onReap)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    paneHeight = $0
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(max(paneHeight, 44), 320))

            if let updateNote { UserNoteLine(note: updateNote) }
            footer
        }
        .padding(13)
        .frame(width: 386)
        .task {
            onAppearLive()
            // 메뉴바 팝오버는 열려도 키 윈도우가 되지 않아, 키 입력이 직전에
            // 쓰던 앱으로 간다(실측 2026-08-11: HID 수준 ⌘R도 도달하지 않았고
            // NSApp.activate만으로는 부족했다). 창을 직접 키로 만들어야 ⌘R이
            // 여기 닿는다. 첫 열림에는 창 핸들이 몇 틱 늦게 잡히므로 잠깐
            // 기다린다. 팝오버는 바깥을 누르면 닫히면서 초점도 원래 앱으로
            // 돌아가므로 빼앗는 것이 아니다.
            for _ in 0..<20 where hostWindow == nil {
                try? await Task.sleep(for: .milliseconds(25))
            }
            guard !Task.isCancelled, let hostWindow else { return }
            NSApp.activate(ignoringOtherApps: true)
            hostWindow.makeKey()
        }
        .background(WindowGrabber(window: $hostWindow))
        // 습관처럼 ⌘R을 누르는 손을 위해: 열 때와 같은 가벼운 재조회(디스크·
        // 휴지통·로그인 항목·프로세스)를 다시 돈다. 60~90초짜리 전체 스캔은
        // 여기 걸지 않는다 — 그건 [다시 찾아보기]가 맡는다.
        .onAppear {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // 문자 비교만으로는 안 된다: 한글 입력기에서는 R 키가 "ㄱ"으로
                // 온다(실측 2026-08-11, 로그로 확인). 물리 키(kVK_ANSI_R = 15)를
                // 먼저 보고, 다른 자판 배열을 위해 문자 비교를 남긴다.
                guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                      event.keyCode == 15
                        || event.charactersIgnoringModifiers?.lowercased() == "r"
                else { return event }
                refreshNow()
                return nil   // 소비한다 — 처리할 곳이 없다는 삑 소리를 막는다
            }
        }
        .onDisappear {
            onDisappearLive()
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
        .overlay(alignment: .bottomLeading) {
            // 재조회가 조용히 끝나서, 이 반응이 없으면 ⌘R이 고장난 것처럼 보인다.
            // 오른쪽 위는 탭을 가려서 왼쪽 아래에 둔다(설정·종료 버튼 반대편).
            if refreshFlash {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10)).foregroundStyle(Palette.apps)
                    Text("새로 읽었어요").font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.regularMaterial, in: Capsule())
                .padding(8)
                .transition(.opacity)
            }
        }
    }

    /// 이 뷰가 붙은 NSWindow를 잡아 바인딩에 넣는다. MenuBarExtra는 창을 여는
    /// 공개 API도, 창 핸들을 주는 API도 없다 — 뷰 계층에서 거슬러 올라가는 것이
    /// 유일한 길이다(상태 항목을 AX로 찾는 AtticApp.swift의 사정과 같다).
    private struct WindowGrabber: NSViewRepresentable {
        @Binding var window: NSWindow?

        /// 창에 붙는 순간 핸들만 저장한다. **여기서 activate·makeKey를 부르면
        /// 안 된다** — 팝오버가 뜨기 전이라 표시 자체가 깨진다(실측 2026-08-11:
        /// 팝오버가 아예 열리지 않았다). 키로 만드는 것은 .task가 맡는다.
        final class AttachView: NSView {
            var onAttach: (NSWindow) -> Void = { _ in }
            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                if let window { onAttach(window) }
            }
        }

        func makeNSView(context: Context) -> AttachView {
            let view = AttachView()
            view.onAttach = { attached in
                Task { @MainActor in window = attached }
            }
            return view
        }

        func updateNSView(_ nsView: AttachView, context: Context) {
            Task { @MainActor [weak nsView] in window = nsView?.window }
        }
    }

    /// ⌘R의 실제 동작: 열 때와 같은 가벼운 재조회 + 잠깐의 시각 반응.
    private func refreshNow() {
        onAppearLive()
        withAnimation(.easeOut(duration: 0.15)) { refreshFlash = true }
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            withAnimation(.easeOut(duration: 0.3)) { refreshFlash = false }
        }
    }

    /// 비울 수 있는 총량. 단위 없는 숫자는 개수처럼 읽힌다("공간 70").
    private var spaceBadge: String? {
        let totalBytes = spaceItems.reduce(UInt64(0)) { $0 + $1.bytes }
        return totalBytes >= 1 << 30 ? SizeText.compact(totalBytes) : nil
    }

    /// 숨은 프로세스와 자동 실행 프로그램을 합쳐 센다 — 탭 하나가 둘을 담는다.
    private var residueBadge: String? {
        let count = residueGroups.count + launchAgents.filter { !$0.isDisabled }.count
        return count > 0 ? "\(count)" : nil
    }

    // MARK: 바닥

    private var footer: some View {
        HStack(spacing: 5) {
            // 새 버전은 조용히 한 줄로만 알린다 — 지금 하려는 일(공간 정리)을
            // 가리지 않는 자리다.
            if let updateProgress {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small).scaleEffect(0.5)
                    Text(updateProgress).font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            } else if let availableUpdate {
                Button { onInstallUpdate() } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.down.circle.fill").font(.system(size: 10))
                        Text(L("%@로 업데이트", availableUpdate.version))
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundStyle(Palette.apps)
                }
                .buttonStyle(.borderless)
                .help("받아서 교체하고 다시 시작해요 · 옛 버전은 휴지통으로 가요")
            }
            if notificationsUnavailable {
                Image(systemName: "bell.slash")
                    .help("알림이 꺼져 있어요 — 메뉴바 아이콘으로만 알려줍니다")
            }
            Spacer()
            // SettingsLink는 SwiftUI가 Settings scene을 여는 정식 방법이다.
            // sendAction(showSettingsWindow:)으로 바꿨더니 여기서도 안 열렸다 —
            // 그 액션은 앱 메뉴가 있을 때(도커에 표시하는 경우)만 responder
            // 체인에 걸린다. 뷰 안에서는 이걸 쓰는 것이 맞다.
            SettingsLink {
                Image(systemName: "gearshape").font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("설정")
            .accessibilityLabel("설정")
            .simultaneousGesture(TapGesture().onEnded {
                NSApp.activate(ignoringOtherApps: true)   // 없으면 창이 뒤에 뜬다
            })
            Button { onQuit() } label: {
                Image(systemName: "power").font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("Attic 종료")
            .accessibilityLabel("Attic 종료")
        }
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
    }
}
