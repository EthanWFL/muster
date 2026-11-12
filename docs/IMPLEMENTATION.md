# Muster — 落地实施文档（v0.1）

> 对应需求：`~/.pi/agent-panel-prd.md`（PRD v0.1）。本文回答「怎么做、按什么顺序、怎么验收」。
> 标注 **【待验证】** 的内容是基于文档/经验的假设，必须在 M0 实测后回填，不得当作事实。

---

## 0. 环境与约束

| 项 | 现状 |
|---|---|
| Swift | 6.3.2（arm64，macOS 27.2） |
| 工具链 | 仅 Command Line Tools，**无完整 Xcode**（无 `xcodebuild`、Instruments、SwiftUI 预览） |
| 可用 | `swift build/test`、`codesign`、`iconutil`、`notarytool`、`lsof` |
| 本机 agent | 已装 Claude Code 2.1.292；`codex` / `cursor` / `opencode` 命令均未找到（`~/.codex` 目录存在） |
| 仓库 | 空骨架：`Sources/Muster`、`Sources/muster-hook`、`Tests/MusterTests`、`Scripts/`、`Resources/`，尚无提交 |

**结论性决策**

1. 构建系统：**SPM + 打包脚本**，不建 Xcode 工程。
2. 语言模式：先用 Swift 5 模式（`swiftLanguageModes: [.v5]`），避免 socket/多线程代码被 Swift 6 严格并发卡住；稳定后再评估升 6。
3. v1 范围：**Claude Code 完整闭环（审批 + 会话 + 清理）**；Codex 只读监控；Cursor / opencode 只留 adapter 桩。原因见 §9。
4. 零第三方依赖，直到 M5 才引入 Sparkle。
5. 待办：仓库里的 `.gitignore` 目前是一个**目录**而不是文件，需先删掉重建（见 M1 第 1 步）。

---

## 1. 架构总览

```
┌──────────────── Claude Code ────────────────┐
│ PreToolUse hook ──exec──▶ muster-hook   │  独立小二进制，无 UI 依赖
└──────────────────────────────┬──────────────┘
                               │ Unix socket (NDJSON)
                               ▼
┌───────────────────── Muster.app ─────────────────────┐
│ SocketServer ─▶ ApprovalStore ◀─▶ SwiftUI 面板           │
│                     │                                    │
│ AgentAdapter(s) ─▶ SessionStore                          │
│ ProcessScanner / WorktreeScanner ─▶ CleanupPlanner       │
└──────────────────────────────────────────────────────────┘
```

**关键设计原则**

- **fail-safe 优先**：`muster-hook` 任何异常（连不上、超时、解析失败、崩溃）都必须表现为「无决策」，行为等同未安装。
- hook 二进制与 app **只通过 socket 协议耦合**，不共享代码以外的状态。
- 所有「会改变系统状态」的动作（kill、prune、写配置）统一走 `Action` 抽象：先生成 **计划（命令 + 影响对象）**，再执行，且展示与执行用同一份数据（满足 R7）。

---

## 2. 目录与 Target 规划

```
Package.swift
Sources/
  MusterCore/          # 纯逻辑库，无 UI，可测试
    Model/                 # Session, ToolCall, Risk, Decision
    Protocol/              # Socket 消息编解码（v1）
    Adapters/              # AgentAdapter + ClaudeAdapter + CodexAdapter
    Approval/              # ApprovalStore, RiskClassifier, SimilarRule
    Cleanup/               # ProcessScanner, OwnershipHeuristic, WorktreeScanner, CleanupPlan
    Support/               # Logger(轮转), Paths, Clock(可注入)
  Muster/              # 可执行：SwiftUI app，仅 UI + 装配
  muster-hook/         # 可执行：hook 客户端，仅依赖 Protocol 的极小子集
Tests/
  MusterCoreTests/
  MusterTests/         # UI 装配层的少量测试
Scripts/
  package.sh               # 组装 .app + Info.plist + codesign
  fake-hook.sh             # M0 验证用
  install-hooks.sh         # 开发期手动装/卸 hook（正式逻辑在 Adapter.installHooks）
Resources/
  Info.plist.template
  AppIcon.iconset/
docs/
  IMPLEMENTATION.md        # 本文
  M0-findings.md           # M0 验证结论（M0 产出）
```

