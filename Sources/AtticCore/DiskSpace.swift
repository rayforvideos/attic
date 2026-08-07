import Foundation

/// 디스크 용량. 되돌려줄 양을 재면서 정작 "지금 얼마 남았나"를 보여주지 않으면
/// 74GB가 큰 값인지 감이 오지 않는다.
public struct DiskSpace: Sendable, Equatable {
    public let total: UInt64
    /// 사용자가 실제로 쓸 수 있는 양(purgeable 포함) — Finder가 말하는 여유.
    public let free: UInt64
    /// `free` 중 시스템이 필요할 때 스스로 비우는 영역(로컬 스냅샷·시스템 캐시).
    /// df/statfs의 즉시 여유와 Finder 여유가 다르게 말하는 "설명되지 않는 X GB"의
    /// 정체다 — 이름을 붙여 보여주는 것이 목적이고, 앱이 직접 지우지는 않는다.
    public let purgeable: UInt64

    public var used: UInt64 { total > free ? total - free : 0 }
    /// 0~1
    public var usedRatio: Double {
        total > 0 ? Double(used) / Double(total) : 0
    }

    public init(total: UInt64, free: UInt64, purgeable: UInt64 = 0) {
        self.total = total
        self.free = free
        self.purgeable = purgeable
    }
}

public protocol DiskSpaceProbing: Sendable {
    func snapshot() -> DiskSpace?
}

public struct DiskSpaceProbe: DiskSpaceProbing {
    let path: String

    public init(path: String = NSHomeDirectory()) {
        self.path = path
    }

    public func snapshot() -> DiskSpace? {
        // 사용자가 실제로 쓸 수 있는 양(.volumeAvailableCapacityForImportantUsage)을 쓴다.
        // statfs의 f_bavail은 APFS에서 스냅샷·예약분 때문에 과대평가된다.
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ]) else { return nil }
        guard let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        // 즉시 여유(purgeable 제외)와의 차이가 시스템이 비울 수 있는 영역이다.
        let plain = UInt64(max(0, values.volumeAvailableCapacity ?? 0))
        let free = UInt64(max(0, available))
        return DiskSpace(total: UInt64(total), free: free,
                         purgeable: free > plain ? free - plain : 0)
    }
}

/// APFS 로컬 스냅샷 개수 — `tmutil listlocalsnapshots /`는 비root로 동작한다.
/// purgeable 공간의 주범이 대개 이것이라, 개수를 함께 보여주면 "왜 여유가
/// 두 값으로 보이지"라는 의문에 이름이 생긴다.
public enum LocalSnapshots {
    public static func parseCount(from output: String) -> Int {
        output.split(separator: "\n")
            .filter { $0.hasSuffix(".local") }
            .count
    }

    /// 어느 볼륨의 스냅샷인지 명시한다 — 홈이 외장/별도 볼륨이면 `/`의 개수를
    /// 홈 볼륨의 purgeable 옆에 붙이는 것은 다른 볼륨 이야기를 섞는 것이다.
    public static func count(volumePath: String = NSHomeDirectory()) -> Int {
        // 홈이 속한 볼륨의 마운트 지점을 찾아 그 볼륨을 조회한다.
        let mount = (try? URL(fileURLWithPath: volumePath)
            .resourceValues(forKeys: [.volumeURLKey]))?.volume?.path ?? "/"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        process.arguments = ["listlocalsnapshots", mount]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return 0 }
            return parseCount(from: String(decoding: data, as: UTF8.self))
        } catch {
            return 0
        }
    }
}


/// 전체 디스크 접근 권한이 있는지. macOS에 직접 묻는 API가 없어서, **권한이
/// 없으면 반드시 실패하는 경로**를 읽어 판별한다(TCC 데이터베이스 디렉터리).
///
/// 이 판별이 필요한 이유: 큰 파일·설치 파일·스크린샷을 찾으려면 Downloads·
/// Desktop·Documents·Movies·Music을 봐야 하고, macOS는 **폴더마다 따로** 묻는다.
/// 사용자에게는 "스캔할 때마다 묻는다"로 느껴진다. 전체 디스크 접근을 한 번
/// 허용하면 그 프롬프트가 전부 사라지므로, 그 사실을 알려줄 수 있어야 한다.
public enum FullDiskAccess {
    public static var isGranted: Bool {
        let probe = NSHomeDirectory() + "/Library/Application Support/com.apple.TCC"
        return (try? FileManager.default.contentsOfDirectory(atPath: probe)) != nil
    }

    /// 시스템 설정의 전체 디스크 접근 페이지를 연다(딥링크 실측 확인 2026-08-06).
    public static var settingsURL: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    }
}
