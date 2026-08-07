import Foundation
import os

private let logger = os.Logger(subsystem: "com.sangjunpark.attic", category: "store")

/// JSON 장부의 원자적 읽기·쓰기. `.atomic` 쓰기만으로는 **찢어진 파일**만 막고
/// **갱신 유실**은 막지 못한다 — 인스턴스가 둘(설치본과 개발 빌드, 또는 종료 중
/// 인스턴스와 새 인스턴스) 겹치면 마지막 쓰기가 상대 기록을 조용히 되돌린다.
///
/// 그래서 read-modify-write를 `flock`으로 감싼다. 잠금은 별도 `.lock` 파일에
/// 걸어, 본 파일을 `.atomic`으로 교체(= inode 교체)해도 잠금이 유효하게 남는다.
public enum JSONFileStore {
    /// 잠금 아래에서 현재 값을 읽어 변형하고 저장한다. 반환값은 저장된 값.
    /// 실패해도 throw하지 않는다 — 장부는 앱의 필수 조건이 아니다.
    @discardableResult
    public static func update<T: Codable>(
        at fileURL: URL,
        default fallback: T,
        sanitize: (T) -> T = { $0 },
        transform: (inout T) -> Void
    ) -> T {
        let lockURL = fileURL.appendingPathExtension("lock")
        let handle = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        if handle >= 0 { flock(handle, LOCK_EX) }
        defer {
            if handle >= 0 { flock(handle, LOCK_UN); close(handle) }
        }

        var value = load(at: fileURL, default: fallback, sanitize: sanitize)
        transform(&value)
        do {
            try JSONEncoder().encode(value).write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Failed to save \(fileURL.lastPathComponent, privacy: .public): \(error, privacy: .public)")
        }
        return value
    }

    /// 잠금 없이 읽는다(읽기만 하는 경로용). 손상·부재 파일은 기본값이다 —
    /// 장부가 깨졌다는 사실이 앱을 멈출 이유는 없다.
    public static func load<T: Codable>(at fileURL: URL, default fallback: T,
                                        sanitize: (T) -> T = { $0 }) -> T {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(T.self, from: data) else {
            return fallback
        }
        return sanitize(decoded)
    }
}
