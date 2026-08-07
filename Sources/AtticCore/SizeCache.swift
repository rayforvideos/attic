import Foundation

/// 재본 크기를 기억한다. **바뀌지 않은 것을 다시 재지 않기 위한** 장치다.
///
/// 왜 필요한가(실측): 스캔의 거의 전부가 크기 측정이다 — 탐색은 0.77초인데
/// node_modules 82개를 재는 데 34.4초, 캐시 4개에 41.2초가 든다. 두 번째로 재도
/// 36초로 줄지 않는다(파일시스템 캐시가 도와주지 않는다). syscall 방식을 바꿔도
/// 소용없었다: getattrlistbulk 5.04초 vs du 4.43초 — 병목은 인터페이스가 아니라
/// 디스크 메타데이터 읽기다. 그래서 남은 길은 **재지 않는 것**뿐이다.
///
/// 무엇을 재사용해도 되는가: 우리가 제안하는 node_modules는 90일 넘게 손대지
/// 않은 프로젝트의 것이라 애초에 변할 일이 없다. 디렉터리의 mtime이 그대로면
/// 지난 값을 쓴다.
///
/// mtime은 완벽한 신호가 아니다(깊은 곳의 파일만 바뀌면 상위 mtime은 그대로다).
/// 그래도 안전한 이유: 휴지통으로 옮기기 직전에 **항상 다시 잰다**(Reclaimer가
/// remeasured로 보고한다). 목록의 숫자는 "언제 확인한 결과"라는 맥락 안에 있고,
/// 실제로 지우는 숫자는 그 순간에 다시 재서 말한다.
public struct SizeCache: Sendable, Codable, Equatable {
    public struct Entry: Sendable, Codable, Equatable {
        public let bytes: UInt64
        /// 잴 때 본 디렉터리 mtime. 이게 바뀌면 다시 잰다.
        public let modifiedAt: Date
        public let measuredAt: Date
    }

    /// 종류에 따라 유효 기간이 다르다. mtime은 완벽한 신호가 아니므로(깊은 곳의
    /// 파일만 바뀌면 상위 mtime은 그대로다) 기간으로 한 번 더 막는다.
    ///
    /// **오래된 프로젝트의 node_modules: 30일.** 90일 넘게 손대지 않은 프로젝트만
    /// 후보라서 애초에 변할 일이 없다. 되살아나면(npm install) mtime이 바뀐다.
    public static let staleProjectMaxAge: TimeInterval = 30 * 86_400

    /// **캐시: 6시간.** 캐시는 지금도 자라고 있다. 어제 재본 숫자를 오늘 보여주면
    /// 이 앱이 파는 유일한 것(정직한 숫자)을 잃는다. 방금 스캔한 뒤 다시 눌러보는
    /// 경우만 재사용하고, 하루 뒤에 열면 다시 잰다.
    public static let volatileCacheMaxAge: TimeInterval = 6 * 3_600

    public static let maxAge = staleProjectMaxAge

    public private(set) var entries: [String: Entry]

    public init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    /// 지금 다시 재지 않고 써도 되는 값. 없으면 nil이다.
    public func reusableBytes(for path: String,
                              maxAge: TimeInterval = SizeCache.staleProjectMaxAge,
                              now: Date = Date()) -> UInt64? {
        guard let entry = entries[path],
              now.timeIntervalSince(entry.measuredAt) < maxAge,
              let current = Self.modifiedAt(of: path),
              // 초 단위 아래는 파일시스템마다 정밀도가 달라 같은 값으로 본다.
              abs(current.timeIntervalSince(entry.modifiedAt)) < 1
        else { return nil }
        return entry.bytes
    }

    public mutating func record(path: String, bytes: UInt64, now: Date = Date()) {
        guard let modifiedAt = Self.modifiedAt(of: path) else { return }
        entries[path] = Entry(bytes: bytes, modifiedAt: modifiedAt, measuredAt: now)
    }

    /// 사라진 경로는 버린다 — 안 그러면 파일이 지워진 뒤에도 목록이 계속 커진다.
    public mutating func forgetMissing() {
        entries = entries.filter { FileManager.default.fileExists(atPath: $0.key) }
    }

    static func modifiedAt(of path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}
