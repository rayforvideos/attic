import Foundation

/// "지금 쓰이는 중"인 후보를 가려내는 판정. 실행 중인 앱의 캐시나 살아 있는
/// 프로세스가 물고 있는 node_modules를 옮기면 두 가지가 잘못된다: Finder로
/// 휴지통을 비울 때 "사용 중" 경고에 막히고, 앱은 열린 핸들로 **휴지통 안의**
/// 폴더에 계속 써서 옮긴 캐시가 그 안에서 다시 자란다(실사용 보고).
///
/// 판정은 프로세스 목록의 메타데이터(실행 경로·작업 디렉터리)로만 한다 —
/// 열린 파일 목록(lsof)은 node_modules 하나에도 수만 파일이라 스캔마다 돌리기엔
/// 너무 느리다. 그래서 이 판정은 완전하지 않다: 놓친 항목은 예전처럼 목록에
/// 뜨고, 비울 때 "사용 중"을 만날 수 있다. 잘못 거르는 쪽(멀쩡한 후보 숨김)은
/// 여기 규칙이 좁아서 일어나지 않는다.
public struct ReclaimInUse: Sendable {
    /// 실행 중 .app 번들 이름(확장자 없이, 소문자).
    let appNames: Set<String>
    /// 실행 중 .app 번들의 CFBundleIdentifier(소문자).
    let bundleIDs: Set<String>
    let cwds: [String]
    let execPaths: [String]

    init(appNames: Set<String>, bundleIDs: Set<String>,
         cwds: [String], execPaths: [String]) {
        self.appNames = appNames
        self.bundleIDs = bundleIDs
        self.cwds = cwds
        self.execPaths = execPaths
    }

    public init(samples: [ProcessSample]) {
        var appNames: Set<String> = []
        var bundlePaths: Set<String> = []
        var cwds: [String] = []
        var execPaths: [String] = []

        for sample in samples {
            if let cwd = sample.cwd { cwds.append(cwd) }
            if !sample.execPath.isEmpty { execPaths.append(sample.execPath) }
            if let bundle = Self.appBundlePath(ofExecutable: sample.execPath) {
                bundlePaths.insert(bundle)
                let name = ((bundle as NSString).lastPathComponent as NSString)
                    .deletingPathExtension
                appNames.insert(name.lowercased())
            }
        }

        // 같은 번들에서 여러 프로세스(헬퍼들)가 떠 있으니 번들당 한 번만 읽는다.
        var bundleIDs: Set<String> = []
        for path in bundlePaths {
            if let id = Bundle(path: path)?.bundleIdentifier {
                bundleIDs.insert(id.lowercased())
            }
        }

        self.init(appNames: appNames, bundleIDs: bundleIDs,
                  cwds: cwds, execPaths: execPaths)
    }

    /// `path` 후보가 지금 쓰이는 중인가. 실행 중 여부가 의미 있는 종류에만
    /// 반응한다 — 다른 종류는 항상 false다(빌드 캐시는 Xcode가 떠 있어도
    /// 지워서 안전하고, 이 판정이 번지면 스캔 결과가 통째로 사라질 수 있다).
    public func isInUse(path: String, kind: ReclaimKind, home: String) -> Bool {
        switch kind {
        case .nodeModules:
            let project = (path as NSString).deletingLastPathComponent
            if cwds.contains(where: { Self.isUnder($0, root: project) }) { return true }
            return execPaths.contains { Self.isUnder($0, root: project) }
        case .electronCache:
            let support = "\(home)/Library/Application Support/"
            guard path.hasPrefix(support) else { return false }
            let appFolder = String(path.dropFirst(support.count))
                .split(separator: "/").first.map(String.init) ?? ""
            return matchesRunningApp(appFolder)
        case .libraryCache:
            let caches = "\(home)/Library/Caches/"
            if path.hasPrefix(caches) {
                let name = String(path.dropFirst(caches.count))
                    .split(separator: "/").first.map(String.init) ?? ""
                return matchesRunningApp(name)
            }
            let containers = "\(home)/Library/Containers/"
            if path.hasPrefix(containers) {
                let bundleID = String(path.dropFirst(containers.count))
                    .split(separator: "/").first.map(String.init) ?? ""
                return bundleIDs.contains(bundleID.lowercased())
            }
            return false
        default:
            return false
        }
    }

    /// 캐시 폴더 이름이 실행 중인 앱을 가리키는가. 이름은 앱 이름("Slack",
    /// "Spotify")일 수도, 번들ID("com.tinyspeck.slackmacgap")일 수도 있어
    /// 양쪽에 다 물어본다.
    private func matchesRunningApp(_ name: String) -> Bool {
        let lower = name.lowercased()
        return appNames.contains(lower) || bundleIDs.contains(lower)
    }

    /// 실행 파일 경로에서 .app 번들 경로를 뽑는다. 번들 밖 실행 파일(CLI)은 nil.
    static func appBundlePath(ofExecutable path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    /// 경로 컴포넌트 단위 포함 검사. 단순 hasPrefix는 "shop-backup"을
    /// "shop" 아래로 오인한다.
    static func isUnder(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }
}
