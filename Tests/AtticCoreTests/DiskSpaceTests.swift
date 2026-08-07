import Testing
import Foundation
@testable import AtticCore

@Suite("DiskSpace")
struct DiskSpaceTests {
    @Test func computesUsedAndRatio() {
        let d = DiskSpace(total: 100, free: 40)
        #expect(d.used == 60)
        #expect(abs(d.usedRatio - 0.6) < 0.0001)
    }

    @Test func handlesDegenerateValues() {
        #expect(DiskSpace(total: 0, free: 0).usedRatio == 0)
        #expect(DiskSpace(total: 10, free: 20).used == 0)   // free > total 이면 0으로 막는다
    }

    @Test func liveProbeIsPlausible() throws {
        let d = try #require(DiskSpaceProbe().snapshot())
        #expect(d.total > 100 << 30)          // 100GB 이상 디스크
        #expect(d.free > 0 && d.free < d.total)
        #expect(d.usedRatio > 0 && d.usedRatio < 1)
        #expect(d.purgeable <= d.free)         // 비울 수 있는 영역은 여유의 일부다
    }

    /// tmutil 출력 파싱 — 헤더 줄은 스냅샷이 아니다.
    @Test func countsLocalSnapshotsFromTmutilOutput() {
        let output = """
        Snapshots for disk /:
        com.apple.TimeMachine.2026-08-04-120000.local
        com.apple.TimeMachine.2026-08-05-090000.local
        """
        #expect(LocalSnapshots.parseCount(from: output) == 2)
        #expect(LocalSnapshots.parseCount(from: "Snapshots for disk /:\n") == 0)
        #expect(LocalSnapshots.parseCount(from: "") == 0)
    }
}

@Suite("DirectorySize 배치 측정")
struct DirectorySizeBatchTests {
    /// 항목마다 du를 부르면 이 맥에서 280번이 되어 95초가 걸렸다 — 한 번에
    /// 여러 경로를 물어보고 경로별 크기를 받는다.
    @Test func measuresManyPathsInOneCall() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "batch-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        var paths: [String] = []
        for i in 0..<5 {
            let dir = root.appending(path: "d\(i)")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: 50_000 * (i + 1)).write(to: dir.appending(path: "f"))
            paths.append(dir.path)
        }
        let sizes = await DirectorySize.measureAll(paths)
        #expect(sizes.count == 5)
        for path in paths { #expect((sizes[path] ?? 0) > 0) }
        // 큰 쪽이 실제로 더 크게 나와야 한다
        #expect((sizes[paths[4]] ?? 0) > (sizes[paths[0]] ?? 0))
    }

    /// 없는 경로가 섞여도 나머지는 측정된다 — du는 실패한 것만 건너뛴다.
    @Test func skipsMissingPathsButMeasuresTheRest() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "batch2-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try Data(repeating: 0x41, count: 100_000).write(to: root.appending(path: "f"))
        let missing = root.path + "/does-not-exist"
        let sizes = await DirectorySize.measureAll([root.path, missing])
        #expect((sizes[root.path] ?? 0) > 0)
        #expect(sizes[missing] == nil)
    }
}

@Suite("UserSettings")
struct UserSettingsTests {
    /// 화면과 스캐너가 같은 기본값을 봐야 한다 — 어긋나면 코드가 의도한 기준을
    /// 사용자가 고를 수 없다(실제로 그랬다: 화면 최소 1GB, 스캐너 300MB).
    @Test func scannerDefaultMatchesSettingsDefault() {
        #expect(ReclaimScanner.defaultLargeFileThreshold
                == UInt64(UserSettings.defaultLargeFileMB) << 20)
    }

    /// 기본값은 흔한 동영상(300~800MB)을 지나치지 않아야 한다.
    @Test func defaultCatchesCommonVideoSizes() {
        #expect(UserSettings.defaultLargeFileMB <= 500)
    }
}
