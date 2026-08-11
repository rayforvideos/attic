import Foundation

/// (pid, 시작시각) 쌍. 부팅 세션 안에서 프로세스를 유일하게 가리키며 pid 재사용
/// 방어의 근간이다.
public struct ProcIdentity: Sendable, Equatable, Hashable {
    public let pid: pid_t
    public let startSec: UInt64
    public let startUsec: UInt64
    public init(pid: pid_t, startSec: UInt64, startUsec: UInt64) {
        self.pid = pid; self.startSec = startSec; self.startUsec = startUsec
    }
}

/// 한 프로세스의 스캔 시점 스냅샷. 시스템 접근 없이 판단 로직에 주입할 수 있다.
public struct ProcessSample: Sendable, Equatable {
    public let pid: pid_t
    public let ppid: pid_t
    public let uid: uid_t
    public let startSec: UInt64
    public let startUsec: UInt64
    public let physFootprint: UInt64        // 바이트. 측정 실패(타 uid) 시 0
    public let execPath: String             // proc_pidpath. 실패 시 ""
    public let argv: [String]               // KERN_PROCARGS2. 실패 시 []
    public let cwd: String?                 // PROC_PIDVNODEPATHINFO. 실패 시 nil
    public let listeningPorts: [UInt16]     // TSI_S_LISTEN 상태 TCP 로컬 포트
    public let cpuTimeNanos: UInt64         // ri_user_time + ri_system_time

    public var identity: ProcIdentity {
        ProcIdentity(pid: pid, startSec: startSec, startUsec: startUsec)
    }

    public init(pid: pid_t, ppid: pid_t, uid: uid_t,
                startSec: UInt64, startUsec: UInt64,
                physFootprint: UInt64, execPath: String, argv: [String],
                cwd: String?, listeningPorts: [UInt16], cpuTimeNanos: UInt64) {
        self.pid = pid; self.ppid = ppid; self.uid = uid
        self.startSec = startSec; self.startUsec = startUsec
        self.physFootprint = physFootprint; self.execPath = execPath
        self.argv = argv; self.cwd = cwd
        self.listeningPorts = listeningPorts; self.cpuTimeNanos = cpuTimeNanos
    }
}

/// ppid 체인을 끝까지 따라가는 데 필요한 최소 조상 정보. proc_bsdshortinfo와
/// proc_pidpath는 NO_CHECK_SAME_USER라 root 소유 조상까지 덮는다.
public struct AncestorInfo: Sendable, Equatable {
    public let ppid: pid_t
    public let execPath: String
    public init(ppid: pid_t, execPath: String) {
        self.ppid = ppid; self.execPath = execPath
    }
}


#if DEBUG
extension ProcessSample {
    /// 테스트 픽스처. 인자 없이 쓰면 안전한 기본값.
    public static func fixture(
        pid: pid_t = 1000, ppid: pid_t = 1, uid: uid_t = 501,
        startSec: UInt64 = 0, startUsec: UInt64 = 0,
        physFootprint: UInt64 = 50 << 20,
        execPath: String = "/usr/local/bin/node",
        argv: [String] = ["node", "/proj/node_modules/.bin/vite"],
        cwd: String? = "/Users/ray/workspace/proj",
        listeningPorts: [UInt16] = [], cpuTimeNanos: UInt64 = 0
    ) -> ProcessSample {
        ProcessSample(pid: pid, ppid: ppid, uid: uid,
                      startSec: startSec, startUsec: startUsec,
                      physFootprint: physFootprint, execPath: execPath,
                      argv: argv, cwd: cwd, listeningPorts: listeningPorts,
                      cpuTimeNanos: cpuTimeNanos)
    }
}
#endif

/// 프로세스 샘플러의 계약. 테스트가 가짜 샘플을 넣을 수 있게 프로토콜로 둔다.
public protocol ProcessSampling: Sendable {
    func sample() -> [ProcessSample]
    func ancestrySnapshot() -> [pid_t: AncestorInfo]
}