`muster-hook` 不依赖 `MusterCore` 的全部内容，避免二进制变大、启动变慢（hook 每次工具调用都会被启动，**冷启动 < 30ms** 是目标）。协议编解码放进一个独立的小 target `MusterProtocol`，由 Core 和 hook 共同依赖。

---

## 3. 里程碑详细拆解

PRD 估时 7.5 天，考虑 Swift 菜单栏 app 的焦点/键盘坑与无 Xcode 的调试成本，**实际按 2～3 周规划**。

### M0 — hook 阻塞验证（0.5～1d）🔴 决定路线

**目标**：回答 PRD §11 的问题 1，并产出 `docs/M0-findings.md`。

步骤：

1. 写 `Scripts/fake-hook.sh`：读 stdin JSON → 打印到日志文件 → `sleep $N` → 按参数输出决策。
2. 在 **临时的项目级** `.claude/settings.local.json`（不碰全局配置）里注册 `PreToolUse` hook。
3. 用 `claude -p` 或交互会话触发 `Bash` 工具调用，逐项实验：

| # | 实验 | 要回答的问题 |
|---|---|---|
| E1 | hook sleep 5s 后 exit 0 | 父进程是否等待？工具是否正常执行？ |
| E2 | hook sleep 100s 后 exit 0，`timeout` 不设 | 默认硬超时是多少？超时后是放行还是阻止？ |
| E3 | 同上，hook 配置里 `timeout: 120` | 能否阻塞 ≥ 90s？ |
| E4 | exit 2 + stderr 文本 | 是否阻止执行？stderr 是否回传给模型？ |
| E5 | stdout 输出 JSON `permissionDecision: "allow"` | 是否真的跳过原生确认？ |
| E6 | stdout 输出 JSON `permissionDecision: "deny"` + reason | 同 E4，对比两种 deny 路径 |
| E7 | stdout 输出 `permissionDecision: "ask"` 或空输出 exit 0 | 「无决策」应该用哪种？是否回落到原生提示？ |
| E8 | 并发：同时有 3 个 hook 在等 | 是否互相阻塞？（子 agent / 并行工具调用场景） |
| E9 | hook 被 SIGKILL / 二进制不存在 | 此时 Claude 行为是什么？（R2 兜底依据） |
| E10 | 已有 allow 规则命中的命令 | hook 是否仍被调用？顺序如何？ |
| E11 | 记录 stdin 里实际有哪些字段 | `session_id`、`cwd`、`tool_name`、`tool_input`、`transcript_path` 是否齐全 |

> **【待验证】** 已知 Claude Code hook 文档的大致语义：exit 0 = 成功，exit 2 = 阻止并把 stderr 反馈给模型，也支持 JSON 输出的 `hookSpecificOutput.permissionDecision`（allow/deny/ask），hook 有可配置的 `timeout`（默认值需实测）。以上全部以实测为准。

**出口判定**

- ✅ 能阻塞 ≥ 90s 且「无决策」能回落原生提示 → 进入 M1，走主方案。
- ⚠️ 能阻塞但上限 < 90s → 把 R1 的超时改为 `min(90, 上限 - 5)` 秒，记录在 PRD §11。
- ❌ 不能长阻塞 → 启动降级方案（PRD §5.2：事后上报 + proxy），**暂停 M2，与用户重新评审范围**。

### M1 — 骨架 + Adapter + 会话列表（2～3d）

