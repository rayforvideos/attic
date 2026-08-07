import Foundation
import os

private let logger = os.Logger(subsystem: "com.sangjunpark.attic", category: "updater")

/// 새 버전을 내려받아 교체한다.
///
/// **이 앱은 전체 디스크 접근을 요구한다.** 그런 앱이 자기 자신을 바꾸는 경로를
/// 만드는 것은 위험한 일이므로, 교체 전에 반드시 두 가지를 확인한다:
///
/// 1. **팀 ID 고정** — 내려받은 앱이 우리 Developer ID(`5XDWSJ2JK7`)로 서명돼
///    있는가. 통신이 가로채여도 공격자는 이 서명을 만들 수 없다.
/// 2. **공증 확인** — Gatekeeper가 실행을 허락하는가(`spctl -a -t exec`).
///
/// 둘 중 하나라도 아니면 **교체하지 않고 실패로 끝낸다.** 확인할 수 없는 것을
/// 설치하지 않는다.
///
/// 옛 버전은 지우지 않고 **휴지통으로 보낸다** — 이 앱이 사용자 파일에 하는 것과
/// 같은 약속이다. 새 버전이 문제가 있으면 되돌릴 수 있어야 한다.
public struct Updater: Sendable {
    /// 우리 Developer ID 팀. 서명 확인의 기준이라 상수로 못 박는다.
    public static let teamID = "5XDWSJ2JK7"

    public enum Failure: Error, Equatable {
        case downloadFailed
        case mountFailed
        case appNotFoundInImage
        /// 서명이 우리 것이 아니다 — 가장 중요한 거부다.
        case signatureMismatch(String)
        case notNotarized(String)
        case notNewer(String)
        case replaceFailed(String)
    }

    let bundleURL: URL
    let currentVersion: String
    let run: @Sendable ([String]) -> (status: Int32, output: String)

    public init(bundleURL: URL = Bundle.main.bundleURL,
                currentVersion: String = (Bundle.main
                    .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0",
                run: (@Sendable ([String]) -> (status: Int32, output: String))? = nil) {
        self.bundleURL = bundleURL
        self.currentVersion = currentVersion
        self.run = run ?? Updater.execute
    }

    // MARK: - 검증 (순수 로직 — 테스트 대상)

    /// `codesign -dvv` 출력에서 팀 ID를 뽑는다. 없으면 nil.
    static func teamID(fromCodesign output: String) -> String? {
        for line in output.split(separator: "\n") {
            guard line.hasPrefix("TeamIdentifier=") else { continue }
            let value = line.dropFirst("TeamIdentifier=".count).trimmingCharacters(in: .whitespaces)
            return value == "not set" ? nil : value
        }
        return nil
    }

    /// `codesign -dvv` 출력이 Developer ID로 서명된 것인지. 개발용(Apple
    /// Development) 서명은 배포본이 아니므로 거부한다.
    static func isDeveloperIDSigned(_ output: String) -> Bool {
        output.split(separator: "\n").contains { $0.hasPrefix("Authority=Developer ID Application:") }
    }

    /// `spctl -a -vvv -t exec` 출력이 공증된 Developer ID를 인정하는지.
    static func isNotarized(_ output: String) -> Bool {
        output.contains("accepted") && output.contains("Notarized Developer ID")
    }

    // MARK: - 설치

    /// DMG를 내려받아 검증하고 교체한다. 성공하면 새 앱 번들 경로를 돌려준다.
    public func install(from dmgURL: URL,
                        progress: (@Sendable (String) -> Void)? = nil) async throws -> URL {
        progress?("받는 중")
        let downloaded = try await download(dmgURL)
        defer { try? FileManager.default.removeItem(at: downloaded) }

        progress?("확인 중")
        let mountPoint = FileManager.default.temporaryDirectory
            .appending(path: "attic-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        let attach = run(["/usr/bin/hdiutil", "attach", "-nobrowse", "-readonly",
                          "-mountpoint", mountPoint.path, downloaded.path])
        guard attach.status == 0 else { throw Failure.mountFailed }
        defer {
            _ = run(["/usr/bin/hdiutil", "detach", mountPoint.path, "-force"])
            try? FileManager.default.removeItem(at: mountPoint)
        }

        guard let newApp = (try? FileManager.default
            .contentsOfDirectory(atPath: mountPoint.path))?
            .first(where: { $0.hasSuffix(".app") })
            .map({ mountPoint.appending(path: $0) })
        else { throw Failure.appNotFoundInImage }

        try verify(newApp)
        progress?("설치 중")
        try replace(with: newApp)
        return bundleURL
    }

    /// 서명·공증·버전을 모두 확인한다. **하나라도 아니면 던진다.**
    func verify(_ app: URL) throws {
        let signing = run(["/usr/bin/codesign", "-dvv", app.path])
        let output = signing.output
        guard signing.status == 0, Self.isDeveloperIDSigned(output) else {
            throw Failure.signatureMismatch(L("Developer ID 서명이 아니에요"))
        }
        guard let team = Self.teamID(fromCodesign: output) else {
            throw Failure.signatureMismatch(L("서명에 팀 정보가 없어요"))
        }
        guard team == Self.teamID else {
            throw Failure.signatureMismatch(L("다른 개발자의 서명이에요 (%@)", team))
        }
        let gatekeeper = run(["/usr/sbin/spctl", "-a", "-vvv", "-t", "exec", app.path])
        guard Self.isNotarized(gatekeeper.output) else {
            throw Failure.notNotarized(L("공증을 확인할 수 없어요"))
        }
        // 버전까지 확인한다 — 낮은 버전으로 되돌리는 것도 업데이트가 아니다.
        let plist = app.appending(path: "Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any],
              let version = info["CFBundleShortVersionString"] as? String,
              let new = AppVersion(version), let old = AppVersion(currentVersion),
              old < new
        else { throw Failure.notNewer(L("더 새 버전이 아니에요")) }
        logger.info("update verified: team \(team, privacy: .public) version \(version, privacy: .public)")
    }

    /// 지금 앱을 휴지통으로 보내고 새 것을 그 자리에 놓는다. 지우지 않는 이유는
    /// 이 앱이 사용자 파일에 하는 약속과 같다 — 되돌릴 수 있어야 한다.
    private func replace(with newApp: URL) throws {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: bundleURL.path) {
                try fm.trashItem(at: bundleURL, resultingItemURL: nil)
            }
            try fm.copyItem(at: newApp, to: bundleURL)
        } catch {
            throw Failure.replaceFailed(error.localizedDescription)
        }
    }

    private func download(_ url: URL) async throws -> URL {
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        guard let (temp, response) = try? await URLSession.shared.download(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { throw Failure.downloadFailed }
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "attic-update-\(UUID().uuidString).dmg")
        try? FileManager.default.moveItem(at: temp, to: destination)
        return destination
    }

    static let execute: @Sendable ([String]) -> (status: Int32, output: String) = { arguments in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
