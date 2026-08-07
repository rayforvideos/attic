import SwiftUI
import AtticCore

/// 정리 탭 — **숨어서 돌고 있는 것**을 모아 둔다. 창은 닫혔는데 살아 있는 개발
/// 프로세스와, 로그인마다 조용히 올라오는 프로그램이다.
struct CleanupPane: View {
    let residueGroups: [ResidueGroup]
    let reapingPaths: Set<String>
    let reapBlocked: Bool
    var launchAgents: [LaunchAgent] = []
    var togglingAgents: Set<String> = []
    var onToggleAgent: (LaunchAgent) -> Void = { _ in }
    let onReap: (ResidueGroup) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if residueGroups.isEmpty {
                EmptyNote(symbol: "sparkles", text: "숨어서 돌고 있는 개발 프로세스가 없어요")
            } else {
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
            agentSection
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