1. 修复 `.gitignore`（删目录，写文件：`.build/`、`*.app`、`.DS_Store`、`.swiftpm/`、`dist/`），首次提交。
2. 写 `Package.swift`：Core 库、Protocol 库、两个可执行 target、测试 target，平台 `.macOS(.v14)`。
3. 数据模型（按 PRD §6，`ToolCall.input` 用 `[String: JSONValue]` 自定义枚举代替 `[String: Any]`，保证 `Codable`/`Sendable`）。
4. `AgentAdapter` 协议（第一天定死，PRD 要求）。`decide` 在 Claude 上是「通过 socket 回写决策」，不是写文件。
5. `ClaudeAdapter.sessions()`：
   - 数据源 **【待验证】**：`~/.claude/projects/<编码后的cwd>/*.jsonl`（mtime = 最后活动），以及 hook 上报的实时事件。
   - 只依赖最少字段（`sessionId`、`cwd`、时间戳），未知字段忽略；解析失败的行跳过并记日志。
   - **只读，不复制 transcript 内容**（PRD §7 隐私）。
6. `SessionStore`：合并「落盘推断」与「hook 实时事件」，hook 事件优先；状态机 `running → waiting → idle → ended`，`ended` 判定用「进程不存在或 N 分钟无活动」，阈值写成常量并可测。
7. 菜单栏骨架：`MenuBarExtra(.window)`、`LSUIElement`、四个 Tab、会话页。
8. `Scripts/package.sh` 的**最小版**：能把 `swift build -c release` 产物装进 `.app` 并启动（`Info.plist` 此时就要有 `LSUIElement`）。

**验收**：新开一个 Claude session，5s 内出现；结束后 30s 内变灰（PRD §5.3）。

### M2 — 审批闭环（3～4d）🟠 最难

**子任务**

| # | 内容 | 要点 |
|---|---|---|
| 2.1 | `SocketServer` | POSIX `socket/bind/listen/accept` 或 `Network.framework`；路径 `~/Library/Application Support/Muster/agentd.sock`，启动时检查**长度 < 104 字节**，权限 `0600`，目录 `0700`；残留 socket 文件启动时先探测再清理 |
| 2.2 | 连接生命周期 | 每个 request 对应一个长连接；**连接断开 = 该请求立即作废**（hook 被杀/Claude 中断时面板条目自动消失） |
| 2.3 | `muster-hook` | 读 stdin → 连 socket → 写 request → 阻塞读 decision → 按决策退出；连不上/超时/任何异常 → 「无决策」。**自带本地超时**（比 app 侧略长，作为双保险） |
| 2.4 | `ApprovalStore` | 状态机 `pending → allowed/denied/expired`；排序 = 危险度降序 + 等待时长降序，**稳定排序**（相同键保持到达顺序）；R5 折叠：key = `(session, tool, 规范化命令)`，累计计数 |
| 2.5 | `RiskClassifier` | 规则表驱动，写成数据不写成 if 链。高：`rm -rf`/`sudo`/`git push`/`curl\|sh`/`chmod`/网络类；中：Write/Edit/装依赖；低：Read/Grep/Glob。**未知一律按中**，不按低。要有对抗用例（`rm  -rf`、`;`/`&&` 串联、`$(…)`、别名） |
| 2.6 | 「允许同类（本会话）」 | 规则 = `tool_name` + 命令前缀（取到第一个操作符/管道前的前 N 个 token）。**仅内存，随 session 结束清除**；高危命令默认不提供此选项或需额外确认 |
| 2.7 | 超时 R1 | app 侧计时器 90s（以 M0 结论为准）→ 返回 `no_decision` 并移除条目；hook 侧另有保险超时 |
| 2.8 | 拒绝 R3 | 拒绝必须带原因，默认预填一句话，可编辑；回传方式以 M0 E4/E6 结论为准 |
| 2.9 | 面板键盘交互 | `j/k` 选择、`⏎`、`⌫`、`⌥⏎`、`⇧⏎`、`⌘⏎`；用 `.onKeyPress`（macOS 14+）+ 焦点状态；**面板打开时必须能自动获得键盘焦点**（`MenuBarExtra` 窗口的常见坑，需实测） |
| 2.10 | 角标 | 菜单栏图标显示 `pending` 计数；用 `MenuBarExtra` 的 label 视图，计数为 0 时不显示数字 |
| 2.11 | `installHooks` / 卸载 | 见 §6 |
| 2.12 | 永久允许 R4 | 先展示将追加的配置片段，二次确认，原子写入（见 §6） |
| 2.13 | 跳到终端（`⌘⏎`） | 见 M3.5 |

