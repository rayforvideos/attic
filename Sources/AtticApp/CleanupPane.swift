import SwiftUI
import AtticCore

/// 정리 탭. 창은 닫혔는데 살아 있는 개발 프로세스와, 로그인마다 조용히 올라오는
/// 프로그램을 모아 둔다.
struct CleanupPane: View {
    /// L()로 만든 문자열은 locale을 읽지 않는다. 이 선언이 없으면 언어를 바꿔도
    /// L()로 조립한 문구만 옛 언어로 남는다.
    @Environment(\.locale) private var locale

    let residueGroups: [ResidueGroup]
    let reapingPaths: Set<String>
    let reapBlocked: Bool
    var launchAgents: [LaunchAgent] = []
    /// 목록을 한 번이라도 읽었는지. 조회 중인 빈 목록을 "없어요"로 단정하지 않는다.
    var launchAgentsLoaded: Bool = true
    /// 부팅·로그인 항목 전체(시스템 포함, 읽기 전용).
    var startupItems: [StartupItem] = []
    var togglingAgents: Set<String> = []
    var onToggleAgent: (LaunchAgent) -> Void = { _ in }
    let onReap: (ResidueGroup) -> Void

    @State private var systemExpanded = false
    @State private var systemHovering = false

    var body: some View {
        let _ = locale   // 읽어야 언어 변경이 이 뷰를 다시 그린다
        VStack(alignment: .leading, spacing: 9) {
            // 개발 프로세스는 개발자에게만 나오므로 로그인 항목을 먼저 둔다.
            // 그러지 않으면 일반 사용자는 늘 "없어요" 한 줄만 보게 된다.
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

    /// 프로그램은 사라졌는데 자동 실행 등록만 남은 것. macOS가 로그인·부팅마다
    /// 이걸 띄우려다 조용히 실패한다.
    @ViewBuilder
    private var leftoverSection: some View {
        if !leftovers.isEmpty {
            Eyebrow(text: "프로그램은 없는데 등록만 남은 것")
            VStack(spacing: 1) {
                ForEach(leftovers) { item in
                    MetricRow(symbol: "questionmark.folder",
                              symbolTint: Palette.over,
                              title: item.label,
                              subtitle: leftoverPath(item),
                              value: leftoverReason(item),
                              valueTint: .secondary,
                              subtitleTruncation: .middle) { EmptyView() }
                }
            }
            Text("지워진 프로그램의 흔적이에요 · 시스템 항목은 관리자 권한이 있어야 지울 수 있어요")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .padding(.horizontal, 7).padding(.top, 3)
        }
    }

    /// 값 칸에는 왜 찌꺼기인지만 짧게 넣는다. 경로는 부제로 내린다.
    private func leftoverReason(_ item: StartupItem) -> String {
        switch item.leftover {
        case .programMissing: return L("실행 파일 없음")
        case .emptyDefinition: return L("빈 파일")
        case nil: return ""
        }
    }

    /// 홈은 `~`로 접는다. 좁은 화면에서 자리를 아끼고, 스크린샷이나 화면 공유에
    /// 계정 이름이 딸려 나가지 않는다.
    private func leftoverPath(_ item: StartupItem) -> String {
        let path: String
        if case .programMissing(let raw) = item.leftover { path = raw } else { path = item.plistPath }
        return PathDisplay.abbreviateHome(path)
    }

    /// 관리자 권한이 있어야 바꿀 수 있는 것들이라 보여주기만 한다.
    ///
    /// DisclosureGroup은 클릭 영역이 삼각형과 글자에만 걸려 누르기 어렵고 열린
    /// 상태도 눈에 띄지 않아, 줄 전체를 버튼으로 직접 만든다.
    @ViewBuilder
    private var systemSection: some View {
        if !systemItems.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { systemExpanded.toggle() }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(systemExpanded ? 90 : 0))
                            .frame(width: 10)
                        Text(L("부팅할 때 함께 올라오는 프로그램 %lld개", Int64(systemItems.count)))
                            .font(.system(size: 11, weight: .semibold))
                        Spacer(minLength: 0)
                        Text(systemExpanded ? L("접기") : L("펼치기"))
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 6)
                    .background {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(systemExpanded ? Palette.apps.opacity(0.12)
                                  : (systemHovering ? Color.primary.opacity(0.06) : .clear))
                    }
                    // 배경이 없는 부분도 눌리게 한다.
                    .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .onHover { systemHovering = $0 }

                if systemExpanded {
                    VStack(spacing: 1) {
                        ForEach(systemItems) { item in
                            MetricRow(symbol: "gearshape.2",
                                      symbolTint: Palette.muted,
                                      title: item.label,
                                      subtitle: item.programPath ?? item.plistPath,
                                      value: "", valueTint: .secondary,
                                      subtitleTruncation: .middle) { EmptyView() }
                        }
                    }
                    Text("이 목록은 관리자 권한이 있어야 바꿀 수 있어 여기서는 보여주기만 해요")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                        .padding(.horizontal, 7).padding(.top, 3)
                }
            }
            .padding(.top, 2)
        }
    }

    /// 로그인마다 함께 올라오는 상주 프로그램. 끄기는 제거가 아니라 launchd 등록
    /// 해제라 언제든 되돌릴 수 있고, 안내 문구가 그 사실을 보장한다.
    private var agentSection: some View {
        VStack(alignment: .leading, spacing: 1) {
            Eyebrow(text: "로그인할 때 자동 실행되는 프로그램")
            if launchAgents.isEmpty {
                // 조회가 끝나기 전에는 "없어요"라고 단정하지 않는다.
                if launchAgentsLoaded {
                    EmptyNote(symbol: "checkmark.circle",
                              text: "자동 실행되도록 등록된 프로그램이 없어요")
                } else {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small).scaleEffect(0.6)
                        Text("자동 실행 목록을 확인하는 중이에요")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 7).padding(.vertical, 4)
                }
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
