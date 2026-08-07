import Testing
import Foundation
@testable import AtticCore

@Suite("ProcessSampler 실기기")
struct ProcessSamplerTests {
    @Test func findsSelfWithCorrectFields() throws {
        let me = ProcessInfo.processInfo.processIdentifier
        let samples = ProcessSampler().sample()
        let mine = try #require(samples.first { $0.pid == me })
        #expect(mine.uid == getuid())
        #expect(mine.physFootprint > 1 << 20)           // 최소 1MB
        #expect(mine.execPath.isEmpty == false)
        #expect(mine.cwd != nil)
        #expect(mine.argv.isEmpty == false)             // KERN_PROCARGS2 동작 확인
        #expect(mine.startSec > 0)
    }

    @Test func identityMatchesSample() throws {
        let me = ProcessInfo.processInfo.processIdentifier
        let sampler = ProcessSampler()
        let mine = try #require(sampler.sample().first { $0.pid == me })
        #expect(sampler.identity(of: me) == mine.identity)
    }

    @Test func detectsListeningPort() throws {
        // 테스트가 직접 리스닝 소켓을 연다 → 자기 자신에게서 그 포트가 보여야 한다
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(0).bigEndian          // OS가 포트 배정
        addr.sin_addr.s_addr = INADDR_ANY
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        #expect(bindResult == 0)
        #expect(listen(sock, 1) == 0)
        var bound = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = getsockname(sock, $0, &len)
            }
        }
        let port = UInt16(bigEndian: bound.sin_port)

        let me = ProcessInfo.processInfo.processIdentifier
        let mine = try #require(ProcessSampler().sample().first { $0.pid == me })
        #expect(mine.listeningPorts.contains(port))
    }
}
