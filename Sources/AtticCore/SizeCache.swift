import Foundation

/// 재본 크기를 기억해 바뀌지 않은 것을 다시 재지 않는다. 스캔 시간의 거의 전부가
/// 크기 측정이고, 병목이 디스크 메타데이터 읽기라 syscall을 바꿔도 줄지 않는다.
///
/// 디렉터리 mtime이 그대로면 지난 값을 쓴다. mtime은 완벽한 신호가 아니지만
/// (깊은 곳의 파일만 바뀌면 상위 mtime은 그대로다) 휴지통으로 옮기기 직전에는 항상
/// 다시 재므로, 실제로 비운 숫자는 그 순간 측정한 값이다.
public struct SizeCache: Sendable, Codable, Equatable {
    public struct Entry: Sendable, Codable, Equatable {
        public let bytes: UInt64
        /// 잴 때 본 디렉터리 mtime. 이게 바뀌면 다시 잰다.
        public let modifiedAt: Date
        public let measuredAt: Date
    }

    /// 오래된 프로젝트의 node_modules. 90일 넘게 손대지 않은 것만 후보라 변할 일이
    /// 없고, 되살아나면 mtime이 바뀐다.
    public static let staleProjectMaxAge: TimeInterval = 30 * 86_400

    /// 앱 캐시. 지금도 자라고 있어 어제 재본 숫자를 오늘 보여주면 안 된다. 방금
    /// 스캔한 뒤 다시 열어보는 경우에만 재사용한다.
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

    /// 사라진 경로는 버린다. 그러지 않으면 장부가 계속 커지기만 한다.
    public mutating func forgetMissing() {
        entries = entries.filter { FileManager.default.fileExists(atPath: $0.key) }
    }

    static func modifiedAt(of path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}
