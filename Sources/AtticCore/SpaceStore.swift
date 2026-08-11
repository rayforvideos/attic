import Foundation
import os

private let logger = os.Logger(subsystem: "com.sangjunpark.attic", category: "space")

/// 끝난 공간 스캔 한 번의 결과. 지난번에 찾은 것을 보여주자고 켤 때마다 1분 넘는
/// `du` 훑기를 다시 돌리지 않으려고 저장한다.
public struct SpaceScanRecord: Sendable, Codable, Equatable {
    public let items: [ReclaimItem]
    public let completedAt: Date

    public init(items: [ReclaimItem], completedAt: Date) {
        self.items = items
        self.completedAt = completedAt
    }

    /// 직접 디코딩한다. 프로퍼티 기본값만 두면 합성된 `init(from:)`이 키 없는 옛
    /// 파일에서 실패해 사용자가 지난 스캔 결과를 통째로 잃는다. 모르는 키는 무시한다.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decode([ReclaimItem].self, forKey: .items)
        completedAt = try container.decode(Date.self, forKey: .completedAt)
    }
}

/// 마지막 공간 스캔 결과를 `~/Library/Application Support/Attic/space.json`에
/// 저장한다. 호출자에게 throw하지 않는다. 깨지거나 없는 파일은 "지난 결과 없음"이다.
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
