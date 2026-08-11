import SwiftUI

/// 탭 전환 컨트롤.
///
/// `Picker(.segmented)`는 팝오버 안에서 선택된 칸만 그려지고 나머지가 나타나지
/// 않아 순수 SwiftUI로 직접 만든다.
struct TabSwitcher<Tab: Hashable>: View {
    let tabs: [(tab: Tab, title: LocalizedStringKey, badge: String?)]
    @Binding var selection: Tab

    var body: some View {
        HStack(spacing: 3) {
            ForEach(tabs, id: \.tab) { item in
                let selected = item.tab == selection
                Button {
                    selection = item.tab
                } label: {
                    HStack(spacing: 5) {
                        Text(item.title)
                            .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                        if let badge = item.badge, !badge.isEmpty {
                            Text(badge)
                                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background {
                                    Capsule().fill(selected ? Color.white.opacity(0.25)
                                                            : Palette.over.opacity(0.22))
                                }
                        }
                    }
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(selected ? Palette.apps : Color.clear)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(item.title))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        }
    }
}
