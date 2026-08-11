import Foundation
import os

private let logger = os.Logger(subsystem: "com.sangjunpark.attic", category: "launch-agents")

/// 사용자 도메인(`~/Library/LaunchAgents`)의 상주 에이전트 하나.
public struct LaunchAgent: Sendable, Equatable, Identifiable {
    public var id: String { label }
    public let label: String
    public let plistPath: String
    public let programName: String?
    /// launchd에 "다시 로드하지 말 것"으로 기록됨. 재로그인에도 유지된다.
    public let isDisabled: Bool
    public let isLoaded: Bool
}

/// 상주 에이전트 관리. launchctl disable/bootout으로 내리고 enable/bootstrap으로
/// 되돌린다.
///
/// 안전 경계:
/// - 사용자 도메인만 다룬다. `~/Library/LaunchAgents`의 plist와 `gui/<uid>` 타깃뿐이고
///   /Library·/System/Library는 나열조차 하지 않는다.
/// - `com.apple.*` 라벨은 사용자 디렉터리에 있어도 방어적으로 제외한다.
/// - rc=0을 성공 증거로 쓰지 않고 상태를 재조회한다. 진실 소스는 launchd
///   자신(`print-disabled`/`print`)이며 앱은 따로 기록하지 않는다.
public struct LaunchAgentManager: Sendable {
    let agentsDirectory: String
    let domainTarget: String

    public init(agentsDirectory: String =
                    "\(NSHomeDirectory())/Library/LaunchAgents",
                uid: uid_t = getuid()) {
        self.agentsDirectory = agentsDirectory
        self.domainTarget = "gui/\(uid)"
    }

    // MARK: - 파싱 (순수 함수 — 테스트 대상)

    /// `launchctl print-disabled gui/UID` 출력에서 라벨별 disabled 여부를 뽑는다.
    public static func parseDisabled(from output: String) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let open = line.firstIndex(of: "\""),
                  let close = line.lastIndex(of: "\""), open < close,
                  let arrow = line.range(of: "=>") else { continue }
            let label = String(line[line.index(after: open)..<close])
            // `=>` 뒤 토큰만 본다. 접미사 문자열에 의존하면 OS가 포맷을 바꿨을 때
            // 맵이 통째로 비어 모든 에이전트가 "켜짐"으로 보인다.
            let verdict = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
                .lowercased()
            switch verdict {
            case "disabled", "true", "1": result[label] = true
            case "enabled", "false", "0": result[label] = false
            default: continue      // 모르는 형식은 판정하지 않는다
            }
        }
        return result
    }

    /// plist에서 Label과 실행 파일 이름을 뽑는다. 깨진 plist는 launchd도 무시하므로
    /// nil로 두어 목록에서 뺀다.
    public static func parsePlist(data: Data) -> (label: String, program: String?, disabledInPlist: Bool)? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any],
              let label = dict["Label"] as? String else { return nil }
        let path = (dict["Program"] as? String)
            ?? (dict["ProgramArguments"] as? [Any])?.first as? String
        // plist 자체의 Disabled 키도 상태의 일부다. launchd override와 별개로 이
        // 값이 true면 사용자 눈에는 꺼짐이어야 한다.
        let disabled = (dict["Disabled"] as? Bool) ?? false
        return (label, path.map { ($0 as NSString).lastPathComponent }, disabled)
    }

    // MARK: - 나열

    /// 테스트 가능한 코어: launchctl 결과를 주입받는다.
    func list(disabledMap: [String: Bool], isLoaded: (String) -> Bool) -> [LaunchAgent] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: agentsDirectory) else { return [] }
        return entries
            .filter { $0.hasSuffix(".plist") }
            .sorted()
            .compactMap { name -> LaunchAgent? in
                let path = "\(agentsDirectory)/\(name)"
                guard let data = fm.contents(atPath: path),
                      let parsed = Self.parsePlist(data: data) else { return nil }
                // Apple 것은 사용자 디렉터리에 있어도 건드리지 않는다.
                guard !parsed.label.hasPrefix("com.apple.") else { return nil }
                return LaunchAgent(label: parsed.label,
                                   plistPath: path,
                                   programName: parsed.program,
                                   isDisabled: disabledMap[parsed.label] ?? parsed.disabledInPlist,
                                   isLoaded: isLoaded(parsed.label))
            }
    }

    public func list() -> [LaunchAgent] {
        let disabled = Self.parseDisabled(from: run(["print-disabled", domainTarget]).output)
        // 에이전트마다 서브프로세스를 띄우면 목록 하나에 수십 번 fork하므로
        // 도메인 전체를 한 번 덤프해 그 안에서 찾는다.
        let domainDump = run(["print", domainTarget]).output
        return list(disabledMap: disabled,
                    isLoaded: { domainDump.contains($0) })
    }

    // MARK: - 끄기 / 켜기

    /// 끈다. bootout으로 지금 내리고 disable로 재로그인에도 안 올라오게 한다.
    /// 성공 판정은 rc가 아니라 상태 재조회로 한다.
    public func disable(_ agent: LaunchAgent) -> Bool {
        _ = run(["bootout", "\(domainTarget)/\(agent.label)"])   // 이미 내려가 있으면 실패해도 무방
        _ = run(["disable", "\(domainTarget)/\(agent.label)"])
        let probe = run(["print-disabled", domainTarget])
        guard probe.status == 0 else { return false }
        let disabled = Self.parseDisabled(from: probe.output)
        let stillLoaded = run(["print", "\(domainTarget)/\(agent.label)"]).status == 0
        return disabled[agent.label] == true && !stillLoaded
    }

    /// 켠다. enable 후 bootstrap으로 plist에서 다시 로드한다.
    public func enable(_ agent: LaunchAgent) -> Bool {
        _ = run(["enable", "\(domainTarget)/\(agent.label)"])
        _ = run(["bootstrap", domainTarget, agent.plistPath])
        // fail-closed. print-disabled가 실패하면 맵이 비어 `!= true`가 그것을
        // "켜졌다"로 읽으므로, 확인할 수 없으면 실패로 본다.
        let probe = run(["print-disabled", domainTarget])
        guard probe.status == 0 else { return false }
        let disabled = Self.parseDisabled(from: probe.output)
        // RunAtLoad가 없는 에이전트는 bootstrap 후에도 실행 중이 아닐 수 있어 로드
        // 여부는 성공 조건에 넣지 않는다. 라벨이 맵에 없으면 조회가 온전하지 않았다는
        // 뜻이므로 실패다.
        guard let stillDisabled = disabled[agent.label] else { return false }
        return !stillDisabled
    }

    private func run(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        } catch {
            logger.error("launchctl \(arguments.joined(separator: " "), privacy: .public) 실행 실패: \(error, privacy: .public)")
            return (-1, "")
        }
    }
}
