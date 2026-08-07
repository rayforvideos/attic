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
    @State private var isMovingToTrash = false

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
            isScanningSpace: model.isScanningSpace,
            scanProgress: model.scanProgress,
            scanStartedAt: model.scanStartedAt,
            spaceScanCompletedAt: model.spaceScanCompletedAt,
            spaceResultsFromDisk: model.spaceResultsFromDisk,
            isMovingToTrash: isMovingToTrash,
            spaceNote: model.spaceNote,
            notificationsUnavailable: model.notifier.fallbackActive,
            launchAgents: model.launchAgents,
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
                isMovingToTrash = true
                Task {
                    await model.moveToTrash(items)
                    isMovingToTrash = false
                }
            },
            onSpaceTabAppear: { model.markSpaceResultsSeen() },
            hasFullDiskAccess: model.hasFullDiskAccess,
            isFirstRun: !model.hasEverScanned,
            onRecheckAccess: { model.recheckFullDiskAccess() },
            trash: model.trash,
            isEmptyingTrash: model.isEmptyingTrash,
            onEmptyTrash: { Task { await model.emptyTrash() } },
            onOpenSettings: {
                NSApp.activate(ignoringOtherApps: true)   // 없으면 창이 다른 앱 뒤에 뜬다
                AppDelegate.openSettings()
            },
            onQuit: { NSApp.terminate(nil) },
            onAppearLive: { model.startLiveRefresh() },
            onDisappearLive: { model.stopLiveRefresh(); reapNote = nil }
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
    let isScanningSpace: Bool
    let scanProgress: ScanProgress?
    let scanStartedAt: Date?
    let spaceScanCompletedAt: Date?
    let spaceResultsFromDisk: Bool
    let isMovingToTrash: Bool
    let spaceNote: UserNote?
    var notificationsUnavailable: Bool = false
    var launchAgents: [LaunchAgent] = []
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
    let trash: TrashContents?
    let isEmptyingTrash: Bool
    let onEmptyTrash: () -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void
    let onAppearLive: () -> Void
    let onDisappearLive: () -> Void
    var initialTab: Tab = .space

    enum Tab: String, CaseIterable, Identifiable {
        case space, cleanup
        var id: String { rawValue }
    }

    @State private var tab: Tab?
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
                            isScanning: isScanningSpace,
                            scanProgress: scanProgress, scanStartedAt: scanStartedAt,
                            spaceScanCompletedAt: spaceScanCompletedAt,
                            spaceResultsFromDisk: spaceResultsFromDisk,
                            isMoving: isMovingToTrash,
                            note: spaceNote,
                            hasFullDiskAccess: hasFullDiskAccess,
                            isFirstRun: isFirstRun,
                            onRecheckAccess: onRecheckAccess,
                            trash: trash, isEmptyingTrash: isEmptyingTrash,
                            onScan: onScanSpace,
                            onMoveToTrash: onMoveToTrash,
                            onEmptyTrash: onEmptyTrash,
                            onAppear: onSpaceTabAppear)
                    case .cleanup:
                        CleanupPane(residueGroups: residueGroups,
                                    reapingPaths: reapingPaths,
                                    reapBlocked: reapBlocked,
                                    launchAgents: launchAgents,
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

            footer
        }
        .padding(13)
        .frame(width: 386)
        .task { onAppearLive() }
        .onDisappear { onDisappearLive() }
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
            if notificationsUnavailable {
                Image(systemName: "bell.slash")
                    .help("알림이 꺼져 있어요 — 메뉴바 아이콘으로만 알려줍니다")
            }
            Spacer()
            Button { onOpenSettings() } label: {
                Image(systemName: "gearshape").font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("설정")
            .accessibilityLabel("설정")
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
