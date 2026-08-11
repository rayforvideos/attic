import Darwin
import Foundation

/// `setpriority(PRIO_DARWIN_PROCESS, pid, PRIO_DARWIN_BG)`를 적용/해제한 결과.
/// 비권한으로 동작하며 같은 uid의 임의 프로세스에 걸 수 있다. 타 uid 대상은 커널이
/// EPERM으로 거부한다.
public enum PriorityChange: Sendable, Equatable {
    case backgrounded
    /// `prio = 0`으로 해제 성공. `PRIO_DARWIN_NONBG`는 공개 SDK에 없고 man 페이지가
    /// 명시하듯 해제는 리터럴 0이 정식 경로다.
    case restored
    /// 대상 uid가 다르다. 커널이 EPERM으로 막으므로 시도조차 하지 않는다.
    case refusedOtherUid
    /// 자기 자신, 유효하지 않은 pid, 또는 보호 목록에 속한 시스템 프로세스.
    case refusedProtected
    /// 판정은 통과했으나 syscall 자체가 실패했다.
    case failed(errno: Int32)
}

/// 프로세스를 Darwin 백그라운드 정책으로 밀거나 되돌리는 얇은 래퍼. 판정과 syscall을
/// 한 곳에 묶어 안전 경계가 호출부마다 어긋나는 일을 막는다.
public struct ProcessPriority: Sendable {
    /// Apple 제공 바이너리가 사는 곳. 여기 있는 것은 uid가 같아도 밀지 않는다.
    public static let systemBinaryPrefixes: [String] = [
        "/System/", "/usr/libexec/", "/usr/sbin/", "/usr/bin/", "/sbin/", "/bin/",
        "/Library/Apple/",
    ]

    /// `/System/` 안이지만 사용자가 직접 쓰는 평범한 앱이 사는 곳. 메모·캘린더 같은
    /// 것들이라 서드파티 앱과 다르게 취급할 이유가 없다. 시스템 서비스
    /// (`/System/Library/`)는 그대로 거부한다.
    public static let userFacingSystemAppPrefixes: [String] = [
        "/System/Applications/", "/System/Library/CoreServices/Applications/",
    ]

    /// 손대면 안 되는 프로세스 이름. 시스템 서비스를 느리게 만들면 그것을 기다리는
    /// 모든 것이 함께 멈춘다. mds/mdworker 계열은 Apple이 이미 낮은 우선순위로
    /// 돌리고 있어 더 밀면 색인이 끝나지 않고 CPU를 더 오래 붙잡는다.
    public static let protectedNames: Set<String> = [
        "launchd", "WindowServer", "loginwindow", "tccd", "secinitd",
        "mds", "mds_stores", "mdworker", "mdworker_shared", "mdbulkimport",
    ]

    private let ownUid: uid_t
    private let ownPid: pid_t

    public init(ownUid: uid_t, ownPid: pid_t) {
        self.ownUid = ownUid
        self.ownPid = ownPid
    }

    /// 이 프로세스에 정책을 걸 수 있는지. UI의 버튼 표시 조건과 모델의 거부 조건이
    /// 이 하나를 함께 써야 눌러도 항상 거절되는 버튼이 생기지 않는다.
    public func canAdjust(pid: pid_t, uid: uid_t, execPath: String) -> Bool {
        refusal(pid: pid, uid: uid, execPath: execPath) == nil
    }

    public func background(pid: pid_t, uid: uid_t, execPath: String) -> PriorityChange {
        if let refusal = refusal(pid: pid, uid: uid, execPath: execPath) { return refusal }
        return apply(pid: pid, prio: PRIO_DARWIN_BG, success: .backgrounded)
    }

    /// 되돌리기. 경계를 한 곳에 두려고 뒤로 밀 때와 같은 안전 판정을 적용한다.
    public func restore(pid: pid_t, uid: uid_t, execPath: String) -> PriorityChange {
        if let refusal = refusal(pid: pid, uid: uid, execPath: execPath) { return refusal }
        return apply(pid: pid, prio: 0, success: .restored)
    }

    /// 현재 뒤로 밀려 있는지 조회한다.
    ///
    /// `getpriority(PRIO_DARWIN_PROCESS, <타 pid>)`는 BG를 걸어둔 뒤에도 0을 돌려주는
    /// 경우가 있어 자기 자신에 대해서만 믿을 수 있다. 타 프로세스의 반환값을 진실
    /// 소스로 쓰지 말고, 뒤로 민 목록은 앱이 따로 기록해야 한다.
    public func isBackgrounded(pid: pid_t) -> Bool? {
        errno = 0
        let result = getpriority(PRIO_DARWIN_PROCESS, id_t(pid))
        if result == -1 && errno != 0 { return nil }
        return (result & PRIO_DARWIN_BG) != 0
    }

    // MARK: - 내부

    private func refusal(pid: pid_t, uid: uid_t, execPath: String) -> PriorityChange? {
        guard uid == ownUid else { return .refusedOtherUid }
        guard pid > 0, pid != ownPid else { return .refusedProtected }
        // Apple 시스템 바이너리는 느리게 만들어도 일이 더 오래 걸릴 뿐이고 무엇이
        // 그것을 기다리는지 우리가 알 수 없다. 미는 대상은 내 개발 프로세스와 내가
        // 띄운 앱뿐이다.
        let isUserFacingApp = Self.userFacingSystemAppPrefixes.contains {
            execPath.hasPrefix($0)
        }
        for prefix in Self.systemBinaryPrefixes
        where execPath.hasPrefix(prefix) && !isUserFacingApp {
            return .refusedProtected
        }
        let name = (execPath as NSString).lastPathComponent
        if Self.protectedNames.contains(name) { return .refusedProtected }
        return nil
    }

    private func apply(pid: pid_t, prio: Int32, success: PriorityChange) -> PriorityChange {
        errno = 0
        let ret = setpriority(PRIO_DARWIN_PROCESS, id_t(pid), prio)
        if ret == -1 { return .failed(errno: errno) }
        return success
    }

    /// 우리가 방금 띄운 자식 프로세스를 Darwin 백그라운드로 내린다.
    ///
    /// `background(pid:uid:execPath:)`의 안전 가드는 남의 프로세스를 미는 것을 막기
    /// 위한 것이라 여기엔 적용하지 않는다. 대상은 우리가 `Process.run()`으로 만들고
    /// 끝을 기다리는 자식뿐이다.
    public static func backgroundOwnChild(pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        errno = 0
        let ret = setpriority(PRIO_DARWIN_PROCESS, id_t(pid), PRIO_DARWIN_BG)
        return ret == 0
    }
}
