import Foundation

extension RiskClassifier {
    // MARK: Segment

    func assessSegment(_ segment: ShellSegment, depth: Int) -> RiskAssessment {
        var words = segment.tokens[...]
        var dangerousEnv = false
        while let t = words.first, Self.isAssignment(t) {
            if let eq = t.firstIndex(of: "="), Self.isDangerousEnv(String(t[..<eq])) { dangerousEnv = true }
            words = words.dropFirst()
        }
        if dangerousEnv { return RiskAssessment(.high, "dangerous environment override") }
        let rest = Array(words)
        guard let first = rest.first else { return RiskAssessment(.medium, "assignment only") }
        let exe = Self.executableName(first)

        if RiskTables.wrappers.contains(exe) {
            return assessWrapper(exe, args: Array(rest.dropFirst()), depth: depth)
        }
        return assessDirect(first, args: Array(rest.dropFirst()), piped: segment.op == .pipe, depth: depth)
    }

    /// 包装器（env/xargs/timeout…）：对其后每个可能作为命令起点的后缀各评估一次，取最高风险。
    /// 后缀评估时不再展开包装器，所以嵌套 `env env env …` 只是线性开销。
    private func assessWrapper(_ exe: String, args: [String], depth: Int) -> RiskAssessment {
        let floor = RiskTables.wrapperFloor[exe]
        var best: RiskAssessment?
        for j in args.indices where Self.canStartCommand(args[j]) {
            var sub = Array(args[j...])
            var dangerousEnv = false
            while let t = sub.first, Self.isAssignment(t) {
                if let eq = t.firstIndex(of: "="), Self.isDangerousEnv(String(t[..<eq])) { dangerousEnv = true }
                sub.removeFirst()
            }
            let a: RiskAssessment?
            if dangerousEnv {
                a = RiskAssessment(.high, "dangerous environment override")
            } else if let cmd = sub.first {
                a = RiskTables.wrappers.contains(Self.executableName(cmd))
                    ? nil
                    : assessDirect(cmd, args: Array(sub.dropFirst()), piped: false, depth: depth)
            } else {
                a = nil
            }
            if let a, best == nil || a.risk > best!.risk { best = a }
            if best?.risk == .high { break }
        }
        var result = best ?? RiskAssessment(.medium, "wrapper \(exe) without command")
        if let floor, result.risk < floor { result = RiskAssessment(floor, "\(exe) wrapper") }
        return result
    }

    private func assessDirect(_ first: String, args: [String], piped: Bool, depth: Int) -> RiskAssessment {
        if first.contains(where: { "$`*?".contains($0) }) {
            return RiskAssessment(.high, "dynamic command name")
        }
        let exe = Self.executableName(first)
        if let rule = commandRules.first(where: { matches($0, exe: exe, args: args, piped: piped) }) {
            return RiskAssessment(rule.risk, rule.name)
        }
        if RiskTables.shells.contains(exe) { return assessShell(args, depth: depth) }
        if exe == "eval" {
            let inner = assessCommand(args.joined(separator: " "), depth: depth + 1)
            return inner.risk < .medium ? RiskAssessment(.medium, "eval") : inner
        }
        return RiskAssessment(.medium, "unknown command")
    }

    private func assessShell(_ args: [String], depth: Int) -> RiskAssessment {
        guard let flag = args.firstIndex(where: { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("c") }),
              let script = args[(flag + 1)...].first(where: { !$0.hasPrefix("-") })
        else { return RiskAssessment(.medium, "shell script") }
        return assessCommand(script, depth: depth + 1)
    }

    // MARK: Rule matching

    func matches(_ rule: CommandRule, exe: String, args: [String], piped: Bool) -> Bool {
        guard rule.executables.contains(exe) || rule.executablePrefixes.contains(where: { exe.hasPrefix($0) })
        else { return false }
        return Self.holds(rule.when, args: args, piped: piped)
    }

    static func holds(_ c: ArgCondition, args: [String], piped: Bool) -> Bool {
        switch c {
        case .always: return true
        case .anyArg(let set): return args.contains(where: set.contains)
        case .subcommand(let set): return subcommand(of: args).map(set.contains) ?? false
        case .flag(let short, let long): return args.contains { hasFlag($0, short: short, long: long) }
        case .pipedInto: return piped
        case .anyOf(let cs): return cs.contains { holds($0, args: args, piped: piped) }
        case .allOf(let cs): return cs.allSatisfy { holds($0, args: args, piped: piped) }
        }
    }

    /// 跳过全局选项后的第一个非选项参数；遇到会携带代码的选项（`git -c`）返回 nil
    static func subcommand(of args: [String]) -> String? {
        var i = 0
        while i < args.count {
            let a = args[i]
            guard a.hasPrefix("-") else { return a }
            let name = String(a.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[0])
            if RiskTables.codeCarryingOptions.contains(name) { return nil }
            i += RiskTables.globalValueOptions.contains(a) ? 2 : 1
        }
        return nil
    }

    static func hasFlag(_ token: String, short: Set<Character>, long: Set<String>) -> Bool {
        guard token.hasPrefix("-"), token.count > 1 else { return false }
        if long.contains(token) || long.contains(where: { token.hasPrefix($0 + "=") }) { return true }
        if token.hasPrefix("--") { return false }
        return token.dropFirst().contains(where: short.contains)
    }

    // MARK: Token helpers

    static func isAssignment(_ t: String) -> Bool {
        guard let eq = t.firstIndex(of: "="), eq != t.startIndex else { return false }
        let name = t[..<eq]
        guard let f = name.first, f.isASCII, f.isLetter || f == "_" else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    static func isDangerousEnv(_ name: String) -> Bool {
        RiskTables.dangerousEnvVars.contains(name)
            || RiskTables.dangerousEnvPrefixes.contains(where: name.hasPrefix)
    }

    /// 取 basename 并转小写（macOS 默认大小写不敏感，`/bin/RM` 也能执行）
    static func executableName(_ token: String) -> String {
        (token as NSString).lastPathComponent.lowercased()
    }

    /// 包装器之后，选项和纯数字/时长（`-n 10`、`5s`）不会是命令起点
    static func canStartCommand(_ token: String) -> Bool {
        if token.hasPrefix("-") { return false }
        let number = token.dropLast(token.last.map { "smhd".contains($0) } == true ? 1 : 0)
        return number.isEmpty || !number.allSatisfy { $0.isASCII && ($0.isNumber || $0 == ".") }
    }
}
