import SwiftUI
import AtticCore

/// 정리 탭 — **숨어서 돌고 있는 것**을 모아 둔다. 창은 닫혔는데 살아 있는 개발
/// 프로세스와, 로그인마다 조용히 올라오는 프로그램이다.
struct CleanupPane: View {
    let residueGroups: [ResidueGroup]
    let reapingPaths: Set<String>
    let reapBlocked: Bool
    var launchAgents: [LaunchAgent] = []
    /// 부팅·로그인 항목 전체(시스템 포함, 읽기 전용).
    var startupItems: [StartupItem] = []
    var togglingAgents: Set<String> = []
    var onToggleAgent: (LaunchAgent) -> Void = { _ in }
    let onReap: (ResidueGroup) -> Void

    @State private var systemExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            // 로그인 항목을 먼저 둔다. 개발 프로세스는 개발자에게만 나오는데,
            // 그걸 맨 위에 두면 일반 사용자는 늘 "없어요" 한 줄만 보게 된다.
            agentSection
            leftoverSection
            if !residueGroups.isEmpty {
                Eyebrow(text: "창은 닫혔는데 아직 돌고 있는 개발 프로세스")
                VStack(spacing: 1) {
                    ForEach(residueGroups, id: \.projectPath) { group in
                        ResidueRow(group: group,
                                   busy: reapingPaths.contains(group.projectPath),
                                   blocked: reapBlocked,
                                   onReap: { onReap(group) })
                    }
                }
            }
            systemSection
        }
    }

    private var leftovers: [StartupItem] { startupItems.filter { $0.leftover != nil } }
    private var systemItems: [StartupItem] {
        startupItems.filter { $0.domain == .system && $0.leftover == nil }
    }

    /// 프로그램은 사라졌는데 자동 실행 등록만 남은 것. macOS는 로그인·부팅마다
    /// 이걸 띄우려다 실패한다 — 눈에 보이지 않는 찌꺼기다.
    @ViewBuilder
    private var leftoverSection: some View {
        if !leftovers.isEmpty {
            Eyebrow(text: "프로그램은 없는데 등록만 남은 것")
            VStack(spacing: 1) {
                ForEach(leftovers) { item in
                    MetricRow(symbol: "questionmark.folder",
                              symbolTint: Palette.over,
                              title: item.label,
                              subtitle: leftoverReason(item),
                              value: item.domain == .user ? L("내 계정") : L("시스템"),
                              valueTint: .secondary) { EmptyView() }
                }
            }
            Text("지워진 프로그램의 흔적이에요 · 시스템 항목은 관리자 권한이 있어야 지울 수 있어요")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .padding(.horizontal, 7).padding(.top, 3)
        }
    }

    private func leftoverReason(_ item: StartupItem) -> String {
        switch item.leftover {
        case .programMissing(let path): return L("실행할 파일이 없어요 — %@", path)
        case .emptyDefinition: return L("내용이 비어 있는 등록 파일이에요")
        case nil: return item.plistPath
        }
    }

    /// 관리자 권한이 있어야 바꿀 수 있는 것들. 끄지는 못해도 **무엇이 올라오는지**
    /// 아는 것 자체가 출발점이다(백신·은행 보안 프로그램·각종 업데이터).
    @ViewBuilder
    private var systemSection: some View {
        if !systemItems.isEmpty {
            DisclosureGroup(isExpanded: $systemExpanded) {
                VStack(spacing: 1) {
                    ForEach(systemItems) { item in
                        MetricRow(symbol: "gearshape.2",
                                  symbolTint: Palette.muted,
                                  title: item.label,
                                  subtitle: item.programPath ?? item.plistPath,
                                  value: "", valueTint: .secondary) { EmptyView() }
                    }
                }
                Text("이 목록은 관리자 권한이 있어야 바꿀 수 있어 여기서는 보여주기만 해요")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 7).padding(.top, 3)
            } label: {
                Text(L("부팅할 때 함께 올라오는 프로그램 %lld개", Int64(systemItems.count)))
                    .font(.system(size: 11, weight: .semibold))
            }
            .padding(.top, 2)
        }
    }

    /// 로그인마다 함께 올라오는 상주 프로그램(업데이터류). 끄기는 제거가 아니라
    /// launchd 등록 해제라 언제든 되돌릴 수 있다 — 그 사실을 문구로 보장한다.
    private var agentSection: some View {
        VStack(alignment: .leading, spacing: 1) {
            Eyebrow(text: "로그인할 때 자동 실행되는 프로그램")
            if launchAgents.isEmpty {
                EmptyNote(symbol: "checkmark.circle",
                          text: "자동 실행되도록 등록된 프로그램이 없어요")
            }
            ForEach(launchAgents) { agent in
                MetricRow(symbol: agent.isDisabled ? "moon.zzz.fill" : "arrow.trianglehead.2.clockwise",
                          symbolTint: agent.isDisabled ? Palette.muted : Palette.locked,
                          title: agent.programName ?? agent.label,
                          subtitle: agent.label,
                          value: agent.isDisabled ? L("꺼짐")
                                                  : (agent.isLoaded ? L("실행 중") : L("대기 중")),
                          valueTint: .secondary) {
                    RowAction(label: agent.isDisabled ? "켜기" : "끄기",
                              busy: togglingAgents.contains(agent.label),
                              disabled: false) { onToggleAgent(agent) }
                }
            }
            if !launchAgents.isEmpty {
                Text("끄면 다시 로그인해도 자동 실행되지 않아요 · 언제든 다시 켤 수 있어요")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 7).padding(.top, 3)
            }
        }
    }
}
