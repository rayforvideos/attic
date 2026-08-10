import Foundation

/// "지금 쓰이는 중"인 후보를 가려내는 판정. 실행 중인 앱의 캐시나 살아 있는
/// 프로세스가 물고 있는 node_modules를 옮기면 두 가지가 잘못된다: Finder로
/// 휴지통을 비울 때 "사용 중" 경고에 막히고, 앱은 열린 핸들로 **휴지통 안의**
/// 폴더에 계속 써서 옮긴 캐시가 그 안에서 다시 자란다(실사용 보고).
///
/// 판정은 불리언이 아니라 **누가 쓰는지 이름**을 돌려준다. "사용 중이에요"라고만
/// 하면 사용자가 무엇을 꺼야 할지 알 수 없다 — 끄고 말고는 이름을 보고 사용자가
/// 정한다.
///
/// 판정은 프로세스 목록의 메타데이터(실행 경로·작업 디렉터리)로만 한다 —
/// 열린 파일 목록(lsof)은 node_modules 하나에도 수만 파일이라 스캔마다 돌리기엔
/// 너무 느리다. 그래서 이 판정은 완전하지 않다: 놓친 항목은 예전처럼 목록에
/// 뜨고, 비울 때 "사용 중"을 만날 수 있다. 잘못 거르는 쪽(멀쩡한 후보 숨김)은
/// 여기 규칙이 좁아서 일어나지 않는다.
public struct ReclaimInUse: Sendable {
    /// 판정에 필요한 만큼만 남긴 프로세스 한 줄.
    struct Proc: Sendable {
        let name: String        // 사용자에게 보여줄 이름 (앱 이름 또는 실행 파일 이름)
        let cwd: String?
        let execPath: String
    }

    /// 실행 중 .app 번들: 소문자 이름 → 보여줄 이름.
    let apps: [String: String]
    /// 실행 중 .app 번들: 소문자 CFBundleIdentifier → 보여줄 앱 이름.
    let bundleIDs: [String: String]
    let procs: [Proc]

    init(apps: [String: String], bundleIDs: [String: String], procs: [Proc]) {
        self.apps = apps
        self.bundleIDs = bundleIDs
        self.procs = procs
    }

    public init(samples: [ProcessSample]) {
        var apps: [String: String] = [:]
        var bundlePathsByName: [String: String] = [:]   // 번들 경로 → 보여줄 이름
        var procs: [Proc] = []

        for sample in samples {
            let bundle = Self.appBundlePath(ofExecutable: sample.execPath)
            let appName = bundle.map {
                (($0 as NSString).lastPathComponent as NSString).deletingPathExtension
            }
            // 이름 없는 프로세스는 판정에 못 쓴다 — "누가"를 말할 수 없으면
            // 후보를 숨기지 않는 쪽(현상 유지)이 맞다.
            let name = appName
                ?? (sample.execPath.isEmpty ? nil
                    : (sample.execPath as NSString).lastPathComponent)
                ?? sample.argv.first.map { ($0 as NSString).lastPathComponent }
            guard let name, !name.isEmpty else { continue }

            procs.append(Proc(name: name, cwd: sample.cwd, execPath: sample.execPath))
            if let appName, let bundle {
                apps[appName.lowercased()] = appName
                bundlePathsByName[bundle] = appName
            }
        }

        // 같은 번들에서 여러 프로세스(헬퍼들)가 떠 있으니 번들당 한 번만 읽는다.
        var bundleIDs: [String: String] = [:]
        for (path, appName) in bundlePathsByName {
            if let id = Bundle(path: path)?.bundleIdentifier {
                bundleIDs[id.lowercased()] = appName
            }
        }

        self.init(apps: apps, bundleIDs: bundleIDs, procs: procs)
    }

    /// `path` 후보를 지금 쓰고 있는 앱·프로세스의 이름. nil이면 자유다.
    /// 실행 중 여부가 의미 있는 종류에만 반응한다 — 다른 종류는 항상 nil이다
    /// (빌드 캐시는 Xcode가 떠 있어도 지워서 안전하고, 이 판정이 번지면 스캔
    /// 결과가 통째로 사라질 수 있다).
    public func culprit(path: String, kind: ReclaimKind, home: String) -> String? {
        switch kind {
        case .nodeModules:
            let project = (path as NSString).deletingLastPathComponent
            return procs.first {
                if let cwd = $0.cwd, Self.isUnder(cwd, root: project) { return true }
                return Self.isUnder($0.execPath, root: project)
            }?.name
        case .electronCache:
            let support = "\(home)/Library/Application Support/"
            guard path.hasPrefix(support) else { return nil }
            let appFolder = String(path.dropFirst(support.count))
                .split(separator: "/").first.map(String.init) ?? ""
            return runningApp(named: appFolder)
        case .libraryCache:
            let caches = "\(home)/Library/Caches/"
            if path.hasPrefix(caches) {
                let name = String(path.dropFirst(caches.count))
                    .split(separator: "/").first.map(String.init) ?? ""
                return runningApp(named: name)
            }
            let containers = "\(home)/Library/Containers/"
            if path.hasPrefix(containers) {
                let bundleID = String(path.dropFirst(containers.count))
                    .split(separator: "/").first.map(String.init) ?? ""
                return bundleIDs[bundleID.lowercased()]
            }
            return nil
        default:
            return nil
        }
    }

    /// 캐시 폴더 이름이 가리키는 실행 중인 앱. 이름은 앱 이름("Slack",
    /// "Spotify")일 수도, 번들ID("com.tinyspeck.slackmacgap")일 수도 있어
    /// 양쪽에 다 물어본다.
    private func runningApp(named name: String) -> String? {
        let lower = name.lowercased()
        return apps[lower] ?? bundleIDs[lower]
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
