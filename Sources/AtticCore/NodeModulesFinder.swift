import Foundation

/// node_modules를 찾는다.
///
/// 예전에는 `find`를 자식 프로세스로 띄웠다. 42초 걸리던 것이 3초가 된 이유는
/// 별도 프로세스라서가 아니라 **가지치기**(숨김 폴더·node_modules 아래를 보지
/// 않음)였고, 그건 앱 안에서도 그대로 할 수 있다.
///
/// 앱 안에서 훑어야 하는 이유: 보호 폴더(문서·데스크탑) 접근을 자식 프로세스가
/// 요청하면 허용을 눌러도 우리 앱에 기록이 남지 않아 스캔할 때마다 같은
/// 프롬프트가 다시 뜬다(사용자 신고로 확인).
public enum NodeModulesFinder {
    /// `timeout`이 없으면 응답 없는 네트워크 마운트에서 find가 끝나지 않고,
    /// scan()이 반환하지 않아 isScanningSpace가 true로 굳는다 — 앱을 재시작할
    /// 때까지 다시 스캔할 수 없다(감사에서 확인). `-x`로 마운트 경계도 넘지 않는다.
    /// 결과와 함께 **온전히 훑었는지**를 돌려준다. find는 권한 거부 디렉토리를
    /// 만나면 rc=1로 끝나는데, 그것을 성공으로 받으면 일부만 훑은 목록이 완전한
    /// 결과로 올라가 "비울 게 없어요"가 거짓이 된다(감사에서 확인).
    public struct Result: Sendable {
        public let paths: [String]
        public let complete: Bool
    }

    /// `lowPriority`·`timeout`은 자식 프로세스 시절의 손잡이다. 앱 안에서 훑으면
    /// 끊을 프로세스가 없고 우선순위는 호출하는 Task가 정한다 — 호출부를 흔들지
    /// 않기 위해 인자는 남기고 무시한다.
    public static func find(under root: String, maxDepth: Int,
                            lowPriority: Bool = false,
                            timeout: TimeInterval = 120) -> Result {
        var paths: [String] = []
        // maxDepth는 "그 단계까지 내려가 그 안을 살핀다"는 뜻이라 node_modules
        // 자신은 한 단계 더 깊을 수 있다 — find 시절과 같은 범위를 유지한다.
        let complete = DirectoryWalk.walk(
            root: root, maxDepth: maxDepth + 1,
            onDirectory: { path in
                guard (path as NSString).lastPathComponent == "node_modules" else { return false }
                paths.append(path)
                return true     // 찾았으면 그 아래는 볼 필요가 없다
            })
        return Result(paths: paths, complete: complete)
    }

}
