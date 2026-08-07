import Testing
import Foundation
@testable import AtticCore

@Suite("StartupInventory")
struct StartupInventoryTests {
    private func write(_ dir: URL, _ name: String, _ plist: [String: Any]) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: plist,
                                                      format: .xml, options: 0)
        try data.write(to: dir.appending(path: name))
    }

    private func makeDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory
            .appending(path: "startup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func flagsMissingProgramAsLeftover() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(dir, "com.example.gone.plist",
                  ["Label": "com.example.gone",
                   "ProgramArguments": ["/Library/PrivilegedHelperTools/gone-helper"]])
        let item = try #require(StartupInventory.inspect(
            path: dir.appending(path: "com.example.gone.plist").path, domain: .system))
        #expect(item.label == "com.example.gone")
        #expect(item.leftover == .programMissing(path: "/Library/PrivilegedHelperTools/gone-helper"))
    }

    /// 빈 plist와 "프로그램이 사라진 plist"는 다르다. 뭉뚱그려 말하면 화면이
    /// 거짓을 말한다 — 실제로 구글 keystone 항목이 빈 껍데기였는데 처음에
    /// "프로그램 없음"으로 잘못 셌다.
    @Test func distinguishesEmptyDefinition() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(dir, "com.example.empty.plist", [:])
        let item = try #require(StartupInventory.inspect(
            path: dir.appending(path: "com.example.empty.plist").path, domain: .user))
        #expect(item.leftover == .emptyDefinition)
        // 라벨이 없으면 파일명에서 가져온다
        #expect(item.label == "com.example.empty")
    }

    @Test func healthyItemHasNoLeftover() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(dir, "com.example.alive.plist",
                  ["Label": "com.example.alive", "Program": "/bin/ls"])
        let item = try #require(StartupInventory.inspect(
            path: dir.appending(path: "com.example.alive.plist").path, domain: .system))
        #expect(item.leftover == nil)
        #expect(item.programPath == "/bin/ls")
    }

    /// 읽지 못한 파일을 찌꺼기로 세면 안 된다. 권한이나 형식 때문에 못 읽는
    /// 경우가 실제로 있었다(심볼릭 링크로 앱 번들을 가리키는 plist).
    @Test func unreadableFileIsNotReported() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("이건 plist가 아니다".utf8).write(to: dir.appending(path: "broken.plist"))
        #expect(StartupInventory.inspect(
            path: dir.appending(path: "broken.plist").path, domain: .system) == nil)
        #expect(StartupInventory.inspect(path: "/does/not/exist.plist", domain: .system) == nil)
    }

    /// 애플 것은 시스템이 관리한다 — 보여줘도 사용자가 할 일이 없다.
    @Test func skipsAppleItems() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(dir, "x.plist", ["Label": "com.apple.something", "Program": "/nope"])
        #expect(StartupInventory.inspect(path: dir.appending(path: "x.plist").path,
                                         domain: .system) == nil)
    }

    /// 실제 맥에서 훑어도 터지지 않고, 읽은 것은 라벨이 있어야 한다.
    @Test func scansRealMachineSafely() {
        let items = StartupInventory().scan()
        for item in items {
            #expect(!item.label.isEmpty)
            #expect(!item.label.hasPrefix("com.apple."))
        }
        print(">>> 자동 실행 항목 \(items.count)개 · 찌꺼기 \(items.filter { $0.leftover != nil }.count)개")
    }
}
