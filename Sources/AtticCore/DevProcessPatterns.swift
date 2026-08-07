import Foundation

/// "개발 프로세스로 보이는가"의 유일한 정의. `ResidueDetector`(잔류 탐지)와
/// `CPUAttribution`(종료 가능 판정) 양쪽이 이 하나의 기준을 공유한다 — 기준이
/// 두 곳에 따로 있으면 어느 한쪽만 고쳤을 때 조용히 어긋난다.
public enum DevProcessPatterns {
    /// 대상 패턴 (설계 §7): argv 전체 문자열에 매칭
    public static let patterns = ["vite", "webpack", "next dev", "nuxt", "rollup",
                                  "storybook", "jest --watch", "vitest", "playwright",
                                  "cypress", "mcp"]

    /// 표본마다·패턴마다 다시 컴파일하면 낭비다 — 한 번만 컴파일해 재사용한다.
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
