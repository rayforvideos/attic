import Foundation

/// `Reclaimer.moveToTrash` 한 번의 결과.
public struct ReclaimResult: Sendable {
    public let movedBytes: UInt64
    public let movedCount: Int
    public let refused: [(path: String, reason: ReclaimRefusal)]
    public let failed: [(path: String, message: String)]
    /// 옮겨진 항목이 휴지통 어디에 놓였는지(`resultingItemURL`).
    public let trashedURLs: [String]
    /// 옮기려 했으나 경로가 이미 없던 항목. 문구로 판별하면 번역된 언어에서 매칭이
    /// 깨지므로 구조로 돌려준다.
    public var alreadyGone: [String] = []
    /// 이동한 모든 항목의 크기를 실행 직전에 다시 쟀는지. false면 스캔 당시 값이
    /// 섞여 있다는 뜻이라 화면과 장부가 "약"으로 다뤄야 한다.
    public let remeasured: Bool

    public init(
        movedBytes: UInt64,
        movedCount: Int,
        refused: [(path: String, reason: ReclaimRefusal)],
        failed: [(path: String, message: String)],
        trashedURLs: [String] = [],
        remeasured: Bool = true,
        alreadyGone: [String] = []
    ) {
        self.movedBytes = movedBytes
        self.movedCount = movedCount
        self.refused = refused
        self.failed = failed
        self.trashedURLs = trashedURLs
        self.remeasured = remeasured
        self.alreadyGone = alreadyGone
    }
}

/// 후보를 휴지통으로 옮긴다. 지우지 않는다. 이 타입이 하는 유일한 파일 시스템 변경은
/// `FileManager.trashItem`이다.
///
/// 항목마다 옮기기 직전에 심볼릭 링크 여부와 수정 시각을 다시 읽어 `ReclaimGuard`로
/// 재검증한다. 스캔 이후의 변화와, 호출부가 손으로 만든 항목을 넘기는 경우를 함께
/// 막는다.
public struct Reclaimer: Sendable {
    public init() {}

    public func moveToTrash(
        _ items: [ReclaimItem],
        guard guardian: ReclaimGuard,
        staleThresholdDays: Int,
        inUse: ReclaimInUse? = nil
    ) async -> ReclaimResult {
        // 스캔 때 걸렀어도 그 사이 앱이 켜졌을 수 있어 이동 시점의 프로세스 목록으로
        // 다시 판정한다. 주입은 테스트용이다.
        let running = inUse ?? ReclaimInUse(samples: ProcessSampler().sample())
        var movedBytes: UInt64 = 0
        var movedCount = 0
        var refused: [(path: String, reason: ReclaimRefusal)] = []
        var failed: [(path: String, message: String)] = []
        var trashedURLs: [String] = []
        var allRemeasured = true
        var alreadyGone: [String] = []

        for item in items {
            let fm = FileManager.default

            if let process = running.culprit(path: item.path, kind: item.kind,
                                             home: guardian.home) {
                refused.append((item.path, .inUse(by: process)))
                continue
            }

            // attributesOfItem은 심볼릭 링크를 따라가지 않는다. 끊어진 링크도
            // "없다"가 아니라 링크로 보이고 아래 가드가 거부한다.
            guard let attributes = try? fm.attributesOfItem(atPath: item.path) else {
                failed.append((item.path, L("경로가 이미 없어요")))
                alreadyGone.append(item.path)
                continue
            }

            let isSymlink = (attributes[.type] as? FileAttributeType) == .typeSymbolicLink
            let resolvedPath = URL(fileURLWithPath: item.path).resolvingSymlinksInPath().path

            let lockfilePresent: Bool
            let ageDays: Int
            if item.kind == .nodeModules {
                let projectDir = (item.path as NSString).deletingLastPathComponent
                lockfilePresent = hasLockfile(inDirectory: projectDir)
                // fail-closed. mtime을 못 읽으면 방금 고친 것으로 보아 가드가 거부하게 한다.
                ageDays = ageInDays(ofPath: projectDir) ?? 0
            } else {
                lockfilePresent = false
                // 못 재면 0으로 둔다. 모르는 것은 손대지 않는 편이 맞다.
                ageDays = FileAge.days(ofItemAt: item.path) ?? 0
            }

            if let refusal = guardian.check(
                path: item.path, kind: item.kind, lockfilePresent: lockfilePresent,
                ageDays: ageDays, isSymlink: isSymlink, resolvedPath: resolvedPath,
                staleThresholdDays: staleThresholdDays
            ) {
                refused.append((item.path, refusal))
                continue
            }

            // 스캔 값은 며칠 전 것일 수 있어 옮기기 직전에 다시 잰다. 측정에
            // 실패하면 스캔 값을 쓰되 그 사실을 기록한다.
            let measured = await DirectorySize.measure(item.path)
            if measured == nil { allRemeasured = false }

            do {
                var resultingURL: NSURL?
                try fm.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: &resultingURL)
                if let trashedPath = resultingURL?.path {
                    trashedURLs.append(trashedPath)
                }
                movedBytes += measured ?? item.bytes
                movedCount += 1
            } catch {
                failed.append((item.path, error.localizedDescription))
            }
        }

        return ReclaimResult(movedBytes: movedBytes, movedCount: movedCount,
                              refused: refused, failed: failed, trashedURLs: trashedURLs,
                              remeasured: allRemeasured, alreadyGone: alreadyGone)
    }

    private func hasLockfile(inDirectory dir: String) -> Bool {
        let lockfiles = ["package-lock.json", "yarn.lock", "pnpm-lock.yaml"]
        let fm = FileManager.default
        return lockfiles.contains { fm.fileExists(atPath: "\(dir)/\($0)") }
    }

    private func ageInDays(ofPath path: String) -> Int? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date else {
            return nil
        }
        let seconds = Date().timeIntervalSince(mtime)
        return max(0, Int(seconds / 86_400))
    }
}
