import Foundation

/// 경로를 좁은 화면에 보여주기 위한 다듬기. 사용자 파일은 파일명만으로는 지울지
/// 판단할 수 없고 어느 폴더에 있는지를 봐야 한다.
public enum PathDisplay {
    /// 파일이 들어 있는 폴더를 사람이 읽는 형태로 만든다. 홈은 `~`로 접고, 너무
    /// 길면 가운데를 접는다. 뒤를 자르면 정작 어느 폴더인지가 사라진다.
    public static func folder(of path: String, home: String = NSHomeDirectory(),
                              limit: Int = 44) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return shorten(abbreviate(parent, home: home), limit: limit)
    }

    /// 홈만 `~`로 접는다. 접는 폭이 자리마다 달라 길이는 건드리지 않는다.
    public static func abbreviateHome(_ path: String, home: String = NSHomeDirectory()) -> String {
        abbreviate(path, home: home)
    }

    static func abbreviate(_ path: String, home: String) -> String {
        guard !home.isEmpty else { return path }
        if path == home { return "~" }
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// 가운데를 `…`로 접어 앞쪽 계열과 바로 담긴 폴더 이름을 모두 남긴다.
    static func shorten(_ text: String, limit: Int) -> String {
        guard limit > 3, text.count > limit else { return text }
        let keep = limit - 1                    // … 한 글자 자리
        let head = keep / 2
        let tail = keep - head
        return text.prefix(head) + "…" + text.suffix(tail)
    }
}
