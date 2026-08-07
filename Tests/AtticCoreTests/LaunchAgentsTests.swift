import Testing
import Foundation
@testable import AtticCore

@Suite("LaunchAgents")
struct LaunchAgentsTests {
    /// launchctl print-disabled gui/UID 실측 출력 포맷 그대로.
    @Test func parsesDisabledList() {
        let output = """
        	disabled services = {
        		"com.google.keystone.user.xpcservice" => enabled
        		"com.apple.Siri.agent" => enabled
        		"com.apple.ManagedClientAgent.enrollagent" => disabled
        		"com.example.helper" => disabled
        	}
        """
        let map = LaunchAgentManager.parseDisabled(from: output)
        #expect(map["com.example.helper"] == true)
        #expect(map["com.google.keystone.user.xpcservice"] == false)
        #expect(map["com.apple.ManagedClientAgent.enrollagent"] == true)
        #expect(map["없는라벨"] == nil)
    }

    @Test func parsesPlistLabelAndProgram() throws {
        let plist: [String: Any] = [
            "Label": "com.example.updater",
            "ProgramArguments": ["/Applications/Example.app/Contents/MacOS/updater", "--wake"],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let parsed = try #require(LaunchAgentManager.parsePlist(data: data))
        #expect(parsed.label == "com.example.updater")
        #expect(parsed.program == "updater")

        let programOnly: [String: Any] = ["Label": "com.example.svc", "Program": "/usr/local/bin/svc"]
        let data2 = try PropertyListSerialization.data(fromPropertyList: programOnly, format: .xml, options: 0)
        #expect(LaunchAgentManager.parsePlist(data: data2)?.program == "svc")
    }

    /// 사용자 도메인 디렉토리의 plist만 나열하고, Apple 라벨은 방어적으로 뺀다.
    @Test func listsUserAgentsExcludingApple() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "agents-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        func write(_ name: String, label: String) throws {
            let plist: [String: Any] = ["Label": label, "Program": "/usr/bin/true"]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: dir.appending(path: name))
        }
        try write("a.plist", label: "com.example.one")
        try write("b.plist", label: "com.apple.something")   // 제외돼야 함
        try Data("깨진 파일".utf8).write(to: dir.appending(path: "broken.plist"))

        let manager = LaunchAgentManager(agentsDirectory: dir.path)
        let agents = manager.list(disabledMap: ["com.example.one": true],
                                  isLoaded: { _ in false })
        #expect(agents.map(\.label) == ["com.example.one"])
        #expect(agents.first?.isDisabled == true)
        #expect(agents.first?.isLoaded == false)
    }
}

@Suite("LaunchAgents 파서 견고성")
struct LaunchAgentsParserRobustnessTests {
    /// OS가 포맷을 바꿔도(=> true/false) 맵이 통째로 비지 않아야 한다 — 비면
    /// 모든 에이전트가 "켜짐"으로 보이고 끄기가 성공해도 실패라고 말한다.
    @Test func parsesAlternateVerdictTokens() {
        let output = """
        \tdisabled services = {
        \t\t"com.example.a" => true
        \t\t"com.example.b" => false
        \t\t"com.example.c" => 1
        \t\t"com.example.d" => 0
        \t\t"com.example.e" => 낯선값
        \t}
        """
        let map = LaunchAgentManager.parseDisabled(from: output)
        #expect(map["com.example.a"] == true)
        #expect(map["com.example.b"] == false)
        #expect(map["com.example.c"] == true)
        #expect(map["com.example.d"] == false)
        // 모르는 형식은 판정하지 않는다(추측하지 않는다)
        #expect(map["com.example.e"] == nil)
    }

    /// plist 자체의 Disabled 키도 상태의 일부다.
    @Test func honorsDisabledKeyInPlist() throws {
        let plist: [String: Any] = ["Label": "com.example.off", "Program": "/usr/bin/true",
                                   "Disabled": true]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let parsed = try #require(LaunchAgentManager.parsePlist(data: data))
        #expect(parsed.disabledInPlist)
    }
}