**验收**（来自 PRD §5.1，加上可自动化的部分）

- [ ] 3 个 agent 同时请求，队列顺序稳定，角标数正确
- [ ] 杀掉 app 后，agent 仍走原生确认，不卡死、不自动放行
- [ ] 拒绝后 agent 收到原因文本，且工具未执行
- [ ] 90s 超时后 agent 走原生提示，面板条目消失
- [ ] 自动化：用 `muster-hook` + 模拟客户端对 `SocketServer` 做集成测试（并发 50 请求、半途断连、超长行、非法 JSON）

### M3 — 环境清理 + 会话跳转（2d）

1. `ProcessScanner`：优先用 `libproc`（`proc_listpids`、`proc_pidinfo`、`proc_pidpath`）读进程树、cwd、启动时间；端口用 `lsof -iTCP -sTCP:LISTEN -nP -F`（机器可读格式）。**所有外部命令封装成可注入的 `CommandRunner` 协议**，测试时用桩。
2. `OwnershipHeuristic`（R9）：`cwd 前缀匹配 + 启动时间晚于 session + 命令行关键词 + 是否在 session 进程树内`，每项给权重，输出 0～1 置信度；**< 0.8 标「不确定」、默认不勾选**；权重与阈值集中在一个文件。
3. `OrphanDetector`：曾归属某 session、`ppid == 1`、CPU > 60% 持续 5 分钟（需要采样历史，用环形缓冲，注意内存）。
4. `WorktreeScanner`：对每个已知项目 cwd 跑 `git worktree list --porcelain`；判定「目录不存在 / 分支已合并」。默认只 `git worktree prune`（元数据），**删目录是独立的、二次确认的动作**。
5. 会话「跳到终端」：先用 TTY / 进程祖先找到所属终端 app，再用 `NSAppleScript` 聚焦 Terminal / iTerm2 窗口；**失败不弹窗，退化为复制 `cd <cwd>` 到剪贴板**。辅助功能权限可选，被拒走降级。
6. `CleanupPlan`：生成「将执行的命令列表」，UI 展示的文本与执行的 `argv` 来自同一个对象（R7）。执行结果入 `CleanupReport`（释放端口、删除目录、回收磁盘，R8）。

**安全硬约束（R6）——在执行层强制，不只在 UI 层**

```text
执行 kill 之前，Executor 内部必须再次校验：
  pid > 1
  pid != getpid()
  pid 仍属于当初规划时的同一个进程（比对 pid + 启动时间，防止 PID 复用）
  已在 session 进程树内，或用户对该项做过显式二次确认
任一不满足 → 拒绝执行并记日志
只发 SIGTERM；10s 后仍存活才在 UI 上提示是否 SIGKILL（需再次点击）
```

**验收**

- [ ] 起一个前台 dev server，归到正确 session 并显示端口
- [ ] 3 个失效 worktree 的仓库 prune 后状态正确
- [ ] 零误杀测试：构造一批非 agent 进程（含同 cwd 前缀的无关进程、PID 复用场景、pid=1、自身），**断言 Executor 一律拒绝**

### M4 — 规则扫描（已下线）

原本要做的事：跨仓库扫 `CLAUDE.md` / `AGENTS.md` / `.cursorrules` / `.github/copilot-instructions.md`，报重复规则、失效引用、跨仓库冲突。

2026-11-12 决定整块下线：这个页面真正的目标其实是「一份规则同步到本机所有 agent」，而那件事由 `M4.5 指令同步` 直接完成了。因此删掉了：

