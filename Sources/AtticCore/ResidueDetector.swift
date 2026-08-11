import Foundation

public enum ResidueSignal: Sendable, Equatable {
    case longLived(hours: Double)       // 기본 임계 4시간 초과
    case orphaned                       // ppid == 1 이거나 부모가 죽음
    case cpuIdle(hours: Double)         // 직전 관측 대비 CPU 시간 증가 미미
    case staleProject(days: Double)     // cwd 최종 수정이 오래됨 (기본 1일 초과)
    case duplicate(count: Int)          // 동일 실행 경로+인자 2개 이상
    case holdsPorts([UInt16])
}

public struct ResidueCandidate: Sendable, Equatable {
    public let sample: ProcessSample
    public let signals: [ResidueSignal]
    public var score: Int { signals.count }
}

public struct ResidueGroup: Sendable, Equatable {
    public let projectPath: String
    public let candidates: [ResidueCandidate]
    public var totalFootprint: UInt64 { candidates.reduce(0) { $0 + $1.sample.physFootprint } }
    public var allPorts: [UInt16] { candidates.flatMap(\.sample.listeningPorts).sorted() }
    public var score: Int { candidates.map(\.score).max() ?? 0 }
}

public struct DetectionContext: Sendable {
    public let now: Date
    // 전 uid 프로세스의 ppid/실행경로 맵(ProcessSampler.ancestrySnapshot()).
    // 기본값을 두면 "조상 데이터 없음"과 "정말로 조상이 없음"을 구분할 수 없게 되므로
    // 호출부가 매번 명시적으로 채우도록 필수 파라미터로 둔다.
    public let ancestry: [pid_t: AncestorInfo]
    public let protectedPaths: [String]
    public let previousCPUTimes: [ProcIdentity: UInt64]   // 직전 관측 창의 CPU 시간
    public let previousObservedAt: Date?
    public let projectMTime: @Sendable (String) -> Date?
    public let ideBundleNames: Set<String>
    public let ownPid: pid_t
    public let ownUid: uid_t

    public init(now: Date, ancestry: [pid_t: AncestorInfo], protectedPaths: [String],
                previousCPUTimes: [ProcIdentity: UInt64], previousObservedAt: Date?,
                projectMTime: @escaping @Sendable (String) -> Date?,
                ideBundleNames: Set<String> = ["IntelliJ IDEA", "Xcode", "Code", "Cursor"],
                ownPid: pid_t = getpid(), ownUid: uid_t = getuid()) {
        self.now = now; self.ancestry = ancestry; self.protectedPaths = protectedPaths
        self.previousCPUTimes = previousCPUTimes; self.previousObservedAt = previousObservedAt
        self.projectMTime = projectMTime; self.ideBundleNames = ideBundleNames
        self.ownPid = ownPid; self.ownUid = ownUid
    }
}

public struct ResidueDetector: Sendable {
    /// 경로 컴포넌트 단위로 대소문자를 무시해 비교한다. `hasPrefix`만 쓰면
    /// `/Users/ray/wo`가 `/Users/ray/work-other`까지 보호하고, 틸드가 확장되지 않은
    /// `~/work`는 아무것도 보호하지 못한다.
    static func isUnder(_ path: String, root rawRoot: String) -> Bool {
        let root = (rawRoot as NSString).expandingTildeInPath
        guard !root.isEmpty else { return false }
        if path.compare(root, options: .caseInsensitive) == .orderedSame { return true }
        return path.lowercased().hasPrefix(root.lowercased() + "/")
    }

    static let lifetimeThreshold: TimeInterval = 4 * 3600
    static let staleProjectThreshold: TimeInterval = 86_400
    static let cpuIdleThresholdNanos: UInt64 = 1_000_000_000   // 관측 창에서 1초 미만 증가

    let context: DetectionContext

    public init(context: DetectionContext) { self.context = context }

