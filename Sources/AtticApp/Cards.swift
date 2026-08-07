import SwiftUI

/// 묶음 카드. 구분선으로 띠를 나누는 대신 내용을 카드에 담는다 —
/// macOS 26의 기본 어법이고, 무엇이 한 덩어리인지 눈으로 바로 잡힌다.
struct Card<Content: View>: View {
    var tint: Color? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(tint?.opacity(0.13) ?? Color.primary.opacity(0.07))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(tint?.opacity(0.32) ?? Color.primary.opacity(0.11),
                                  lineWidth: 0.8)
            }
    }
}

/// 목록의 한 줄. 왼쪽 심볼로 종류를, 오른쪽 값으로 크기를 읽게 하고,
/// 행동은 **항상 보이는 버튼**으로 둔다 — 호버해야 나타나는 버튼은 있는 줄도 모른다.
struct MetricRow<Trailing: View>: View {
    let symbol: String
    let symbolTint: Color
    let title: String
    let subtitle: String?
    let value: String
    var valueTint: Color = .primary
    /// 값 앞에 작게 붙는 상태 아이콘 (예: 느리게 해둔 프로세스의 거북이 표시). 기본은 없음.
    var valueIcon: String? = nil
    var valueIconTint: Color = .secondary
    var subtitleLines: Int = 1
    /// 경로는 **가운데를 접어야** 한다. 뒤를 자르면 정작 무엇인지 알려주는
    /// 파일명이 사라지고 "/Library/PrivilegedHelperTools/com.bjango.ista…"만
    /// 남는다. 문장은 그대로 뒤를 자른다.
    var subtitleTruncation: Text.TruncationMode = .tail
    @ViewBuilder var trailing: Trailing

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(symbolTint)
                .frame(width: 15)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(subtitleLines)
                        .truncationMode(subtitleTruncation)
                        .fixedSize(horizontal: false, vertical: subtitleLines > 1)
                }
            }
            Spacer(minLength: 6)
            HStack(spacing: 3) {
                if let valueIcon {
                    Image(systemName: valueIcon)
                        .font(.system(size: 9))
                        .foregroundStyle(valueIconTint)
                }
                Text(value)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(valueTint)
            }
            trailing
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.06 : 0))
        }
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onHover { hovering = $0 }
    }
}

extension MetricRow where Trailing == EmptyView {
    init(symbol: String, symbolTint: Color, title: String,
         subtitle: String?, value: String, valueTint: Color = .primary,
         subtitleLines: Int = 1) {
        self.init(symbol: symbol, symbolTint: symbolTint, title: title,
                  subtitle: subtitle, value: value, valueTint: valueTint,
                  subtitleLines: subtitleLines, trailing: { EmptyView() })
    }
}

/// 행에 붙는 작은 실행 버튼. 눌러도 되는 것처럼 보여야 한다.
///
/// 라벨은 `LocalizedStringKey`다 — String으로 받으면 SwiftUI가 번역 테이블을
/// 조회하지 않고 그대로 그린다(기기 언어가 영어여도 한국어가 나온다).
struct RowAction: View {
    let label: LocalizedStringKey
    let busy: Bool
    let disabled: Bool
    /// 한 줄에 버튼이 두 개 들어가야 할 때 폭과 글꼴을 줄인다.
    var compact: Bool = false
    let action: () -> Void

    private var minWidth: CGFloat { compact ? 34 : 44 }

    var body: some View {
        if busy {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.6)
                .frame(width: minWidth, height: 18)
        } else {
            Button(label, action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .font(compact ? .system(size: 10) : nil)
                .disabled(disabled)
                .frame(minWidth: minWidth)
        }
    }
}

/// 아무것도 할 일이 없을 때. 빈 화면은 안내할 자리다.
struct EmptyNote: View {
    let symbol: String
    let text: LocalizedStringKey

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 3)
    }
}
