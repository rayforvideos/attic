import Foundation

/// `0.1.0` 같은 버전. 문자열 비교로는 `0.10.0 < 0.9.0`이 되어버리므로 숫자로 견준다.
public struct AppVersion: Sendable, Equatable, Comparable, CustomStringConvertible {
    public let parts: [Int]

    /// `v0.1.0`, `0.1`, `1.2.3.4` 모두 받는다. 숫자가 아닌 조각은 버린다 —
    /// 태그 규칙이 흔들려도 앱이 조용히 잘못된 비교를 하지 않게.
    public init?(_ text: String) {
        let trimmed = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let numbers = trimmed.split(separator: ".").compactMap { Int($0) }
        guard !numbers.isEmpty else { return nil }
        parts = numbers
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for index in 0..<max(lhs.parts.count, rhs.parts.count) {
            // 없는 자리는 0으로 본다: 0.2 == 0.2.0
            let left = index < lhs.parts.count ? lhs.parts[index] : 0
            let right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

public struct AvailableUpdate: Sendable, Equatable {
    public let version: String
    public let pageURL: URL
    /// DMG 자산의 직접 링크. 없으면 앱 안에서 교체할 수 없어 페이지를 열어준다.
    public let downloadURL: URL?
}

/// 새 버전이 나왔는지 확인한다. 받아서 교체하는 일은 `Updater`가 한다 —
/// 여기서는 **무엇이 최신인지만** 알아낸다.
///
/// **이 앱이 네트워크를 쓰는 유일한 곳이다.** 보내는 것은 아무것도 없다:
/// 식별자·사용 기록·경로 모두 담지 않는 평범한 GET 하나다. 설정에서 끌 수 있다.
public struct UpdateChecker: Sendable {
    /// GitHub Releases API. 별도 버전 파일을 두지 않는다 — 릴리스를 올리는 것이
    /// 곧 배포이므로, 사람이 잊고 갱신하지 않을 자리를 만들지 않는다.
    public static let releasesEndpoint =
        URL(string: "https://api.github.com/repos/rayforvideos/attic/releases/latest")!
    public static let releasesPage =
        URL(string: "https://github.com/rayforvideos/attic/releases/latest")!

    let currentVersion: String
    /// 테스트가 네트워크를 타지 않도록 주입한다.
    let fetch: @Sendable () async -> Data?

    public init(currentVersion: String,
                fetch: (@Sendable () async -> Data?)? = nil) {
        self.currentVersion = currentVersion
        self.fetch = fetch ?? {
            var request = URLRequest(url: UpdateChecker.releasesEndpoint)
            request.timeoutInterval = 10
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            // 실패는 조용히 넘긴다 — 업데이트 확인이 안 되는 것은 사용자가 지금
            // 하려는 일(공간 정리)과 무관하다.
            return try? await URLSession.shared.data(for: request).0
        }
    }

    /// 새 버전이 있으면 그 정보를, 최신이거나 확인하지 못했으면 nil.
    public func check() async -> AvailableUpdate? {
        guard let data = await fetch() else { return nil }
        return Self.parse(data, currentVersion: currentVersion)
    }

    /// 응답에서 태그를 읽어 지금 버전과 견준다. 파싱 실패·형식 변경은 nil이다 —
    /// **모르면 알리지 않는다.** 있지도 않은 새 버전을 권하면 신뢰를 잃는다.
    static func parse(_ data: Data, currentVersion: String) -> AvailableUpdate? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let latest = AppVersion(tag),
              let current = AppVersion(currentVersion),
              current < latest
        else { return nil }
        let page = (json["html_url"] as? String).flatMap(URL.init(string:))
            ?? releasesPage
        // .dmg 자산이 있으면 앱 안에서 받아 교체할 수 있다.
        let dmg = (json["assets"] as? [[String: Any]])?
            .compactMap { $0["browser_download_url"] as? String }
            .first { $0.hasSuffix(".dmg") }
            .flatMap(URL.init(string:))
        return AvailableUpdate(version: latest.description, pageURL: page, downloadURL: dmg)
    }
}
