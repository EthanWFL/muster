# Muster

macOS 菜单栏上的 agent 控制台。一个面板里把本机 agent 会话、残留进程清理，以及 6 个 agent 的共享指令同步收在一起。工具调用审批的代码还在，但面板入口暂时下线（见下文）。

没有 Dock 图标（`LSUIElement`），点状态栏的蝠鲼或按 `⌃⌥A` 打开。

---

## 功能

**会话（Sessions）**
扫描本机进程，认出 Claude Code / Codex / Pi / DeepSeek Harness / Gemini CLI / Cursor / OpenCode 七个 CLI（直接启动的按可执行名，node 启动的按包路径判断），按 agent 分组。每行显示工作目录（悬停看全路径）和已运行时长，时长每秒自己走；右上角 `↻` 立即重扫，另有 15 秒自动重扫，进程退出后该行消失。进程扫到的会话会和 hook / transcript 里已有的记录合并，保留审批状态，启动时间取较早的那个。

**环境（Environment）**
三类残留：监听端口、孤儿进程、已合并但没删的 worktree。先给计划（哪条命令、影响什么对象），确认后才执行——展示和执行用的是同一份数据。归属靠启发式打分（命令行、父子进程树、cwd），拿不准的标「不确定」且默认不勾；删目录这类不可逆操作要再点一次确认。只有页面可见时才做完整扫描，后台每 10 秒采一次进程快照（孤儿判定需要历史）。

**指令（Instructions）**
把一份共享指令写进 6 个 agent 的用户级 md（只列用户级，仓库里的 `AGENTS.md` 不在范围内）：

| agent | 写入文件（按优先级） |
|---|---|
| Claude Code | `~/.claude/CLAUDE.md` → `AGENTS.md` |
| Codex | `~/.codex/AGENTS.override.md` → `AGENTS.md` |
| Pi | `~/.pi/agent/AGENTS.override.md` → `AGENTS.md` → `CLAUDE.md` |
| DeepSeek Harness | `~/.dsh/AGENTS.md` |
| Gemini CLI | `~/.gemini/GEMINI.md` |
| Cursor | `~/.cursorrules` |

目录可用 `CLAUDE_CONFIG_DIR` / `CODEX_HOME` / `PI_CODING_AGENT_DIR` / `DSH_HOME` 覆盖。`AGENTS.override.md` 存在时优先写它——写进 `AGENTS.md` 会被它盖住。

只替换 `<!-- muster:begin · written by Muster from its shared instructions -->` 到 `<!-- muster:end -->` 之间的块，文件里原有的内容一行不动；写之前看 diff，写完留备份，可以随时还原。

面板里每套指令是一行可折叠的条目：点开即切换为该套并展开正文，名字可以直接在行内改（失焦保存），页脚有 `Markdown · ⌘S` 提示，`⌘S` 保存正文，新建的套在列表底部。

**设置**
全局热键 `⌃⌥A`、开机启动、系统通知、hook 的安装/卸载、tab 顺序、检查更新（发现新版本可以直接下载 DMG、就地换包并重启）。

**审批（Approvals，暂时下线）**
代码和 hook 链路都还在：Claude Code 的 `PreToolUse` hook 把请求送到面板，可以「允许 / 拒绝 / 允许同类 / 永久允许」，同类规则按命令前两个 token 匹配、高危不给这个选项。下线的原因有两个：链路只接了 Claude Code，而且会拦下**所有**工具调用，每个最多等 90 秒——对「agent 全权限」的用法反而更麻烦。之后会改成只拦高危操作，并接上 Codex / Gemini CLI / Cursor / Pi / DeepSeek Harness / OpenCode 的钩子，再重新打开。

中英文两套文案，跟随系统语言。

---

## 安装

要求 macOS 14+、Swift 6 工具链。只需要 Command Line Tools，**不需要完整 Xcode**。

从 [Releases](https://github.com/EthanWFL/muster/releases) 下 DMG，把 `Muster.app` 拖进 `/Applications`。

本地构建：

```bash
git clone https://github.com/EthanWFL/muster.git
cd muster
Scripts/package.sh                 # → dist/Muster.app
Scripts/package.sh --dmg           # 顺便出 dist/Muster-X.Y.Z.dmg
swift run Muster                   # 开发时直接跑，不用打包
```

首次打开：app 是 **ad-hoc 签名**，会被 Gatekeeper 拦一次，去「系统设置 → 隐私与安全性」点「仍要打开」。

会话、环境、指令三页不需要任何 agent 配置。审批页下线期间**先别装 hook**：装了之后 Claude Code 的每个工具调用都会静默等 90 秒才放行，面板却没法处理。等风险门做完再开放安装。

---

## 工作原理

```
Claude Code ──PreToolUse──▶ muster-hook ──unix socket──▶ Muster.app
                                                          └─▶ 面板 / 通知
```

- **fail-safe，不是 fail-open**：`muster-hook` 遇到任何异常（stdin 不合法、连不上、超时、回包非法）都输出「无决策」并 `exit 0`，Claude Code 回落到自己的确认提示。Muster 没开或崩了，行为等同没装。
- socket 默认 `~/Library/Application Support/Muster/agentd.sock`，目录权限 `0700`；可用 `MUSTER_SOCK` 覆盖（hook 和 app 读同一个变量）。
- 超时：hook 侧 120 秒（`settings.json` 里显式写，不写会被 Claude Code 默认值提前杀掉），app 侧 TTL 90 秒。
- 备份与配置都在 `~/Library/Application Support/Muster/`。
- 审批链路（`PreToolUse` hook）只在 Claude Code 上接了，且面板入口暂时下线；会话、环境、指令三页都不依赖 hook。

---

## 项目结构

```
Sources/
  MusterProtocol/   协议与 socket 路径，hook 和 app 共用，零依赖
  MusterCore/       纯逻辑：适配器、审批、会话扫描、清理计划、指令同步
  Muster/           SwiftUI app（菜单栏 + 面板 + 设置），仅 UI 与装配
  muster-hook/      hook 客户端，只依赖 Protocol，冷启动要快
Tests/              单元测试（逻辑层为主，UI 很少）
Resources/          Info.plist、AppIcon.icns（打包用）
Scripts/            package.sh、test.sh、make-icon.py
```

---

## 开发

```bash
Scripts/test.sh          # 280 个测试 / 39 个 suite（只要 CLT 也能跑）
Scripts/package.sh       # 打 .app
python3 Scripts/make-icon.py   # 从蝠鲼动效重新生成 AppIcon.icns（需要 Pillow）
```

**发版**：版本号以 git tag 为准，`package.sh` 用 `git describe --tags --abbrev=0` 读它，显式传参可覆盖。

```bash
git tag v0.2.0 && git push origin v0.2.0
Scripts/package.sh --dmg
gh release create v0.2.0 dist/Muster-0.2.0.dmg --title "Muster 0.2.0"
```

release 里的 DMG 必须叫 `*.dmg`，app 的检查更新会挑第一个匹配的 asset。

---

## 已知限制

- 无 Developer ID、无公证：别人首次打开要手动放行；换包更新是重新 ad-hoc 签名，登录项和系统权限可能要求重新授权。
- 审批页暂时下线；审批链路目前也只有 Claude Code，其他 agent 只支持指令同步与会话展示。
- 更新下载没有进度条（网络慢时会看起来像卡住）。
- 仓库暂未声明许可证。
