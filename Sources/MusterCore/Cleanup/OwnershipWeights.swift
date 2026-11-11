import Foundation

/// R9：进程归属启发式的全部权重与阈值都在这个文件里，别处不许写死。
/// 用整数「分」而不是浮点，避免 0.1 + 0.2 之类的比较误差；满分 100 → 置信度 1.0。
public struct OwnershipWeights: Equatable, Sendable {
    /// 在 session 进程树内（或曾在树内，见 `TreeEvidence.formerTree`）
    public var processTree = 40
    /// 进程 cwd 位于 session cwd 之下（按路径分量匹配，不是字符串前缀）
    public var cwdPrefix = 30
    /// 进程启动时间不早于 session 启动时间
    public var startedAfterSession = 15
    /// 命令行含 dev server / 构建工具关键词
    public var commandKeyword = 15

    /// 低于此分数 = 「不确定」，默认不勾选，且执行层要求二次确认
    public var confidentThreshold = 80
    /// 低于此分数的进程不在清理面板里出现
    public var displayFloor = 30

    /// 启动时间比较的容差（秒）
    public var startTimeTolerance: TimeInterval = 1

    /// 命令行 token 命中其一即算关键词匹配（小写，整词或 `词-` 前缀）
    public var keywords: [String] = [
        "node", "npm", "npx", "pnpm", "yarn", "bun", "deno", "vite", "next", "nuxt", "webpack",
        "esbuild", "tsx", "ts-node", "nodemon", "python", "python3", "uvicorn", "gunicorn",
        "flask", "django", "rails", "ruby", "cargo", "swift", "go", "php", "storybook",
    ]

    public init() {}

    public static let `default` = OwnershipWeights()

    public var maxPoints: Int { processTree + cwdPrefix + startedAfterSession + commandKeyword }
}
