import Foundation

/// 命令参数条件，纯数据，由 `RiskClassifier` 解释。
public indirect enum ArgCondition: Sendable, Equatable {
    case always
    /// 任意位置的参数等于集合之一（保守，用于高危判定）
    case anyArg(Set<String>)
    /// 子命令（跳过全局选项后的第一个非选项参数）属于集合（严格，用于降级到低危）
    case subcommand(Set<String>)
    /// 含任一短选项字符（`-rf` 中的 r、f）或等于/以 `=` 开头的长选项
    case flag(short: Set<Character>, long: Set<String>)
    /// 位于管道右侧（stdin 被当作代码执行）
    case pipedInto
    case anyOf([ArgCondition])
    case allOf([ArgCondition])
}

/// 规则按表顺序首个匹配生效，所以特殊规则要排在通用规则之前。
public struct CommandRule: Sendable, Equatable {
    public let name: String
    public let executables: Set<String>
    public let executablePrefixes: [String]
    public let when: ArgCondition
    public let risk: Risk

    public init(
        _ name: String, _ executables: Set<String>, prefixes: [String] = [],
        when: ArgCondition = .always, _ risk: Risk
    ) {
        self.name = name
        self.executables = executables
        self.executablePrefixes = prefixes
        self.when = when
        self.risk = risk
    }
}

public struct ToolRule: Sendable, Equatable {
    public let name: String
    /// 小写
    public let tools: Set<String>
    public let risk: Risk

    public init(_ name: String, _ tools: Set<String>, _ risk: Risk) {
        self.name = name
        self.tools = tools
        self.risk = risk
    }
}

public enum RiskTables {
    /// 执行命令字符串的工具名（小写）
    public static let shellTools: Set<String> = [
        "bash", "shell", "run_terminal_cmd", "execute_bash", "exec_command", "local_shell",
        "terminal", "run_shell_command",
    ]

    /// 本身不决定风险、把后续参数当命令执行的前缀；取其后各后缀的最高风险
    public static let wrappers: Set<String> = [
        "env", "command", "builtin", "exec", "nohup", "time", "nice", "ionice", "timeout",
        "stdbuf", "caffeinate", "setsid", "watch", "xargs", "!", "{", "}",
        "if", "then", "elif", "else", "while", "until", "do",
    ]
    /// 作为包装器出现时的风险下限
    public static let wrapperFloor: [String: Risk] = ["xargs": .medium, "watch": .medium]

    public static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish", "csh", "tcsh"]

    /// 后面的参数是代码，不适合做「允许同类」前缀
    public static let codeRunners: Set<String> =
        wrappers.union(shells).union([
            "eval", "source", ".", "python", "python3", "node", "deno", "bun", "ruby", "perl",
            "php", "osascript", "awk", "gawk", "sed", "find", "ssh", "lua", "swift", "make",
        ])

    public static let globalValueOptions: Set<String> = [
        "-C", "-c", "--git-dir", "--work-tree", "--namespace", "--prefix", "--cwd", "--dir",
    ]

    /// 子命令之前出现就意味着「后面的参数不止是子命令」，不能降到低危（git -c core.pager=...）
    public static let codeCarryingOptions: Set<String> = ["-c", "--config-env", "--exec-path"]

    /// 命令前缀里设置这些变量会改变后续命令的实际行为，一律按高危
    public static let dangerousEnvVars: Set<String> = [
        "PATH", "BASH_ENV", "ENV", "SHELLOPTS", "PS4", "PROMPT_COMMAND", "IFS", "GIT_SSH_COMMAND",
        "GIT_EXTERNAL_DIFF", "GIT_ASKPASS", "NODE_OPTIONS", "PYTHONPATH", "PYTHONSTARTUP", "RUBYOPT",
        "PERL5OPT",
    ]
    public static let dangerousEnvPrefixes: [String] = ["DYLD_", "LD_"]

    /// 摘要优先展示的 input 字段（按顺序取第一个字符串值）
    public static let summaryKeys: [String] = [
        "command", "cmd", "file_path", "filePath", "path", "notebook_path", "pattern", "url", "query",
        "description", "prompt",
    ]
    /// 这些字段是路径，摘要里相对 cwd 显示
    public static let pathKeys: Set<String> = ["file_path", "filePath", "path", "notebook_path"]

