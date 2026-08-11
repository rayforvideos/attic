import Darwin
import Foundation

public struct ProcessSampler: ProcessSampling {
    public init() {}

    public func sample() -> [ProcessSample] {
        let me = getuid()
        return Self.allPids().compactMap { pid -> ProcessSample? in
            guard let bsd = Self.bsdInfo(pid), bsd.pbi_uid == me else { return nil }
            let usage = Self.rusage(pid)
            return ProcessSample(
                pid: pid,
                ppid: pid_t(bsd.pbi_ppid),
                uid: bsd.pbi_uid,
                startSec: bsd.pbi_start_tvsec,
                startUsec: bsd.pbi_start_tvusec,
                physFootprint: usage?.ri_phys_footprint ?? 0,
                execPath: Self.execPath(pid),
                argv: Self.arguments(pid) ?? [],
                cwd: Self.cwd(pid),
                listeningPorts: Self.listeningPorts(pid),
                cpuTimeNanos: (usage.map { $0.ri_user_time + $0.ri_system_time }) ?? 0
            )
        }
    }

    public func identity(of pid: pid_t) -> ProcIdentity? {
        guard let bsd = Self.bsdInfo(pid) else { return nil }
        return ProcIdentity(pid: pid, startSec: bsd.pbi_start_tvsec,
                            startUsec: bsd.pbi_start_tvusec)
    }

    /// 전 uid 프로세스의 ppid/실행경로 맵. PROC_PIDT_SHORTBSDINFO와 proc_pidpath는
    /// NO_CHECK_SAME_USER라 root 소유 조상까지 덮는다. ppid 체인 보행은 반드시 이
    /// 스냅샷을 써야 한다. same-uid 전용 `sample()` 맵은 root 조상에서 끊겨
    /// fail-closed 판정이 오작동한다.
    public func ancestrySnapshot() -> [pid_t: AncestorInfo] {
        var result: [pid_t: AncestorInfo] = [:]
        for pid in Self.allPids() {
            guard let short = Self.shortBsdInfo(pid) else { continue }
            result[pid] = AncestorInfo(ppid: pid_t(short.pbsi_ppid), execPath: Self.execPath(pid))
        }
        return result
    }

    // MARK: - libproc 래퍼 (전부 same-uid 또는 무제한 flavor)

    static func allPids() -> [pid_t] {
        let capacity = proc_listallpids(nil, 0) + 64    // 재호출 사이 증가 대비 여유분
        guard capacity > 64 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity))
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        guard n > 0 else { return [] }
        return Array(pids.prefix(Int(n))).filter { $0 > 0 }
    }

    static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let ret = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard ret == size else { return nil }           // 부분 반환은 신뢰 불가
        return info
    }

    static func shortBsdInfo(_ pid: pid_t) -> proc_bsdshortinfo? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.stride)
        let ret = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size)
        guard ret == size else { return nil }            // 부분 반환은 신뢰 불가
        return info
    }

    static func rusage(_ pid: pid_t) -> rusage_info_v4? {
        var info = rusage_info_v4()
        let ret = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return ret == 0 ? info : nil
    }

    static func execPath(_ pid: pid_t) -> String {
        let maxPath = 4 * Int(MAXPATHLEN)               // PROC_PIDPATHINFO_MAXSIZE 매크로 미노출
        var buf = [CChar](repeating: 0, count: maxPath)
        guard proc_pidpath(pid, &buf, UInt32(maxPath)) > 0 else { return "" }
        if let nullIndex = buf.firstIndex(of: 0) {
            let bytes = buf[0..<nullIndex].map { UInt8(bitPattern: $0) }
            return String(decoding: bytes, as: UTF8.self)
        }
        return ""
    }

    static func cwd(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        let ret = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size)
        guard ret == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { ptr in
                var len = 0
                while len < Int(MAXPATHLEN) && ptr[len] != 0 {
                    len += 1
                }
                let bytes = (0..<len).map { UInt8(bitPattern: ptr[$0]) }
                return String(decoding: bytes, as: UTF8.self)
            }
        }
    }

    static func listeningPorts(_ pid: pid_t) -> [UInt16] {
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(),
                                count: Int(needed) / stride + 32)   // TOCTOU 여유분
        let written = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds,
                                   Int32(fds.count * stride))
        guard written > 0 else { return [] }

        var ports = Set<UInt16>()
        for fd in fds.prefix(Int(written) / stride)
        where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var si = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.stride)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &si, size) == size,
                  si.psi.soi_kind == SOCKINFO_TCP else { continue }
            let tcp = si.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))
            if port != 0 { ports.insert(port) }
        }
        return ports.sorted()
    }

    static func arguments(_ pid: pid_t) -> [String]? {
        var argmax = 0
        var size = MemoryLayout<Int>.stride
        guard sysctlbyname("kern.argmax", &argmax, &size, nil, 0) == 0 else { return nil }

        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var buf = [UInt8](repeating: 0, count: argmax)  // size 프로브 불안정 → argmax 할당 관행
        var bufSize = argmax
        guard sysctl(&mib, 3, &buf, &bufSize, nil, 0) == 0,
              bufSize > MemoryLayout<Int32>.stride else { return nil }

        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = MemoryLayout<Int32>.stride
        while i < bufSize && buf[i] != 0 { i += 1 }     // exec_path 스킵

        // KERN_PROCARGS2는 exec_path 뒤에 정렬용 널 패딩을 넣는데, argv[0]이 빈
        // 문자열이면 바이트 수준에서 패딩과 구분되지 않아 한 칸씩 밀려 읽힌다.
        // 커널이 주는 정보만으로는 피할 수 없어 그대로 둔다.
        while i < bufSize && buf[i] == 0 { i += 1 }     // 널 패딩 스킵 (개수 가변)
        var argv: [String] = []
        var start = i
        while i < bufSize && argv.count < Int(argc) {   // 카운트 기반: 빈 문자열 argv 허용
            if buf[i] == 0 {
                argv.append(String(decoding: buf[start..<i], as: UTF8.self))
                start = i + 1
            }
            i += 1
        }
        return argv
    }
}