- `MusterCore/Rules/*`（RuleScanner、DuplicateDetector、RefChecker、ContradictionDetector、RuleParser、RuleSuggestion、RuleTextNormalizer 及其测试）
- `Muster/RulesView.swift`、`Muster/RulesModel.swift`、`Rules` tab，以及「忽略」用的 `MusterIgnoredFindings`

`~/Code` 下的仓库级 `AGENTS.md` 仍然**只读不写**（那是 git 跟踪文件，改动应该走 diff/review）。要重新引入，从 git 历史里取回即可。

### 设置页

设置并进面板，不再开独立窗口：

- 面板页脚「设置 ⌘,」切换 `PanelModel.showsSettings`，内容区换成 `SettingsView`（启动 / 外观 / 标签顺序 / 快捷键 / 审批 / 更新 / 关于，一屏滚动），顶部 tab 条隐藏；⎋ 或「返回」退回主视图。
- 旧实现走 `NSApp.sendAction(showSettingsWindow:)` 开 SwiftUI `Settings` 场景，在 accessory App（无 Dock 图标）里经常只返回 true 不弹窗，已删除。
- 标签顺序存在 `UserDefaults` 的 `MusterTabOrder`，面板 tab 条按它渲染，未知值丢弃、新增 tab 自动补到末尾。

### M4.5 — 指令同步（「指令」页）

一份共享指令写进各 agent 的**用户级**指令文件，参考 magpie 的标记块实现（`internal/library/instructions.go`）。

- `AgentCatalog`（`InstructionTargets`）：agent → 指令文件路径，尊重 `CLAUDE_CONFIG_DIR` / `CODEX_HOME` / `PI_CODING_AGENT_DIR` / `DSH_HOME`；已存在的优先，没装的不写。Codex / Pi 存在 `AGENTS.override.md` 时它优先级更高，直接指向它（`redirectedFrom` 记着被取代的 `AGENTS.md`），否则写进 `AGENTS.md` 会被盖掉。
- `InstructionBlock`：`split` / `own` / `withBlock` / `ownLineCount` / `hash`。段由 `<!-- muster:begin … -->` 与 `<!-- muster:end -->` 框住，追加在用户已有内容之后；撤销时只撤这一段。
- `InstructionSync`：`plan`（只读，算出写入后的整份文件 + 动作）与 `apply`（先备份到 `~/Library/Application Support/Muster/backups/<ts>/<agent>/`，保留 10 份，原子写）。
- 多套指令：默认那套在 `instructions.md`，其余在 `instruction-sets/<id>.md`；`instructions.json` 记 `activeSet` 与 `sets`，切换一套 = 换写入的文本（旧的解码走 `decodeIfPresent`，不会把开关丢掉）。
- 状态 `instructions.json` 记录开关与上次写入的段指纹，用来识别手改。
- 备份回滚：每次写前留一份原文件（`backups/<时间戳带毫秒>/<agent>/<文件名>` + `manifest.json` 记原始路径与时间，保留 10 份）；某行的预览里可以直接「恢复」，恢复前会先把当前文件再备份一次，所以恢复本身也能撤销。
- 编辑即存：改完 1.2 秒落盘到当前这套的文件，退出 App 不丢；「保存」只是立刻落盘的按钮。
- 多套指令可新建 / 重命名 / 删除；删掉的只是这套的文本文件，默认那套不能删。
- 切换一套会把新文本直接写进已开启的 agent（换套即生效）。
- 预览有两种：段 diff（`-`/`+`）和整份写入后的文件，用来确认段落在文件里的位置。
- 三条安全线：共享指令为空时绝不自动撤段（库被重置不等于用户要撤销）、文件读不到视为未知不写、只由用户关开关才撤段。
- 仓库级 `AGENTS.md` 只生成/复制，不自动写（会改 git 跟踪文件）。

### M5 — 打包、签名、更新、引导（1～2d）

