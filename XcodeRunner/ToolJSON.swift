import Foundation

/// Command diagnostics can surround a JSON document. Locate a
/// complete, balanced document, respecting strings and escaped brackets.
enum ToolJSON {
    static func decode<T>(_ text: String, context: String, matching: (Any) -> T?) throws -> T {
        let bytes = Array(text.utf8)
        var candidate = 0
        var attempts = 0
        while candidate < bytes.count && attempts < 512 {
            guard bytes[candidate] == 123 || bytes[candidate] == 91 else { candidate += 1; continue }
            attempts += 1
            var stack: [UInt8] = []
            var quoted = false
            var escaped = false
            var end: Int?
            for index in candidate..<bytes.count {
                let byte = bytes[index]
                if quoted {
                    if escaped { escaped = false }
                    else if byte == 92 { escaped = true }
                    else if byte == 34 { quoted = false }
                    continue
                }
                if byte == 34 { quoted = true; continue }
                if byte == 123 || byte == 91 { stack.append(byte) }
                else if byte == 125 || byte == 93 {
                    guard let last = stack.last, (last == 123 && byte == 125) || (last == 91 && byte == 93) else { break }
                    stack.removeLast()
                    if stack.isEmpty { end = index; break }
                }
            }
            if let end, let object = try? JSONSerialization.jsonObject(with: Data(bytes[candidate...end])), let value = matching(object) {
                return value
            }
            candidate += 1
        }
        throw RunnerError.message("Cannot read \(context): the tool did not return a complete JSON document in the expected format. This may be caused by mixed diagnostic output or an incomplete response.")
    }
}
