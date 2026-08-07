import Foundation

/// `/usr/bin/du -sk`로 디렉토리의 실제 점유 바이트를 잰다. 스캔(항목 발견)과
/// 실행(휴지통 이동 직전 재측정)이 같은 자를 써야 보고한 숫자가 일치한다.
///
/// 실패·타임아웃은 nil이다 — 호출자는 크기를 **추측하지 않고** 그 사실을
/// 그대로 다뤄야 한다(스캔은 항목을 빼고 보고, 실행은 스캔 값에 "약"을 붙인다).
public enum DirectorySize {
    /// 여러 경로를 **한 번의 du 호출로** 잰다. 항목마다 부르면 이 맥에서 280번이
    /// 되어 스캔이 95초 걸렸다(실측) — du는 경로를 여러 개 받아 각 줄에 크기를
    /// 돌려주므로 한 번에 물어보는 편이 낫다.
    ///
    /// 반환은 경로 → 바이트. 못 잰 경로는 키가 없다(호출부가 그 사실을 다뤄야 한다).
    /// 경로가 많으면 인자 길이 한계(ARG_MAX)에 걸리므로 묶어서 나눠 부른다.
    public static func measureAll(_ paths: [String], lowPriority: Bool = false,
                                  timeout: TimeInterval = 300) async -> [String: UInt64] {
        guard !paths.isEmpty else { return [:] }
        // du는 I/O 병목이라 **묶음을 병렬로** 돌려야 한다. 한 묶음씩 순차로
        // 부르면 호출 수는 줄지만 병렬성을 잃어 오히려 느려진다(실측: 순차
        // 배치가 항목별 병렬보다 더 오래 걸렸다).
        let chunkSize = max(8, paths.count / 8)
        let chunks = stride(from: 0, to: paths.count, by: chunkSize).map {
            Array(paths[$0..<min($0 + chunkSize, paths.count)])
        }
        return await withTaskGroup(of: [String: UInt64].self) { group in
            for chunk in chunks {
                group.addTask {
                    await measureChunk(chunk, lowPriority: lowPriority, timeout: timeout)
                }
            }
            var result: [String: UInt64] = [:]
            for await measured in group {
                result.merge(measured) { current, _ in current }
            }
            return result
        }
    }

    private static func measureChunk(_ paths: [String], lowPriority: Bool,
                                     timeout: TimeInterval) async -> [String: UInt64] {
        await Task.detached { () -> [String: UInt64] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
            process.arguments = ["-sk"] + paths
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return [:]
            }
            if lowPriority { _ = ProcessPriority.backgroundOwnChild(pid: process.processIdentifier) }

            // 출력을 먼저 다 읽는다 — 파이프가 차면 du가 멈추므로 시한 감시는
            // 별도 스레드에 맡긴다.
            let deadline = Date().addingTimeInterval(timeout)
            let watchdog = Thread {
                while process.isRunning {
                    if Date() >= deadline { process.terminate(); return }
                    usleep(200_000)
                }
            }
            watchdog.start()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            // du는 일부 경로가 실패해도 나머지를 출력하고 rc=1로 끝난다 —
            // 읽은 줄은 그대로 쓴다.
            var sizes: [String: UInt64] = [:]
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
                guard parts.count == 2, let kb = UInt64(parts[0].trimmingCharacters(in: .whitespaces))
                else { continue }
                sizes[parts[1]] = kb * 1024
            }
            return sizes
        }.value
    }

    /// 타임아웃은 속도 조절이 아니라 du가 영영 끝나지 않는 경우(네트워크 마운트)를
    /// 끊는 안전장치다. 가장 크고 비울 가치가 큰 항목이 콜드 캐시에서 20초를
    /// 넘기므로 넉넉히 잡는다.
    public static func measure(_ path: String, lowPriority: Bool = false,
                               timeout: TimeInterval = 180) async -> UInt64? {
        await Task.detached { () -> UInt64? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
            process.arguments = ["-sk", path]
            let pipe = Pipe()
            process.standardOutput = pipe
            // 읽는 쪽 없는 Pipe는 du가 stderr에 64KB를 넘겨 쓰면 그 자리에서
            // 멈춘다(빌드 중 사라진 파일이 많은 트리에서 실제로 발생).
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return nil
            }
            if lowPriority { _ = ProcessPriority.backgroundOwnChild(pid: process.processIdentifier) }

            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning {
                if Date() >= deadline {
                    process.terminate()
                    process.waitUntilExit()
                    return nil
                }
                usleep(50_000) // 50ms poll interval
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            guard let output = String(data: data, encoding: .utf8) else { return nil }
            guard let firstField = output.split(separator: "\t").first
                ?? output.split(separator: " ").first,
                let kilobytes = UInt64(firstField.trimmingCharacters(in: .whitespaces)) else {
                return nil
            }
            return kilobytes * 1024
        }.value
    }
}
