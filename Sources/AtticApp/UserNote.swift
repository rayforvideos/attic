import SwiftUI

/// 행동의 결과 한 줄. 실패한 결과에 성공 체크마크가 붙지 않도록 텍스트와 성패를
/// 함께 들고 다닌다.
struct UserNote: Equatable {
    let text: String
    var failed: Bool = false

    static func ok(_ text: String) -> UserNote { UserNote(text: text) }
    static func fail(_ text: String) -> UserNote { UserNote(text: text, failed: true) }
}

/// 결과 한 줄의 공용 표시. 팝오버 상단과 공간 탭이 함께 쓴다.
struct UserNoteLine: View {
    let note: UserNote

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: note.failed ? "exclamationmark.triangle.fill"
                                          : "checkmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(note.failed ? Palette.over : Palette.apps)
            Text(note.text).font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
    }
}
