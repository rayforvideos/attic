import SwiftUI
import AppKit
import AtticCore

/// 모델과 화면을 잇는 얇은 껍데기. 화면은 PopoverBody가 값만 받아 그리므로 실제
/// 시스템 상태 없이도 띄워 볼 수 있다.
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
                // 진행 상태는 모델이 들고 있다. 뷰와 모델 두 곳에 두면 다른 경로로
                // 들어올 때 한쪽만 잠긴다.
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
            // reapNote는 닫을 때 지우지 않는다. 팝오버는 초점만 잃어도 닫힌다.
            onDisappearLive: { model.stopLiveRefresh() }
        )
    }
}

/// 탭 → 내용 → 바닥.
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
    /// ⌘R 직후 잠깐 보여주는 반응. 재조회가 조용히 끝나서 반응이 없으면 단축키가
    /// 고장난 것처럼 보인다.
    @State private var refreshFlash = false
    /// ⌘R을 받는 키 이벤트 모니터. .keyboardShortcut는 메뉴 키 등가 경로를 타는데
    /// MenuBarExtra 창에는 그 경로가 없어 발화하지 않는다.
    @State private var keyMonitor: Any?
    /// 이 뷰를 담은 창. 열릴 때 키로 만들어야 키 입력이 여기로 온다.
    @State private var hostWindow: NSWindow?
    /// 팝오버는 내용 크기로 창을 만드는데 ScrollView는 고유 높이가 없어서 상한만
    /// 주면 0으로 붕괴한다. 내용 높이를 재서 주고 길어지면 상한에서 자른다.
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
            // 메뉴바 팝오버는 열려도 키 윈도우가 되지 않아 키 입력이 직전에 쓰던
            // 앱으로 간다. NSApp.activate만으로는 부족해 창을 직접 키로 만든다.
            // 첫 열림에는 창 핸들이 몇 틱 늦게 잡히므로 잠깐 기다린다.
            for _ in 0..<20 where hostWindow == nil {
                try? await Task.sleep(for: .milliseconds(25))
            }
            guard !Task.isCancelled, let hostWindow else { return }
            NSApp.activate(ignoringOtherApps: true)
            hostWindow.makeKey()
        }
        .background(WindowGrabber(window: $hostWindow))
        // ⌘R은 열 때와 같은 가벼운 재조회만 돈다. 몇 분짜리 전체 스캔은 여기 걸지
        // 않고 [다시 찾아보기]가 맡는다.
        .onAppear {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // 한글 입력기에서는 R 키가 "ㄱ"으로 오므로 문자 비교만으로는 안 된다.
                // 물리 키(kVK_ANSI_R = 15)를 먼저 보고, 다른 자판 배열을 위해 문자
                // 비교를 남긴다.
                guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                      event.keyCode == 15
                        || event.charactersIgnoringModifiers?.lowercased() == "r"
                else { return event }
                refreshNow()
                return nil   // 소비하지 않으면 처리할 곳이 없다는 삑 소리가 난다
            }
        }
        .onDisappear {
            onDisappearLive()
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
        .overlay(alignment: .bottomLeading) {
            // 오른쪽 위는 탭을 가려서 설정·종료 버튼 반대편인 왼쪽 아래에 둔다.
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

    /// 이 뷰가 붙은 NSWindow를 잡아 바인딩에 넣는다. MenuBarExtra는 창 핸들을 주는
    /// API가 없어 뷰 계층에서 거슬러 올라가는 수밖에 없다.
    private struct WindowGrabber: NSViewRepresentable {
        @Binding var window: NSWindow?

        /// 창에 붙는 순간 핸들만 저장한다. 여기서 activate·makeKey를 부르면 팝오버가
        /// 뜨기 전이라 표시 자체가 깨진다. 키로 만드는 것은 .task가 맡는다.
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

    /// 열 때와 같은 가벼운 재조회에 잠깐의 시각 반응을 더한다.
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

    /// 탭 하나가 둘을 담으므로 숨은 프로세스와 자동 실행 프로그램을 합쳐 센다.
    private var residueBadge: String? {
        let count = residueGroups.count + launchAgents.filter { !$0.isDisabled }.count
        return count > 0 ? "\(count)" : nil
    }

    // MARK: 바닥

    private var footer: some View {
        HStack(spacing: 5) {
            // 새 버전은 지금 하려는 일을 가리지 않게 한 줄로만 알린다.
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
            // sendAction(showSettingsWindow:)은 앱 메뉴가 있을 때만 responder
            // 체인에 걸려 메뉴바 앱에서는 열리지 않는다.
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
