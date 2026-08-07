import Testing
import Foundation
@testable import AtticCore

@Suite("DirectoryWalk")
struct DirectoryWalkTests {
    private func makeTree() throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "walk-\(UUID().uuidString)")
        for path in ["a", "a/b", "a/b/c", "a/b/c/d", "Library/Caches", ".hidden",
                     "proj/node_modules/dep/node_modules"] {
            try fm.createDirectory(at: root.appending(path: path),
                                   withIntermediateDirectories: true)
        }
        for path in ["top.bin", "a/one.bin", "a/b/two.bin", "a/b/c/three.bin",
                     "a/b/c/d/four.bin", "Library/Caches/cache.bin", ".hidden/secret.bin"] {
            try Data(repeating: 0x41, count: 1_000).write(to: root.appending(path: path))
        }
        return root
    }

    @Test func stopsAtMaxDepth() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        var files: [String] = []
        DirectoryWalk.walk(root: root.path, maxDepth: 2,
                           onFile: { path, _, _ in files.append(path) })
        // 루트 직속이 1단계다: top.bin(1) · a/one.bin(2) 까지만.
        #expect(files.contains { $0.hasSuffix("/top.bin") })
        #expect(files.contains { $0.hasSuffix("/a/one.bin") })
        #expect(!files.contains { $0.hasSuffix("/a/b/two.bin") })
    }

    @Test func prunesNamedDirectories() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        var files: [String] = []
        DirectoryWalk.walk(root: root.path, maxDepth: 6, pruneNames: ["Library"],
                           onFile: { path, _, _ in files.append(path) })
        #expect(!files.contains { $0.contains("/Library/") })
        #expect(files.contains { $0.hasSuffix("/a/b/c/d/four.bin") })
    }

    /// 숨김 폴더는 훑지 않는다 — 사용자가 파일로 여기지 않는 것을 목록에 올리면
    /// 안 되고, 여기까지 내려가면 훑기가 몇십 배 느려진다(실측: 42초).
    @Test func skipsHiddenEntries() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        var files: [String] = []
        DirectoryWalk.walk(root: root.path, maxDepth: 6,
                           onFile: { path, _, _ in files.append(path) })
        #expect(!files.contains { $0.contains("/.hidden/") })
    }

    /// onDirectory가 true면 그 아래로 들어가지 않는다 — node_modules 안의
    /// node_modules까지 세면 같은 용량을 두 번 세게 된다.
    @Test func doesNotDescendWhenDirectoryClaimed() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        var claimed: [String] = []
        DirectoryWalk.walk(root: root.path, maxDepth: 8, onDirectory: { path in
            guard (path as NSString).lastPathComponent == "node_modules" else { return false }
            claimed.append(path)
            return true
        })
        #expect(claimed.count == 1)
        #expect(claimed.first?.hasSuffix("/proj/node_modules") == true)
    }

    /// 심볼릭 링크는 따라가지 않는다 — 순환으로 훑기가 끝나지 않거나 같은 파일을
    /// 두 번 센다.
    @Test func doesNotFollowSymlinks() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: root.appending(path: "loop"),
                                                  withDestinationURL: root)
        var files: [String] = []
        DirectoryWalk.walk(root: root.path, maxDepth: 6,
                           onFile: { path, _, _ in files.append(path) })
        #expect(!files.contains { $0.contains("/loop/") })
    }

    /// 읽지 못한 폴더가 있으면 false. 이게 무너지면 일부만 훑은 결과가 완전한
    /// 것으로 올라가 "비울 게 없어요"가 거짓이 된다.
    @Test func reportsIncompleteWhenADirectoryIsUnreadable() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "denied-\(UUID().uuidString)")
        let locked = root.appending(path: "locked")
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data(count: 10).write(to: locked.appending(path: "f"))
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? fm.removeItem(at: root)
        }
        #expect(DirectoryWalk.walk(root: root.path, maxDepth: 4) == false)
        #expect(DirectoryWalk.walk(root: root.appending(path: "..").path, maxDepth: 1) == true)
    }

    @Test func reportsSizeAndTimestamp() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        var sizes: [String: UInt64] = [:]
        var stamps: [String: Date] = [:]
        DirectoryWalk.walk(root: root.path, maxDepth: 1, onFile: { path, bytes, at in
            sizes[(path as NSString).lastPathComponent] = bytes
            stamps[(path as NSString).lastPathComponent] = at
        })
        #expect(sizes["top.bin"] == 1_000)
        #expect(abs(stamps["top.bin"]!.timeIntervalSinceNow) < 60)
    }
}

@Suite("NodeModulesFinder")
struct NodeModulesFinderTests {
    /// 자식 프로세스(find) 대신 앱 안에서 훑는다. 찾는 결과는 같아야 한다.
    @Test func findsNodeModulesAndPrunesNested() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "nm-\(UUID().uuidString)")
        for path in ["one/node_modules/dep/node_modules", "two/deep/node_modules",
                     ".hidden/node_modules"] {
            try fm.createDirectory(at: root.appending(path: path),
                                   withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: root) }

        let result = NodeModulesFinder.find(under: root.path, maxDepth: 4)
        #expect(result.complete)
        #expect(Set(result.paths.map { ($0 as NSString).abbreviatingWithTildeInPath })
            .count == result.paths.count)
        #expect(result.paths.contains { $0.hasSuffix("/one/node_modules") })
        #expect(result.paths.contains { $0.hasSuffix("/two/deep/node_modules") })
        // 안쪽 node_modules는 따로 세지 않는다(용량 이중 계산)
        #expect(!result.paths.contains { $0.hasSuffix("/dep/node_modules") })
        // 숨김 폴더 아래는 보지 않는다
        #expect(!result.paths.contains { $0.contains("/.hidden/") })
    }
}

@Suite("DirectoryWalk 경로 표기")
struct DirectoryWalkPathTests {
    /// 심볼릭 링크가 섞인 루트(`/var` → `/private/var`)를 줘도 **받은 표기 그대로**
    /// 돌려줘야 한다. 풀린 경로를 넘기면 홈 아래 항목이 홈 밖으로 보여 가드가
    /// 전부 거부하고, 스캔 결과가 조용히 비어버린다(실제로 겪었다).
    ///
    /// `resolvingSymlinksInPath()`로는 감지할 수 없다 — 그 API는 `/private`
    /// 접두사를 다시 떼어내 원래 경로와 같은 값을 준다.
    @Test func keepsCallerPathNamespaceThroughSymlinkedRoot() throws {
        let fm = FileManager.default
        // /var는 /private/var의 심볼릭 링크다 — temporaryDirectory가 그 아래다.
        let root = fm.temporaryDirectory.appending(path: "ns-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appending(path: "sub"), withIntermediateDirectories: true)
        try Data(count: 10).write(to: root.appending(path: "sub/f.bin"))
        defer { try? fm.removeItem(at: root) }
        #expect(root.path.hasPrefix("/var/"), "이 테스트는 /var 아래 임시 폴더를 전제한다")

        var files: [String] = []
        var dirs: [String] = []
        DirectoryWalk.walk(root: root.path, maxDepth: 4,
                           onDirectory: { dirs.append($0); return false },
                           onFile: { path, _, _ in files.append(path) })
        #expect(files.allSatisfy { $0.hasPrefix(root.path) })
        #expect(dirs.allSatisfy { $0.hasPrefix(root.path) })
        #expect(files.first?.hasPrefix("/private/") == false)
    }
}
