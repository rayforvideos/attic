import Foundation

/// 로그인·부팅할 때 함께 올라오는 항목 하나. 읽기 전용이다.
public struct StartupItem: Sendable, Equatable, Identifiable {
    public enum Domain: Sendable, Equatable {
        /// `~/Library/LaunchAgents`. 이 앱이 끄고 켤 수 있다.
        case user
        /// `/Library/LaunchAgents`, `/Library/LaunchDaemons`. 관리자 권한이 있어야
        /// 바꿀 수 있어 보여주기만 한다.
        case system
    }

    /// 등록만 남고 실체가 없는 경우. 화면에 "프로그램이 없어요"라고 말했는데 실은
    /// 빈 파일이면 거짓말이 되므로 둘을 구분한다.
    public enum Leftover: Sendable, Equatable {
        /// plist가 가리키는 실행 파일이 사라졌다(앱을 지웠는데 등록만 남음).
        case programMissing(path: String)
        /// plist에 내용이 없다(지우다 만 껍데기).
        case emptyDefinition
    }

    public var id: String { plistPath }
    public let label: String
    public let plistPath: String
    public let programPath: String?
    public let domain: Domain
    public let leftover: Leftover?
}

/// 자동 실행 항목을 훑어보기만 한다. 끄고 켜는 것은 LaunchAgentManager가 사용자
/// 도메인에서만 하고, 그 안전 경계를 넓히지 않으려고 타입을 나눴다.
///
/// 시스템 도메인까지 보는 이유는 부팅할 때 조용히 올라오는 것들(백신, 보안 프로그램,
/// 업데이터)이 대부분 거기 있기 때문이다. 끄지는 못해도 무엇이 올라오는지 알고
/// 지워진 앱의 찌꺼기를 찾아내는 것은 사용자가 할 수 있는 일로 이어진다.
public struct StartupInventory: Sendable {
    let directories: [(path: String, domain: StartupItem.Domain)]

    public init(home: String = NSHomeDirectory()) {
        directories = [
            ("\(home)/Library/LaunchAgents", .user),
            ("/Library/LaunchAgents", .system),
            ("/Library/LaunchDaemons", .system),
        ]
    }

    public func scan() -> [StartupItem] {
        let fm = FileManager.default
        var items: [StartupItem] = []
        for (dir, domain) in directories {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for name in names.sorted() where name.hasSuffix(".plist") {
                // 애플 것은 시스템이 관리한다. 손댈 수도 없고 알려도 할 일이 없다.
                guard !name.hasPrefix("com.apple.") else { continue }
                let path = "\(dir)/\(name)"
                guard let item = Self.inspect(path: path, domain: domain) else { continue }
                items.append(item)
            }
        }
        return items
    }

    /// plist 하나를 읽어 상태를 판정한다. 권한이나 심볼릭 링크 때문에 못 읽으면
    /// nil이다. 모르는 것을 찌꺼기라고 말하지 않는다.
    static func inspect(path: String, domain: StartupItem.Domain) -> StartupItem? {
        guard let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil) as? [String: Any]
        else { return nil }

        let label = (plist["Label"] as? String)
            ?? (path as NSString).lastPathComponent.replacingOccurrences(of: ".plist", with: "")
        guard !label.hasPrefix("com.apple.") else { return nil }

        let program = (plist["Program"] as? String)
            ?? (plist["ProgramArguments"] as? [String])?.first

        let leftover: StartupItem.Leftover?
        if plist.isEmpty {
            leftover = .emptyDefinition
        } else if let program, !FileManager.default.fileExists(atPath: program) {
            leftover = .programMissing(path: program)
        } else {
            leftover = nil
        }
        return StartupItem(label: label, plistPath: path, programPath: program,
                           domain: domain, leftover: leftover)
    }
}