    private static let installVerbs: Set<String> = [
        "install", "i", "add", "ci", "update", "upgrade", "remove", "uninstall", "sync",
        "resolve", "require", "get", "bundle", "deps.get",
    ]

    public static let commandRules: [CommandRule] = [
        // 高
        .init("privilege escalation", ["sudo", "doas", "su", "pkexec"], .high),
        .init("pipe into interpreter", ["sh", "bash", "zsh", "dash", "ksh", "fish", "python", "python3",
                                        "node", "ruby", "perl", "php", "osascript", "source", "."],
              when: .pipedInto, .high),
        .init("recursive/forced delete", ["rm"],
              when: .flag(short: ["r", "R", "f"], long: ["--recursive", "--force"]), .high),
        .init("secure delete", ["shred", "srm", "unlink"], .high),
        .init("git remote/destructive", ["git"],
              when: .anyOf([
                .anyArg(["push", "pull", "fetch", "clone", "ls-remote", "clean", "filter-branch"]),
                .allOf([.anyArg(["reset"]), .anyArg(["--hard"])]),
              ]), .high),
        .init("permissions", ["chmod", "chown", "chgrp", "chflags", "setfacl"], .high),
        .init("network", ["curl", "wget", "nc", "ncat", "netcat", "nmap", "ssh", "scp", "sftp", "rsync",
                          "ftp", "tftp", "telnet", "socat", "ssh-copy-id"], .high),
        .init("cloud/cluster CLI", ["gh", "aws", "gcloud", "az", "kubectl", "helm", "terraform", "twine"], .high),
        .init("publish/push", ["npm", "yarn", "pnpm", "cargo", "docker", "podman"],
              when: .anyArg(["publish", "push"]), .high),
        .init("disk/system", ["dd", "diskutil", "fdisk", "hdiutil", "mount", "umount", "launchctl",
                              "systemctl", "shutdown", "reboot", "halt", "kill", "killall", "pkill",
                              "crontab", "osascript", "networksetup", "scutil", "pmset", "csrutil",
                              "spctl", "tccutil"],
              prefixes: ["mkfs", "newfs"], .high),
        .init("find destructive", ["find"],
              when: .flag(short: [], long: ["-delete", "-exec", "-execdir", "-ok", "-okdir"]), .high),
        // 中
        .init("find writes files", ["find"],
              when: .flag(short: [], long: ["-fprint", "-fprint0", "-fprintf", "-fls"]), .medium),
        .init("sed in-place", ["sed"], when: .flag(short: ["i"], long: ["--in-place"]), .medium),
        .init("delete", ["rm", "rmdir"], .medium),
        .init("dependency install", ["npm", "yarn", "pnpm", "bun", "pip", "pip3", "uv", "poetry",
                                     "gem", "bundle", "cargo", "go", "brew", "apt", "apt-get", "yum",
                                     "dnf", "composer", "swift", "pod", "mix", "conda"],
              when: .subcommand(installVerbs), .medium),
        // 低
        .init("git read-only", ["git"],
              when: .subcommand(["status", "log", "diff", "show", "blame", "ls-files", "rev-parse",
                                 "describe", "shortlog", "grep"]), .low),
        .init("read-only", ["ls", "cat", "head", "tail", "wc", "grep", "egrep", "fgrep", "rg", "ag", "fd",
                            "find", "pwd", "echo", "printf", "true", "false", "which", "type", "whereis",
                            "stat", "file", "diff", "cmp", "sort", "uniq", "cut", "tr", "tree", "du", "df",
                            "ps", "date", "whoami", "id", "uname", "hostname", "basename", "dirname",
                            "realpath", "readlink", "cd", "test", "[", "[[", "sleep", "jq", "less", "more",
                            "md5", "shasum", "xxd", "done", "fi", "esac"], .low),
    ]

    public static let toolRules: [ToolRule] = [
        .init("read-only tools",
              ["read", "grep", "glob", "ls", "notebookread", "todowrite", "todoread", "bashoutput",
               "read_file", "grep_search", "file_search", "list_dir", "codebase_search"], .low),
        .init("file writes",
              ["write", "edit", "multiedit", "notebookedit", "edit_file", "write_file", "apply_patch",
               "str_replace_editor"], .medium),
        .init("web/agents", ["webfetch", "websearch", "task", "agent"], .medium),
    ]
}
