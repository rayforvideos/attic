import Testing
import Foundation
@testable import AtticCore

@Suite("AppVersion")
struct AppVersionTests {
    /// 문자열 비교로는 "0.10.0" < "0.9.0"이 되어 새 버전을 놓친다.
    @Test func comparesNumerically() {
        #expect(AppVersion("0.9.0")! < AppVersion("0.10.0")!)
        #expect(AppVersion("0.1.0")! < AppVersion("0.1.1")!)
        #expect(AppVersion("1.0.0")! > AppVersion("0.99.99")!)
    }

    /// 자리 수가 다르면 없는 자리를 0으로 본다.
    @Test func treatsMissingPartsAsZero() {
        #expect(AppVersion("0.2")! == AppVersion("0.2")!)
        #expect(!(AppVersion("0.2")! < AppVersion("0.2.0")!))
        #expect(!(AppVersion("0.2.0")! < AppVersion("0.2")!))
        #expect(AppVersion("0.2")! < AppVersion("0.2.1")!)
    }

    @Test func acceptsTagPrefixAndRejectsGarbage() {
        #expect(AppVersion("v1.2.3")?.description == "1.2.3")
        #expect(AppVersion("") == nil)
        #expect(AppVersion("nightly") == nil)
    }
}

@Suite("UpdateChecker")
struct UpdateCheckerTests {
    private func payload(tag: String, page: String = "https://example.com/r/1") -> Data {
        Data(#"{"tag_name":"\#(tag)","html_url":"\#(page)"}"#.utf8)
    }

    @Test func reportsNewerVersion() async {
        let checker = UpdateChecker(currentVersion: "0.1.0",
                                    fetch: { self.payload(tag: "v0.2.0") })
        let update = await checker.check()
        #expect(update?.version == "0.2.0")
        #expect(update?.pageURL.absoluteString == "https://example.com/r/1")
    }

    /// 같은 버전이나 더 낮은 버전에는 알리지 않는다.
    @Test func staysQuietWhenCurrent() async {
        for tag in ["v0.1.0", "0.1.0", "v0.0.9"] {
            let checker = UpdateChecker(currentVersion: "0.1.0",
                                        fetch: { self.payload(tag: tag) })
            #expect(await checker.check() == nil, "\(tag)")
        }
    }

    /// **모르면 알리지 않는다.** 형식이 바뀌거나 못 받았을 때 새 버전이 있다고
    /// 말하면, 있지도 않은 것을 받으러 가게 만든다.
    @Test func staysQuietOnFailureOrUnknownShape() async {
        let cases: [@Sendable () async -> Data?] = [
            { nil },                                        // 네트워크 실패
            { Data("not json".utf8) },
            { Data(#"{"message":"Not Found"}"#.utf8) },      // 릴리스가 없을 때
            { Data(#"{"tag_name":"nightly"}"#.utf8) },       // 숫자가 아닌 태그
        ]
        for fetch in cases {
            let checker = UpdateChecker(currentVersion: "0.1.0", fetch: fetch)
            #expect(await checker.check() == nil)
        }
    }

    /// html_url이 없으면 릴리스 목록 페이지로 보낸다 — 링크가 비어 있으면 안 된다.
    @Test func fallsBackToReleasesPage() async {
        let checker = UpdateChecker(currentVersion: "0.1.0",
                                    fetch: { Data(#"{"tag_name":"v9.9.9"}"#.utf8) })
        #expect(await checker.check()?.pageURL == UpdateChecker.releasesPage)
    }
}
