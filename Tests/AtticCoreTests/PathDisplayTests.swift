import Testing
import Foundation
@testable import AtticCore

@Suite("PathDisplay")
struct PathDisplayTests {
    let home = "/Users/tester"

    @Test func showsContainingFolderWithTilde() {
        #expect(PathDisplay.folder(of: "\(home)/배민/스크린샷 2026-06-09.png", home: home)
                == "~/배민")
        #expect(PathDisplay.folder(of: "\(home)/Downloads/app.dmg", home: home)
                == "~/Downloads")
    }

    /// 홈 밖의 경로는 그대로 보여준다 — ~로 접으면 거짓이 된다.
    @Test func leavesPathsOutsideHomeAlone() {
        #expect(PathDisplay.folder(of: "/Volumes/외장/영상/a.mov", home: home)
                == "/Volumes/외장/영상")
        // 홈과 접두어만 같은 다른 폴더를 잘못 접지 않는다
        #expect(PathDisplay.folder(of: "/Users/tester2/x/a.png", home: home)
                == "/Users/tester2/x")
    }

    /// 긴 경로는 **가운데를** 접는다. 뒤를 자르면 정작 어느 폴더인지가 사라진다.
    @Test func elidesMiddleOfLongPaths() {
        let long = "\(home)/워크스페이스/고객사/2026/상반기/디자인/시안/최종/a.png"
        let shown = PathDisplay.folder(of: long, home: home, limit: 24)
        #expect(shown.count <= 24)
        #expect(shown.hasPrefix("~/워크"))
        #expect(shown.hasSuffix("최종"), "바로 담긴 폴더 이름은 남아야 한다")
        #expect(shown.contains("…"))
    }

    @Test func shortPathsAreUntouched() {
        #expect(PathDisplay.shorten("~/배민", limit: 44) == "~/배민")
        #expect(PathDisplay.folder(of: "\(home)/a.png", home: home) == "~")
    }
}
