import Testing
import Foundation
@testable import AtticCore

@Suite("SizeCache")
struct SizeCacheTests {
    private func makeDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "sc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(count: 10).write(to: url.appending(path: "f"))
        return url
    }

    @Test func reusesWhenNothingChanged() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var cache = SizeCache()
        cache.record(path: dir.path, bytes: 12_345)
        #expect(cache.reusableBytes(for: dir.path) == 12_345)
    }

    /// 디렉터리가 바뀌면 다시 재야 한다 — 여기가 무너지면 옛 숫자를 계속 보여준다.
    @Test func remeasuresAfterDirectoryChanges() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var cache = SizeCache()
        cache.record(path: dir.path, bytes: 12_345)
        // mtime을 확실히 바꾼다(초 단위 정밀도 아래는 같은 값으로 본다)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: dir.path)
        #expect(cache.reusableBytes(for: dir.path) == nil)
    }

    /// mtime이 놓치는 변화가 무한정 쌓이지 않게 기간 제한을 둔다.
    @Test func expiresAfterMaxAge() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var cache = SizeCache()
        cache.record(path: dir.path, bytes: 999)
        let later = Date().addingTimeInterval(SizeCache.staleProjectMaxAge + 60)
        #expect(cache.reusableBytes(for: dir.path, now: later) == nil)
        // 캐시는 6시간이면 만료다 — 자라는 중인 숫자를 오래 붙들지 않는다
        #expect(cache.reusableBytes(for: dir.path,
                                    maxAge: SizeCache.volatileCacheMaxAge,
                                    now: Date().addingTimeInterval(7 * 3_600)) == nil)
        #expect(cache.reusableBytes(for: dir.path,
                                    maxAge: SizeCache.volatileCacheMaxAge,
                                    now: Date().addingTimeInterval(3_600)) == 999)
    }

    @Test func doesNotReuseForMissingPath() throws {
        let dir = try makeDir()
        var cache = SizeCache()
        cache.record(path: dir.path, bytes: 500)
        try FileManager.default.removeItem(at: dir)
        #expect(cache.reusableBytes(for: dir.path) == nil)
    }

    /// 사라진 경로를 계속 들고 있으면 파일이 끝없이 커진다.
    @Test func forgetsMissingPaths() throws {
        let alive = try makeDir()
        let gone = try makeDir()
        defer { try? FileManager.default.removeItem(at: alive) }
        var cache = SizeCache()
        cache.record(path: alive.path, bytes: 1)
        cache.record(path: gone.path, bytes: 2)
        try FileManager.default.removeItem(at: gone)
        cache.forgetMissing()
        #expect(cache.entries.keys.sorted() == [alive.path])
    }

    @Test func survivesRoundTripThroughJSON() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var cache = SizeCache()
        cache.record(path: dir.path, bytes: 4_096)
        let decoded = try JSONDecoder().decode(
            SizeCache.self, from: try JSONEncoder().encode(cache))
        #expect(decoded.reusableBytes(for: dir.path) == 4_096)
    }
}

@Suite("스캐너 — 크기 캐시", .serialized)
struct ScannerSizeCacheTests {
    /// 캐시에 있는 값은 다시 재지 않는다. 실제로 재본 것만 report.measured에
    /// 담겨야 한다 — 재사용한 값을 다시 저장하면 mtime 검사가 무의미해진다.
    @Test func reusesCachedSizeAndReportsOnlyFreshMeasurements() async throws {
        let home = try ReclaimScannerTests.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let derived = home.appending(path: "Library/Developer/Xcode/DerivedData").path

        let first = await ReclaimScanner(home: home.path, projectRoots: [],
                                        staleThresholdDays: 90).scan()
        #expect(first.measured[derived] != nil)
        let trueBytes = try #require(first.measured[derived])

        // 일부러 틀린 값을 캐시에 심어 재사용됐는지 확인한다
        var cache = SizeCache()
        cache.record(path: derived, bytes: trueBytes + (7 << 20))
        let second = await ReclaimScanner(home: home.path, projectRoots: [],
                                         staleThresholdDays: 90,
                                         sizeCache: cache).scan()
        let item = try #require(second.items.first { $0.path == derived })
        #expect(item.bytes == trueBytes + (7 << 20))    // 재지 않고 캐시 값을 썼다
        #expect(second.measured[derived] == nil)        // 재사용은 저장하지 않는다
    }
}
