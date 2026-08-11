import SwiftUI

/// 색은 세 가지 상태(앱이 쓰는 양 / 잠긴 양 / 넘친 양)만 구분하고 나머지는
/// 시스템 색을 쓴다. 라이트·다크 양쪽에서 읽히도록 채도와 명도는 중간대다.
enum Palette {
    /// 앱들이 실제로 쓰고 있는 메모리
    static let apps = Color(red: 0.29, green: 0.56, blue: 0.66)
    /// 잠겨서 회수되지 않는 메모리(wired)
    static let locked = Color(red: 0.49, green: 0.42, blue: 0.66)
    /// 물리 메모리를 넘어서 압축·스왑이 감당하는 부분
    static let over = Color(red: 0.82, green: 0.54, blue: 0.17)
    /// 한계 상태에서만 쓰는 경고색
    static let alarm = Color(red: 0.78, green: 0.27, blue: 0.24)
    /// 손댈 수 없는 시스템 항목의 색. .secondary는 너무 옅어 심볼이 사라져 보인다.
    static let muted = Color(red: 0.53, green: 0.54, blue: 0.58)
}

/// 숫자는 고정폭으로 둔다. 갱신될 때 자리가 흔들리지 않아야 한다.
/// 한글은 고정폭에 넣지 않는다. 한글용 고정폭 자원이 없어 대체 서체로 떨어지며
/// 획 굵기와 자폭이 어긋난다. 자간도 한글에서는 낱자가 흩어져 보여 쓰지 않는다.
enum Typo {
    static let hero = Font.system(size: 33, weight: .medium, design: .monospaced)
    static let heroUnit = Font.system(size: 14, weight: .medium, design: .monospaced)
    static let heroCaption = Font.system(size: 11.5)
    static let eyebrow = Font.system(size: 10.5, weight: .semibold)
    static let rowTitle = Font.system(size: 12.5, weight: .semibold)
    static let rowValue = Font.system(size: 11.5, weight: .medium, design: .monospaced)
    static let body = Font.system(size: 11)
    static let legend = Font.system(size: 10)
    static let legendValue = Font.system(size: 10, weight: .medium, design: .monospaced)
    static let tick = Font.system(size: 9)
    static let tickValue = Font.system(size: 9, weight: .medium, design: .monospaced)
    static let footer = Font.system(size: 10)
}

/// 라벨 위에 붙는 작은 머리글. 섹션 사이를 구분선 대신 이것으로 나눈다.
struct Eyebrow: View {
    let text: LocalizedStringKey
    var trailing: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
                .font(Typo.eyebrow)
                .foregroundStyle(.secondary)
            if let trailing {
                Text(trailing)
                    .font(Typo.legendValue)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
    }
}
