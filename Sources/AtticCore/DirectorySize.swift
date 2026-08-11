import Foundation

/// `/usr/bin/du -sk`로 디렉터리의 실제 점유 바이트를 잰다.
///
/// 실패·타임아웃은 nil이다. 호출자는 크기를 추측하지 말고 모른다는 사실을 그대로
/// 다뤄야 한다.
public enum DirectorySize {
    /// 여러 경로를 한 번의 du 호출로 잰다. 반환은 경로 → 바이트이고 못 잰 경로는
    /// 키가 없다. 경로가 많으면 인자 길이 한계(ARG_MAX)에 걸리므로 나눠 부른다.
    public static func measureAll(_ paths: [String], lowPriority: Bool = false,
                                  timeout: TimeInterval = 300) async -> [String: UInt64] {
        guard !paths.isEmpty else { return [:] }
        // du는 I/O 병목이라 묶음을 순차로 부르면 호출 수는 줄어도 병렬성을 잃어
        // 더 느리다.
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

            // 파이프가 차면 du가 멈추므로 출력을 먼저 읽고 시한 감시는 별도
            // 스레드에 맡긴다.
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

            // du는 일부 경로가 실패해도 나머지를 출력하고 rc=1로 끝나므로 읽은
            // 줄은 그대로 쓴다.
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

    /// 타임아웃은 속도 조절이 아니라 네트워크 마운트처럼 du가 영영 끝나지 않는
    /// 경우를 끊는 안전장치다. 콜드 캐시에서 큰 항목은 20초를 넘기므로 넉넉히 잡는다.
    public static func measure(_ path: String, lowPriority: Bool = false,
                               timeout: TimeInterval = 180) async -> UInt64? {
        await Task.detached { () -> UInt64? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
            process.arguments = ["-sk", path]
            let pipe = Pipe()
            process.standardOutput = pipe
            // 읽는 쪽 없는 Pipe는 du가 stderr에 64KB를 넘겨 쓰면 그 자리에서 멈춘다.
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