    public func detect(_ samples: [ProcessSample]) -> [ResidueGroup] {
        let eligible = samples.filter { isTarget($0) && !isExcluded($0) }

        var comboCount: [String: Int] = [:]
        for s in eligible {
            comboCount[s.execPath + "\u{0}" + s.argv.joined(separator: "\u{0}"), default: 0] += 1
        }

        // 근거 없는 후보는 그룹을 만들기 전에 하나씩 걸러낸다. 같은 cwd에 정상
        // 실행 중인 프로세스가 섞일 수 있는데, 그룹 단위로 판정하면 근거 없는
        // 프로세스가 형제에 묻어 함께 정리 대상이 된다.
        let candidates = eligible
            .map { s in ResidueCandidate(sample: s, signals: signals(for: s, comboCount: comboCount)) }
            .filter { !$0.signals.isEmpty }
        return Dictionary(grouping: candidates, by: { $0.sample.cwd ?? L("(경로 모름)") })
            .map { ResidueGroup(projectPath: $0.key,
                                candidates: $0.value.sorted { $0.score > $1.score }) }
            // 동점이면 용량, 경로 순으로 완전히 결정된 순서를 만든다. Dictionary
            // 순서에 기대면 같은 데이터로 다시 계산해도 목록이 흔들린다.
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                if $0.totalFootprint != $1.totalFootprint {
                    return $0.totalFootprint > $1.totalFootprint
                }
                return $0.projectPath < $1.projectPath
            }
    }

    func isTarget(_ s: ProcessSample) -> Bool {
        DevProcessPatterns.matches(argv: s.argv)
    }

    func isExcluded(_ s: ProcessSample) -> Bool {
        if s.pid == context.ownPid { return true }
        if s.execPath.hasPrefix("/System/") { return true }
        if s.uid != context.ownUid { return true }
        if let cwd = s.cwd, context.protectedPaths.contains(where: { Self.isUnder(cwd, root: $0) }) {
            return true
        }
        // ppid 체인을 거슬러 IDE 번들에 닿으면 제외한다. ancestry는 전 uid를 덮는
        // 완전한 스냅샷이라 여기서 조상을 못 찾는 것은 그 pid가 실제로 없다는 뜻이고,
        // 그때만 fail-closed로 제외한다.
        var cursor = s.ppid
        var hops = 0
        while cursor > 1, hops < 32 {
            guard let ancestor = context.ancestry[cursor] else {
                return true
            }
            if let bundle = AppGrouper.outermostBundlePath(of: ancestor.execPath) {
                let last = (bundle as NSString).lastPathComponent
                let name = last.hasSuffix(".app") ? String(last.dropLast(4)) : last
                if context.ideBundleNames.contains(name) { return true }
            }
            cursor = ancestor.ppid
            hops += 1
        }
        return false
    }

    func signals(for s: ProcessSample, comboCount: [String: Int]) -> [ResidueSignal] {
        var result: [ResidueSignal] = []
        let age = context.now.timeIntervalSince1970 - Double(s.startSec)
        if age > Self.lifetimeThreshold {
            result.append(.longLived(hours: age / 3600))
        }
        if s.ppid == 1 {
            result.append(.orphaned)
        }
        if let prevCPU = context.previousCPUTimes[s.identity],
           let prevAt = context.previousObservedAt,
           s.cpuTimeNanos &- prevCPU < Self.cpuIdleThresholdNanos {
            result.append(.cpuIdle(hours: context.now.timeIntervalSince(prevAt) / 3600))
        }
        if let cwd = s.cwd, let mtime = context.projectMTime(cwd) {
            let staleness = context.now.timeIntervalSince(mtime)
            if staleness > Self.staleProjectThreshold {
                result.append(.staleProject(days: staleness / 86_400))
            }
        }
        let combo = s.execPath + "\u{0}" + s.argv.joined(separator: "\u{0}")
        if let n = comboCount[combo], n >= 2 {
            result.append(.duplicate(count: n))
        }
        if !s.listeningPorts.isEmpty {
            result.append(.holdsPorts(s.listeningPorts))
        }
        return result
    }
}
