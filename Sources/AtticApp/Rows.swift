import SwiftUI
import AtticCore

/// 정리 후보 한 줄. 판정 근거를 부제로 그대로 노출한다 — 휴리스틱이라 사용자가 검산해야 한다.
struct ResidueRow: View {
    let group: ResidueGroup
    let busy: Bool
    let blocked: Bool
    let onReap: () -> Void

    /// 종료는 되돌릴 수 없다(저장 안 된 작업이 날아간다) — 한 번 더 물어본다.
    /// 훨씬 회복 가능한 「휴지통 비우기」도 확인을 받는데 SIGKILL이 한 클릭이면
    /// 확인 비용이 위험과 거꾸로다(감사에서 확인). 별도 창(alert)은 팝오버를
    /// 닫아버릴 수 있어 같은 자리에서 받는다.
    @State private var confirming = false

    var body: some View {
        MetricRow(symbol: "terminal.fill", symbolTint: Palette.locked,
                  title: (group.projectPath as NSString).lastPathComponent,
                  subtitle: Evidence.sentence(for: group),
                  value: confirming ? "" : SizeText.compact(group.totalFootprint),
                  valueTint: .secondary, subtitleLines: 2) {
            if confirming {
                HStack(spacing: 4) {
                    Button(L("정말 종료")) { confirming = false; onReap() }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .tint(Palette.over)
                    Button(L("취소")) { confirming = false }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            } else {
                RowAction(label: "종료", busy: busy, disabled: blocked) {
                    confirming = true
                }
            }
        }
        .help(detail)
    }

    private var detail: String {
        let ports = group.allPorts.isEmpty ? ""
            : L(" · 포트 %@", group.allPorts.map(String.init).joined(separator: "·"))
        return group.projectPath + "\n"
            + L("프로세스 %lld개", group.candidates.count) + ports + "\n"
            + Evidence.sentence(for: group, limit: .max)
    }
}

/// 신호를 사람이 읽는 문장으로 옮긴다. 명사형으로 끝맺어 "~어요"가 반복되지 않게 한다.
///
/// 신호를 여섯 개 다 늘어놓으면 두 줄을 먹고 정작 결정적인 근거가 묻힌다.
/// 판단에 가장 세게 작용하는 순서로 정렬해 세 개만 보여주고, 전체는 툴팁으로 남긴다.
enum Evidence {
    /// 앞에 올수록 "정리해도 된다"는 근거로서 결정적이다.
    private static func rank(_ signal: ResidueSignal) -> Int {
        switch signal {
        case .orphaned:      0   // 띄운 창이 없다 = 아무도 안 보고 있다
        case .cpuIdle:       1   // 일을 안 하고 있다
        case .longLived:     2   // 오래 떠 있다
        case .duplicate:     3   // 중복이면 하나는 잉여다
        case .staleProject:  4   // 프로젝트를 안 건드린다
        case .holdsPorts:    5   // 정리하면 포트가 풀린다(부가 정보)
        }
    }

    static func sentence(for group: ResidueGroup, limit: Int = 3) -> String {
        let all = (group.candidates.first?.signals ?? []).sorted { rank($0) < rank($1) }
        return all.prefix(limit).map { signal -> String in
            switch signal {
            case .longLived(let hours):
                hours >= 24 ? L("%lld일째 켜져 있음", Int(hours / 24))
                            : L("%lld시간째 켜져 있음", Int(hours))
            case .orphaned:
                L("띄운 창은 이미 닫힘")
            case .cpuIdle(let hours):
                hours >= 1 ? L("%lld시간 동안 일 안 함", Int(hours)) : L("한동안 일 안 함")
            case .staleProject(let days):
                L("프로젝트 %lld일째 그대로", Int(days))
            case .duplicate(let count):
                L("같은 명령 %lld개 중복", count)
            case .holdsPorts(let ports):
                L("포트 %@ 사용 중", ports.map(String.init).joined(separator: "·"))
            }
        }.joined(separator: " · ")
    }
}
