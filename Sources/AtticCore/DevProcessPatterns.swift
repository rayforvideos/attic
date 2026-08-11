import Foundation

/// "개발 프로세스로 보이는가"의 유일한 정의. 잔류 탐지와 종료 가능 판정이 이
/// 기준을 공유해야 한쪽만 고쳐 조용히 어긋나는 일이 없다.
public enum DevProcessPatterns {
    /// argv 전체 문자열에 매칭한다.
    public static let patterns = ["vite", "webpack", "next dev", "nuxt", "rollup",
                                  "storybook", "jest --watch", "vitest", "playwright",
                                  "cypress", "mcp"]

    private static let regexes: [NSRegularExpression] = patterns.compactMap { pattern in
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
        return try? NSRegularExpression(pattern: "\\b\(escaped)\\b", options: [])
    }

    public static func matches(argv: [String]) -> Bool {
        let cmdline = argv.joined(separator: " ")
        let range = NSRange(cmdline.startIndex..., in: cmdline)
        return regexes.contains { $0.firstMatch(in: cmdline, options: [], range: range) != nil }
    }
}