- `Scripts/package.sh` 完整版：`.app` 结构、`Info.plist`（版本号、`LSUIElement`、最低系统）、图标（`iconutil` 从 `.iconset` 生成 `.icns`）、`codesign`、生成 `.dmg`。
- **签名决策（PRD §11 Q5）**：v1 先「自签/ad-hoc + 右键打开」；有开发者账号后再加 `notarytool` + Sparkle（Sparkle 需 EdDSA 密钥与 appcast 托管，**与「零网络」冲突，必须做成可关闭，并在文档中明示**）。
- 首次引导：检测已装 agent → 展示将要修改的配置 → 备份 → 安装 hook → 可选辅助功能授权；一键卸载。
- 「导出诊断」：打包日志 + 版本信息，**脱敏**（不含 transcript、命令参数全文）。

---

## 4. 协议与 hook 契约

沿用 PRD §6，补充实现细节：

- 版本字段 `v`：未知版本 → 回 `no_decision`，不报错。
- 每行一个 JSON，**单行上限 1 MB**（超长直接断开，防内存攻击与误用）。
- `request` 中 `input` 可能很大（Write 的整文件内容）：hook 端可截断 `content` 类字段到 64KB 再上报，并带 `truncated:true`。
- `decision` 的 `ttl_ms` 由 app 给出，hook 以 `min(ttl_ms, 本地上限)` 为准。
- hook 的**退出语义映射**（【待验证】，以 M0 为准）：

| decision | hook 行为 |
|---|---|
| `allow` / `allow_similar` | 输出允许 JSON（或 exit 0），具体以 E5 结论为准 |
| `deny` | exit 2 + stderr 写 `reason`，或 deny JSON，以 E4/E6 为准 |
| `no_decision` | 无输出 exit 0，或 `ask`，以 E7 为准 |

- 本机 socket 安全：目录 `0700`、socket `0600`，accept 后用 `getpeereid` 校验对端 uid == 当前用户。

---

## 5. 测试策略

| 层 | 工具 | 重点 |
|---|---|---|
| 单元 | Swift Testing（`Scripts/test.sh`） | RiskClassifier、Jaccard、Ownership 评分、Protocol 编解码、状态机 |
| 集成 | Swift Testing + 临时目录 + 假 socket 客户端 | SocketServer 并发/断连/超时；worktree 用真实 `git` 在 tmp 建仓库 |
| 安全 | 专门的 `NoCollateralKillTests` | R6 全部用例；CI 里不可跳过 |
| 手工 | 清单（见 §8） | 键盘焦点、面板失焦、终端聚焦、真实 Claude 端到端 |
| 时间 | 注入 `Clock` 协议 | 90s 超时、5 分钟 CPU 持续等逻辑不 `sleep` 实时等 |

约定：**一切涉及时间、进程、文件系统、外部命令的代码都通过协议注入**，否则 R6/R1 无法稳定测试。

---

## 6. 配置写入与回滚（PRD §11 Q3）

`installHooks()` / 「永久允许」都会改用户配置，规则：

1. 写前**完整备份**到 `~/Library/Application Support/Muster/backups/<时间戳>/…`。
2. **原子写**：写临时文件 → `fsync` → `rename`。
3. 只**追加/合并**自己的条目，并用唯一标记（如 hook 命令路径含 `muster-hook`）识别，卸载时只移除这些条目，**不整文件还原**（避免覆盖用户之后的手改）。
4. 解析 JSON 失败 / 出现未知 schema → **拒绝写入**并提示，不尝试修复。
5. 写之前展示 diff（R4 同理）。
6. 提供 `uninstall` 并有测试：安装→卸载后文件与原文件语义一致。
7. 开发期优先写 **项目级** `.claude/settings.local.json` 做试验，稳定后才碰 `~/.claude/settings.json`。

---

## 7. 非功能落实

