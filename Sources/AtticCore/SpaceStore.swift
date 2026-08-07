import Foundation
import os

private let logger = os.Logger(subsystem: "com.sangjunpark.attic", category: "space")

/// One completed space scan, persisted so the app doesn't have to re-run a
/// 60~90 second `du` sweep on every launch just to show what it already
/// found last time.
public struct SpaceScanRecord: Sendable, Codable, Equatable {
    public let items: [ReclaimItem]
    public let completedAt: Date

    public init(items: [ReclaimItem], completedAt: Date) {
        self.items = items
        self.completedAt = completedAt
    }

    /// 필드를 추가·제거할 때 **명시적으로** 디코딩한다. 프로퍼티 기본값만 두면
    /// 합성된 `init(from:)`이 키가 없는 옛 파일에서 그대로 실패하고(실측),
    /// 사용자는 지난 스캔 결과 전부를 잃은 채 "찾아보기" 화면으로 돌아간다.
    /// 지금은 spotlightPaths가 든 옛 파일도 읽혀야 한다(그 키는 무시한다).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decode([ReclaimItem].self, forKey: .items)
        completedAt = try container.decode(Date.self, forKey: .completedAt)
    }
}

/// Persists the last space scan result to
/// `~/Library/Application Support/Attic/space.json`. Mirrors
/// `TrendStore`'s shape: load-on-init, best-effort save, never throws to
/// callers — a corrupt or missing file just means "no prior result."
public struct SpaceStore: Sendable {
    let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() -> SpaceScanRecord? {
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(SpaceScanRecord.self, from: data)
        } catch {
            logger.error("Failed to load space scan record: \(error, privacy: .public)")
            return nil
        }
    }

    public func save(_ record: SpaceScanRecord) {
        JSONFileStore.update(at: fileURL, default: record) { $0 = record }
    }
}
