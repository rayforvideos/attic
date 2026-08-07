import SwiftUI

/// 행동의 결과 한 줄. 실패한 결과에 성공 체크마크를 붙이면 성공처럼 읽힌다
/// (검수에서 확인) — 텍스트와 성패를 함께 들고 다니며 아이콘·색을 분기한다.
struct UserNote: Equatable {
    let text: String
    var failed: Bool = false

    static func ok(_ text: String) -> UserNote { UserNote(text: text) }
    static func fail(_ text: String) -> UserNote { UserNote(text: text, failed: true) }
}

/// 결과 한 줄의 공용 표시 — 팝오버 상단(reapNote)과 공간 탭(spaceNote)이 공유한다.
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
