import Testing
import Foundation
@testable import AtticCore

@Suite("SpaceStore")
struct SpaceStoreTests {
    @Test func roundTripsSavedScanResult() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "space-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appending(path: "space.json")

        let items = [
            ReclaimItem(path: "/tmp/a", kind: .buildCache, displayName: "a",
                       bytes: 111, lastUsedDays: nil, note: "note-a"),
            ReclaimItem(path: "/tmp/b", kind: .nodeModules, displayName: "b",
                       bytes: 222, lastUsedDays: 40, note: "note-b"),
        ]
        let completedAt = Date()
        let store = SpaceStore(fileURL: fileURL)
        store.save(SpaceScanRecord(items: items, completedAt: completedAt))

        let reloaded = SpaceStore(fileURL: fileURL).load()
        let record = try #require(reloaded)
        #expect(record.items == items)
        #expect(abs(record.completedAt.timeIntervalSince(completedAt)) < 0.001)
    }

    @Test func loadReturnsNilWhenFileMissing() {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "space-store-missing-\(UUID().uuidString).json")
        #expect(SpaceStore(fileURL: fileURL).load() == nil)
    }
}


@Suite("SpaceStore — 없어진 필드 무시")
struct SpaceStoreDroppedFieldTests {
    /// Spotlight 기능을 걷어낸 뒤에도 그 키가 든 옛 파일을 읽어야 한다 —
    /// 못 읽으면 사용자가 지난 스캔 결과를 잃는다(전에 실제로 겪은 실수다).
    @Test func decodesRecordThatStillHasSpotlightPaths() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "space-old-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"items":[],"completedAt":760000000,"spotlightPaths":["/a","/b"]}"#.utf8)
            .write(to: url)
        let loaded = try #require(SpaceStore(fileURL: url).load())
        #expect(loaded.items.isEmpty)
    }
}
