import Testing
import Foundation
@testable import AtticCore

/// **스캔이 올린 것은 실행 직전 재검증도 통과해야 한다.**
///
/// 이 성질이 깨져서 실제로 이런 일이 있었다: 다운로드·스크린샷·보관본을 목록에
/// 올려놓고, 사용자가 고르고 「휴지통으로 옮기기」를 누르면 "최근에 썼다"며
/// 거부했다. Reclaimer가 나이를 0으로 넘겨서 가드가 전부 막은 것이다.
///
/// 재검증 자체는 있어야 한다(스캔과 실행 사이에 파일이 바뀔 수 있다) — 다만
/// **같은 사실을 두 곳이 다르게 재면** 사용자가 고른 것을 앱이 지우지 못한다.
@Suite("스캔과 실행이 같은 판단을 한다", .serialized)
struct ScanExecuteAgreementTests {
    /// 모든 사용자 파일 종류가 든 홈을 만든다.
    private func makeHome() throws -> URL {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appending(path: "agree-\(UUID().uuidString)")
        let old = Date().addingTimeInterval(-200 * 86_400)

        func put(_ relative: String, mb: Int = 3) throws {
            let url = home.appending(path: relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: mb << 20).write(to: url)
            try fm.setAttributes([.modificationDate: old, .creationDate: old],
                                 ofItemAtPath: url.path)
        }
        try put("Downloads/old-app.dmg")                                  // 설치 파일
        try put("Downloads/회의녹화.mp4")                                  // 설치 파일이 아닌 것
        try put("Downloads/자료모음/a.pdf")                                // 폴더로 제안됨
        try put("Downloads/자료모음/b.pdf")
        try put("Desktop/스크린샷 2026-01-02 오후 3.21.44.png")             // 스크린샷
        try put("Movies/big.mov", mb: 600)                                // 큰 파일
        try put("Library/Developer/Xcode/Archives/2026-01-02/App.xcarchive/Info.plist")
        try fm.setAttributes([.modificationDate: old, .creationDate: old],
                             ofItemAtPath: home.appending(
                                path: "Library/Developer/Xcode/Archives/2026-01-02/App.xcarchive").path)
        return home
    }

    @Test func everythingScannedCanActuallyBeMoved() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let report = await ReclaimScanner(home: home.path, projectRoots: [],
                                         staleThresholdDays: 90,
                                         largeFileThreshold: 100 << 20).scan()
        let userItems = report.items.filter {
            [.staleInstaller, .oldScreenshot, .largeFile, .xcodeArchive].contains($0.kind)
        }
        #expect(!userItems.isEmpty, "이 홈에서는 사용자 파일이 나와야 한다")

        // 실행 직전 재검증과 **같은 경로**로 확인한다: 거부되면 안 된다.
        let guardian = ReclaimGuard(home: home.path)
        for item in userItems {
            let age = FileAge.days(ofItemAt: item.path) ?? 0
            let refusal = guardian.check(
                path: item.path, kind: item.kind, lockfilePresent: false, ageDays: age,
                isSymlink: false,
                resolvedPath: URL(fileURLWithPath: item.path).resolvingSymlinksInPath().path,
                staleThresholdDays: 90)
            #expect(refusal == nil,
                    "스캔이 올린 \(item.kind) \(item.displayName)을 실행이 거부했다: \(String(describing: refusal))")
        }
    }

    /// 실제로 옮겨본다 — 가드를 통과하는 것을 넘어 파일이 정말 휴지통으로 가는지.
    @Test func moveToTrashActuallyMovesUserFiles() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let report = await ReclaimScanner(home: home.path, projectRoots: [],
                                         staleThresholdDays: 90,
                                         largeFileThreshold: 100 << 20).scan()
        let target = try #require(report.items.first { $0.kind == .staleInstaller })

        let result = await Reclaimer().moveToTrash([target],
                                                   guard: ReclaimGuard(home: home.path),
                                                   staleThresholdDays: 90)
        #expect(result.movedCount == 1, "거부: \(result.refused.map(\.reason))")
        #expect(result.refused.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }
}
