import Foundation

/// Claude Code PreToolUse 的 stdin JSON -> WireRequest。
public enum HookRequestBuilder {
    /// stdin 读取上限；超过就放弃拦截（回落到原生提示）。
    public static let stdinLimitBytes = 32 * 1024 * 1024

    /// 返回 nil 表示不该拦截（非 PreToolUse、缺 tool_name、JSON 非法、编码后仍超过单行上限）。
    /// 过长字符串先截到 `Wire.maxContentBytes`；整行仍超过 `Wire.maxLineBytes` 时逐级收紧上限。
    public static func build(
        stdin: Data,
        agent: String = "claude",
        id: String = UUID().uuidString,
        now: Date = Date(),
        pid: Int32? = nil,
        pidStartedAt: Double? = nil
    ) -> WireRequest? {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: stdin),
              case .object(let obj) = root else { return nil }
        if let event = obj["hook_event_name"]?.stringValue, event != "PreToolUse" { return nil }
        guard let tool = obj["tool_name"]?.stringValue, !tool.isEmpty else { return nil }

        var input: [String: JSONValue] = [:]
        if case .object(let o)? = obj["tool_input"] { input = o }
        let session = obj["session_id"]?.stringValue ?? ""
        let cwd = obj["cwd"]?.stringValue ?? ""

        for limit in [Wire.maxContentBytes, 8 * 1024, 1024] {
            var truncated = false
            let trimmed = input.mapValues { truncate($0, limit: limit, flag: &truncated) }
            let request = WireRequest(
                id: id, session: session, agent: agent, tool: tool, input: trimmed,
                cwd: cwd, ts: Int(now.timeIntervalSince1970), truncated: truncated ? true : nil,
                pid: pid, pidStartedAt: pidStartedAt
            )
            if let line = try? WireCodec.encodeLine(request), line.count <= Wire.maxLineBytes {
                return request
            }
        }
        return nil
    }

    static func truncate(_ value: JSONValue, limit: Int, flag: inout Bool) -> JSONValue {
        switch value {
        case .string(let s):
            guard s.utf8.count > limit else { return value }
            flag = true
            return .string(prefix(s, utf8Bytes: limit))
        case .array(let a):
            var copy = flag
            let out = a.map { truncate($0, limit: limit, flag: &copy) }
            flag = copy
            return .array(out)
        case .object(let o):
            var copy = flag
            let out = o.mapValues { truncate($0, limit: limit, flag: &copy) }
            flag = copy
            return .object(out)
        default:
            return value
        }
    }

    /// 按 UTF-8 字节数截断，不切断多字节字符。
    static func prefix(_ s: String, utf8Bytes limit: Int) -> String {
        var n = limit
        while n > 0 {
            if let r = String(s.utf8.prefix(n)) { return r }
            n -= 1
        }
        return ""
    }
}
