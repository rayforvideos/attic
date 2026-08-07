import Testing
import Foundation
@testable import AtticCore

@Suite("Updater — 서명 검증")
struct UpdaterVerificationTests {
    /// 실제 `codesign -dvv` 출력 형태(이 맥에서 뽑은 것).
    private let ourSigning = """
    Executable=/Applications/Attic.app/Contents/MacOS/Attic
    Identifier=com.sangjunpark.attic
    Authority=Developer ID Application: sangjun pakr (5XDWSJ2JK7)
    Authority=Developer ID Certification Authority
    Authority=Apple Root CA
    TeamIdentifier=5XDWSJ2JK7
    Timestamp=Aug 8, 2026 at 12:14:00 AM
    """

    @Test func readsTeamIdentifier() {
        #expect(Updater.teamID(fromCodesign: ourSigning) == "5XDWSJ2JK7")
        #expect(Updater.teamID(fromCodesign: "TeamIdentifier=not set") == nil)
        #expect(Updater.teamID(fromCodesign: "Identifier=x") == nil)
    }

    @Test func acceptsOnlyDeveloperIDSignatures() {
        #expect(Updater.isDeveloperIDSigned(ourSigning))
        // 개발용 서명은 배포본이 아니다
        #expect(!Updater.isDeveloperIDSigned("Authority=Apple Development: 상준 박 (9XD2ZBAP64)"))
        // 애드혹 서명
        #expect(!Updater.isDeveloperIDSigned("Signature=adhoc"))
    }

    /// 공증되지 않았거나 다른 출처면 거부한다.
    @Test func requiresNotarizedVerdict() {
        #expect(Updater.isNotarized("""
        /Applications/Attic.app: accepted
        source=Notarized Developer ID
        """))
        #expect(!Updater.isNotarized("""
        /Applications/Attic.app: accepted
        source=Developer ID
        """), "공증 없이 서명만 된 것은 거부")
        #expect(!Updater.isNotarized("/Applications/Attic.app: rejected"))
        #expect(!Updater.isNotarized(""))
    }
}

@Suite("Updater — 거부 경로")
struct UpdaterRejectionTests {
    private func updater(codesign: String, spctl: String, version: String = "0.9.0",
                         app: URL) -> Updater {
        Updater(bundleURL: URL(fileURLWithPath: "/tmp/does-not-matter.app"),
                currentVersion: version) { arguments in
            if arguments[0].hasSuffix("codesign") { return (0, codesign) }
            if arguments[0].hasSuffix("spctl") { return (0, spctl) }
            return (0, "")
        }
    }

    /// Info.plist가 있는 가짜 앱 번들.
    private func fakeApp(version: String) throws -> URL {
        let app = FileManager.default.temporaryDirectory
            .appending(path: "Fake-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: app.appending(path: "Contents"),
                                                withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleShortVersionString": version], format: .xml, options: 0)
        try data.write(to: app.appending(path: "Contents/Info.plist"))
        return app
    }

    /// **다른 개발자의 서명이면 절대 설치하지 않는다.** 통신이 가로채여도 공격자는
    /// 우리 서명을 만들 수 없다는 것이 이 업데이터의 유일한 안전 근거다.
    @Test func refusesOtherDevelopersSignature() throws {
        let app = try fakeApp(version: "9.9.9")
        defer { try? FileManager.default.removeItem(at: app) }
        let u = updater(codesign: """
        Authority=Developer ID Application: Someone Else (AAAA111111)
        TeamIdentifier=AAAA111111
        """, spctl: "accepted\nsource=Notarized Developer ID", app: app)
        #expect(throws: Updater.Failure.signatureMismatch(L("다른 개발자의 서명이에요 (%@)", "AAAA111111"))) {
            try u.verify(app)
        }
    }

    @Test func refusesUnnotarizedBuild() throws {
        let app = try fakeApp(version: "9.9.9")
        defer { try? FileManager.default.removeItem(at: app) }
        let u = updater(codesign: """
        Authority=Developer ID Application: sangjun pakr (5XDWSJ2JK7)
        TeamIdentifier=5XDWSJ2JK7
        """, spctl: "accepted\nsource=Developer ID", app: app)
        #expect(throws: Updater.Failure.notNotarized(L("공증을 확인할 수 없어요"))) {
            try u.verify(app)
        }
    }

    /// 낮은 버전으로 되돌리는 것도 업데이트가 아니다.
    @Test func refusesOlderOrSameVersion() throws {
        let app = try fakeApp(version: "0.1.0")
        defer { try? FileManager.default.removeItem(at: app) }
        let u = updater(codesign: """
        Authority=Developer ID Application: sangjun pakr (5XDWSJ2JK7)
        TeamIdentifier=5XDWSJ2JK7
        """, spctl: "accepted\nsource=Notarized Developer ID", version: "0.2.0", app: app)
        #expect(throws: Updater.Failure.notNewer(L("더 새 버전이 아니에요"))) {
            try u.verify(app)
        }
    }

    @Test func acceptsOurNotarizedNewerBuild() throws {
        let app = try fakeApp(version: "0.3.0")
        defer { try? FileManager.default.removeItem(at: app) }
        let u = updater(codesign: """
        Authority=Developer ID Application: sangjun pakr (5XDWSJ2JK7)
        TeamIdentifier=5XDWSJ2JK7
        """, spctl: "accepted\nsource=Notarized Developer ID", version: "0.2.0", app: app)
        try u.verify(app)   // 던지지 않아야 한다
    }
}
