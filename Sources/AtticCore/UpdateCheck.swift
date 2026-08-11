import Foundation

/// `0.1.0` 같은 버전. 문자열 비교로는 `0.10.0 < 0.9.0`이 되어버리므로 숫자로 견준다.
public struct AppVersion: Sendable, Equatable, Comparable, CustomStringConvertible {
    public let parts: [Int]

    /// `v0.1.0`, `0.1`, `1.2.3.4`를 모두 받고 숫자가 아닌 조각은 버린다. 태그 규칙이
    /// 흔들려도 앱이 조용히 잘못된 비교를 하지 않게 하려는 것이다.
    public init?(_ text: String) {
        let trimmed = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let numbers = trimmed.split(separator: ".").compactMap { Int($0) }
        guard !numbers.isEmpty else { return nil }
        parts = numbers
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for index in 0..<max(lhs.parts.count, rhs.parts.count) {
            // 없는 자리는 0으로 본다. 0.2와 0.2.0은 같다.
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

/// 새 버전이 나왔는지만 확인한다. 받아서 교체하는 일은 `Updater`가 한다.
///
/// 이 앱이 네트워크를 쓰는 유일한 곳이다. 식별자도 사용 기록도 경로도 담지 않는
/// GET 하나이고 설정에서 끌 수 있다.
public struct UpdateChecker: Sendable {
    /// GitHub Releases API. 별도 버전 파일을 두면 사람이 잊고 갱신하지 않을 자리가
    /// 생기므로 릴리스 자체를 기준으로 삼는다.
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
            // 실패는 조용히 넘긴다. 업데이트 확인은 사용자가 지금 하려는 일과 무관하다.
            return try? await URLSession.shared.data(for: request).0
        }
    }

    /// 새 버전이 있으면 그 정보를, 최신이거나 확인하지 못했으면 nil.
    public func check() async -> AvailableUpdate? {
        guard let data = await fetch() else { return nil }
        return Self.parse(data, currentVersion: currentVersion)
    }

    /// 응답의 태그를 지금 버전과 견준다. 파싱 실패나 형식 변경은 nil이다. 있지도 않은
    /// 새 버전을 권하지 않는다.
    static func parse(_ data: Data, currentVersion: String) -> AvailableUpdate? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let latest = AppVersion(tag),
              let current = AppVersion(currentVersion),
              current < latest
        else { return nil }
        let page = (json["html_url"] as? String).flatMap(URL.init(string:))
            ?? releasesPage
        let dmg = (json["assets"] as? [[String: Any]])?
            .compactMap { $0["browser_download_url"] as? String }
            .first { $0.hasSuffix(".dmg") }
            .flatMap(URL.init(string:))
        return AvailableUpdate(version: latest.description, pageURL: page, downloadURL: dmg)
    }
}
