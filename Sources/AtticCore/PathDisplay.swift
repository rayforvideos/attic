import Foundation

/// 경로를 좁은 화면에 보여주기 위한 다듬기.
///
/// 왜 필요한가: 되돌릴 수 없는 사용자 파일(스크린샷·받은 파일·큰 파일)은
/// **어디에 있는지**를 봐야 지울지 판단할 수 있다. 파일명만 보여주면 이 둘이
/// 화면에서 똑같이 보인다 — 하나는 연말정산 증빙이고 하나는 버려도 되는 것이다.
///
///     ~/2025 연말정산/ㅅㅁㅅ/스크린샷 2026-01-16 오후 2.31.25.png
///     ~/배민/스크린샷 2026-06-09 오후 5.41.31.png
public enum PathDisplay {
    /// 파일이 들어 있는 폴더를 사람이 읽는 형태로. 홈은 `~`로 접고, 너무 길면
    /// **가운데를** 접는다 — 뒤를 자르면 정작 어느 폴더인지가 사라진다.
    public static func folder(of path: String, home: String = NSHomeDirectory(),
                              limit: Int = 44) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return shorten(abbreviate(parent, home: home), limit: limit)
    }

    /// 홈만 `~`로 접는다. 길이는 건드리지 않는다 — 접는 폭이 자리마다 다르다.
    public static func abbreviateHome(_ path: String, home: String = NSHomeDirectory()) -> String {
        abbreviate(path, home: home)
    }

    static func abbreviate(_ path: String, home: String) -> String {
        guard !home.isEmpty else { return path }
        if path == home { return "~" }
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// 가운데를 `…`로 접는다. 앞(어느 폴더 계열인지)과 뒤(바로 담긴 폴더 이름)를
    /// 모두 남기는 것이 목적이다.
    static func shorten(_ text: String, limit: Int) -> String {
        guard limit > 3, text.count > limit else { return text }
        let keep = limit - 1                    // … 한 글자 자리
        let head = keep / 2
        let tail = keep - head
        return text.prefix(head) + "…" + text.suffix(tail)
    }
}
