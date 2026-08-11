import Foundation

/// 바이트를 사람이 읽는 크기로 바꾼다.
public enum SizeText {
    /// 목록·문장에 넣는 짧은 표기. 작은 값도 0으로 뭉개지 않는다. "0"으로 보이면
    /// 크기를 못 잰 것인지 정말 빈 파일인지 구별할 수 없다.
    public static func compact(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / Double(1 << 30)
        if gb >= 1 { return String(format: "%.1fGB", gb) }
        let mb = Double(bytes) / Double(1 << 20)
        if mb >= 1 { return String(format: "%.0fMB", mb) }
        let kb = Double(bytes) / Double(1 << 10)
        if kb >= 1 { return String(format: "%.0fKB", kb) }
        return "\(bytes)B"
    }

    /// 큰 숫자를 강조해 보여주는 자리용. 값과 단위를 따로 준다.
    public static func split(_ bytes: UInt64) -> (value: String, unit: String) {
        let gb = Double(bytes) / Double(1 << 30)
        if gb >= 1 { return (String(format: "%.1f", gb), "GB") }
        let mb = Double(bytes) / Double(1 << 20)
        if mb >= 1 { return (String(format: "%.0f", mb), "MB") }
        let kb = Double(bytes) / Double(1 << 10)
        if kb >= 1 { return (String(format: "%.0f", kb), "KB") }
        return ("\(bytes)", "B")
    }
}