| PRD 要求 | 落实方式 |
|---|---|
| 面板打开 < 150ms | 面板视图用已缓存的 Store 数据渲染，不在打开时同步扫描；重扫描全部后台 |
| 空闲 CPU < 0.3% | 无轮询空转：session 推断用 `DispatchSource` 文件监听 + 低频兜底定时器（≥ 5s）；CPU 采样仅在「环境」页可见或有关联 session 时进行 |
| 内存 < 120MB | transcript 只读 tail、不全量加载；历史缓冲定长环形 |
| 8h 无泄漏 | socket 连接/Task 全部有明确所有者与取消；手工长跑（无 Instruments 时用 `leaks`/`vmmap`/`footprint` 命令行工具抽查） |
| 日志轮转 10MB×3 | `Logger` 自实现简单轮转；默认不记录命令全文，仅记录哈希/长度（隐私） |
| 隐私 | v1 不引入任何网络代码；CI 里加一条 `grep` 检查禁用 `URLSession` 等 API（Sparkle 例外，隔离在独立 target 并可关闭） |

---

## 8. 手工验收清单（发布前逐项勾）

- [ ] 冷启动后菜单栏出现图标，无 Dock 图标
- [ ] `⌃⌥A` 打开面板（权限被拒时的替代入口可用）
- [ ] 打开面板后无需点击即可用 `j/k/⏎/⌫`
- [ ] 点击面板外部自动收起，不丢失待审批条目
- [ ] 3 个并发请求，排序、角标正确
- [ ] 退出 app → 触发工具调用 → agent 原生提示正常
- [ ] app 被 `kill -9` → 同上，且无残留卡死的 hook 进程
- [ ] 睡眠/唤醒后 socket 仍可用
- [ ] 拒绝原因出现在 agent 侧
- [ ] 安装 hook → 卸载 hook → 配置文件与安装前一致
- [ ] 清理流程：展示命令 = 实际执行命令
- [ ] 连续运行 8h：内存与 CPU 在指标内

---

## 9. 风险与决策日志

| # | 风险/问题 | 应对 | 状态 |
|---|---|---|---|
| D1 | hook 不能长阻塞 | M0 先验证，失败则降级评审 | 待 M0 |
| D2 | 仅 Claude 有可验证的 hook | v1 只做 Claude 审批；Codex 只读；记录到 PRD §11 Q2 | 建议采纳，待确认 |
| D3 | agent 私有格式变动 | 容错解析 + 最少字段 + 版本探测 + fixture 测试 | 设计内 |
| D4 | PID 复用导致误杀 | 计划时记录 pid+启动时间，执行前复核 | 设计内 |
| D5 | `MenuBarExtra` 焦点/键盘行为不可控 | M2 早期做最小原型验证；不行则改用 `NSStatusItem + NSPanel` 自管窗口 | 待 M2 |
| D6 | 无 Xcode 无法用 Instruments | 命令行 `leaks`/`footprint`；必要时再装 Xcode | 可接受 |
| D7 | 全局热键是否需辅助功能权限 | 用 Carbon `RegisterEventHotKey`（通常不需要该权限）**【待验证】**；失败则只保留菜单栏点击 | 待 M2 |
| D8 | Sparkle 与「零网络」冲突 | 默认关闭、可选开启、文档明示 | M5 前决定 |
| D9 | Swift 6 严格并发 | 先 Swift 5 模式；边界类型显式 `Sendable` | 设计内 |

---

## 10. 建议的执行顺序（一页纸版）

```
M0 验证（先出结论）
 └─ 通过 → M1 骨架/会话 → M2 审批 → M3 清理/跳转 → M4 指令同步 → M5 打包
 └─ 不通过 → 暂停，重评审 F1 的方案
```

每个里程碑结束：`Scripts/test.sh` 全绿 → 更新本文状态/PRD §11 → 提交一次。

**下一步行动**：开始 M0，先写 `Scripts/fake-hook.sh` 与 `.claude/settings.local.json` 试验配置。

---

## 附：本机测试注意事项

本机只有 Command Line Tools，没有 XCTest，且 SwiftPM 不会自动给 `Testing.framework` 加 `-F` 和 rpath。
**一律用 `Scripts/test.sh` 跑测试，不要直接 `swift test`。** 多个 agent 并行时各自加 `--scratch-path .build-xxx`。
`--filter` 匹配的是套件/用例名，不是目录名。
