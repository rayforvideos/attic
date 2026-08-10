import Testing
import Foundation
@testable import AtticCore

@Suite("Trash")
struct TrashTests {
    /// 테스트용 휴지통. 이름이 `.Trash`여야 한다 — empty()가 그 이름만 지운다.
    private func makeTrash() throws -> (Trash, URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "trash-\(UUID().uuidString)")
        let dir = root.appending(path: ".Trash")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (Trash(directory: dir), root)
    }

    private func put(_ name: String, bytes: Int, in dir: URL) throws {
        try Data(repeating: 0x41, count: bytes).write(to: dir.appending(path: name))
    }

    @Test func reportsSizeAndCount() async throws {
        let (trash, root) = try makeTrash()
        defer { try? FileManager.default.removeItem(at: root) }
        try put("a.dmg", bytes: 200_000, in: trash.directory)
        try put("b.zip", bytes: 100_000, in: trash.directory)

        let contents = try #require(await trash.inspect())
        #expect(contents.itemCount == 2)
        #expect(contents.bytes > 250_000)
        #expect(!contents.isEmpty)
    }

    /// 빈 휴지통은 0바이트다 — "읽을 수 없음"(nil)과 반드시 구별돼야 한다.
    /// 두 경우가 같아지면 권한이 없는 사용자에게 "휴지통이 비었어요"라고 거짓말한다.
    @Test func emptyTrashIsZeroNotNil() async throws {
        let (trash, root) = try makeTrash()
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = try #require(await trash.inspect())
        #expect(contents.itemCount == 0)
        #expect(contents.bytes == 0)
        #expect(contents.isEmpty)
    }

    /// .DS_Store만 남은 휴지통은 사용자 눈에 비어 있다 — 비우라고 권하면 안 된다.
    @Test func ignoresDSStore() async throws {
        let (trash, root) = try makeTrash()
        defer { try? FileManager.default.removeItem(at: root) }
        try put(".DS_Store", bytes: 6_000, in: trash.directory)
        let contents = try #require(await trash.inspect())
        #expect(contents.isEmpty)
    }

    /// 읽을 수 없으면 nil이다(전체 디스크 접근이 없는 실제 상황).
    @Test func returnsNilWhenUnreadable() async {
        let missing = URL(fileURLWithPath: "/does/not/exist/.Trash")
        #expect(await Trash(directory: missing).inspect() == nil)
    }

    /// 방금 옮긴 직후에는 양과 무관하게 비우기를 권한다 — 사용자가 직접 옮긴
    /// 맥락이 있으니 잔소리가 아니다. 평소에는 100MB 문턱을 그대로 쓴다.
    @Test func offersEmptyingRightAfterMoveRegardlessOfSize() {
        let small = TrashContents(bytes: 1 << 20, itemCount: 3)
        #expect(small.shouldOfferEmptying(justMoved: true))
        #expect(!small.shouldOfferEmptying(justMoved: false))
    }

    /// 빈 휴지통은 옮긴 직후라도 비우라고 하지 않는다 — 비울 것이 없다.
    @Test func neverOffersEmptyingEmptyTrash() {
        let empty = TrashContents(bytes: 0, itemCount: 0)
        #expect(!empty.shouldOfferEmptying(justMoved: true))
    }

    /// 옮긴 적이 없어도 100MB를 넘으면 기존대로 권한다.
    @Test func offersEmptyingBigTrashWithoutMove() {
        let big = TrashContents(bytes: 200 << 20, itemCount: 1)
        #expect(big.shouldOfferEmptying(justMoved: false))
    }

    @Test func emptiesEverythingIncludingDirectories() async throws {
        let (trash, root) = try makeTrash()
        defer { try? FileManager.default.removeItem(at: root) }
        try put("a.dmg", bytes: 1_000, in: trash.directory)
        let sub = trash.directory.appending(path: "folder")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try put("nested", bytes: 1_000, in: sub)

        let outcome = await trash.empty()
        #expect(outcome.removed == 2)
        #expect(outcome.failed == 0)
        #expect(await trash.inspect()?.isEmpty == true)
        // 휴지통 자체는 남아야 한다 — 디렉터리를 지우면 macOS가 다시 만들 때까지
        // 휴지통으로 옮기기가 실패한다.
        #expect(FileManager.default.fileExists(atPath: trash.directory.path))
    }

    /// 경로를 잘못 받아도 휴지통이 아닌 디렉터리는 절대 지우지 않는다.
    /// 이 방어가 없으면 한 줄 실수로 홈 디렉터리가 사라진다.
    @Test func refusesToEmptyNonTrashDirectory() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "not-trash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(repeating: 0x41, count: 100).write(to: dir.appending(path: "precious.txt"))

        let outcome = await Trash(directory: dir).empty()
        #expect(outcome.removed == 0)
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "precious.txt").path))
    }
}
