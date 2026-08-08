import Testing
import Foundation
@testable import AtticCore

/// 가드를 뚫으려고 시도한다. 여기서 하나라도 통과하면 남의 파일이 사라진다.
@Suite("ReclaimGuard — 뚫기 시도")
struct GuardAdversarialTests {
    let home = "/Users/tester"

    private func check(_ path: String, kind: ReclaimKind = .nodeModules,
                       resolved: String? = nil, isSymlink: Bool = false,
                       lockfile: Bool = true, ageDays: Int = 200,
                       protectedPaths: [String] = []) -> ReclaimRefusal? {
        ReclaimGuard(home: home, extraProtected: protectedPaths)
            .check(path: path, kind: kind, lockfilePresent: lockfile, ageDays: ageDays,
                   isSymlink: isSymlink, resolvedPath: resolved ?? path,
                   staleThresholdDays: 90)
    }

    /// `..`로 허용 구역을 벗어나려는 시도. 문자열만 보면 허용 경로로 보인다.
    @Test func refusesParentTraversal() {
        #expect(check("\(home)/Library/Caches/Homebrew/../../../Documents/중요",
                      kind: .packageCache) != nil)
        #expect(check("\(home)/workspace/proj/node_modules/../../../.ssh") != nil)
    }

    /// 심볼릭 링크로 바깥을 가리키는 경우. **실제로 가리키는 곳**을 봐야 한다.
    @Test func refusesSymlinkPointingOutside() {
        #expect(check("\(home)/workspace/proj/node_modules",
                      resolved: "\(home)/Documents/소중한자료", isSymlink: true) != nil)
        #expect(check("\(home)/Library/Caches/Homebrew", kind: .packageCache,
                      resolved: "/System/Library", isSymlink: true) != nil)
    }

    /// 대소문자. APFS는 기본이 대소문자를 구분하지 않아서, 문자열 비교만 하면
    /// ~/documents 로 우회된다(실제로 뚫렸던 적이 있다).
    @Test func protectsRegardlessOfCase() {
        for variant in ["Documents", "documents", "DOCUMENTS", "DoCuMeNtS"] {
            #expect(check("\(home)/\(variant)/x/node_modules") != nil, "\(variant)")
        }
    }

    /// 사용자가 설정에 적어둔 폴더는 어떤 종류로도 손대지 않는다.
    @Test func honoursUserProtectedFolders() {
        let mine = "\(home)/work/secret"
        for kind in [ReclaimKind.nodeModules, .largeFile, .staleInstaller, .oldScreenshot] {
            #expect(check("\(mine)/node_modules", kind: kind, protectedPaths: [mine]) != nil,
                    "\(kind)")
        }
        // 하위 경로까지 막아야 한다
        #expect(check("\(mine)/깊이/더깊이/node_modules", protectedPaths: [mine]) != nil)
    }

    /// 홈 밖은 어떤 종류로도 대상이 아니다.
    @Test func refusesEverythingOutsideHome() {
        for path in ["/Library/Caches/Homebrew", "/System/Library/Caches",
                     "/Users/other/Library/Caches/Homebrew", "/tmp/node_modules",
                     "/Volumes/외장/node_modules"] {
            #expect(check(path, kind: .packageCache) != nil, "\(path)")
            #expect(check(path, kind: .nodeModules) != nil, "\(path)")
        }
    }

    /// 홈 자체나 최상위 폴더를 통째로 넘기는 경우.
    @Test func refusesHomeItselfAndTopLevelFolders() {
        for path in [home, "\(home)/", "\(home)/Documents", "\(home)/Desktop",
                    "\(home)/Library", "/", "/Users"] {
            #expect(check(path, kind: .largeFile) != nil, "\(path)")
        }
    }
}
