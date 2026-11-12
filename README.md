# Muster

macOS 菜单栏上的 agent 控制台。一个面板里把 Claude Code 的工具调用审批、会话状态、残留进程清理，以及 6 个 agent 的共享指令同步收在一起。

没有 Dock 图标（`LSUIElement`），点状态栏的蝠鲼或按 `⌃⌥A` 打开。

---

## 功能

**审批（Approvals）**
Claude Code 每次要跑工具前，`PreToolUse` hook 把请求送到面板，可以「允许 / 拒绝 / 允许同类」。同类规则只活在本会话，按命令前两个 token 匹配（`Edit`/`Write` 这类非 shell 工具按工具名），高危命令不给这个选项；也可以把某条完全相同的命令存成永久规则。拒绝时可以写一句理由回传给 agent，它会当作这次的错误信息读。

**会话（Sessions）**
从 `~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl` 推断会话状态，只读文件头尾（有界读取），15 秒兜底重扫一次；实时状态来自 hook 事件。

**环境（Environment）**
三类残留：监听端口、孤儿进程、已合并但没删的 worktree。先给计划（哪条命令、影响什么对象），确认后才执行——展示和执行用的是同一份数据。

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

**设置**
全局热键 `⌃⌥A`、开机启动、系统通知、hook 的安装/卸载、检查更新（发现新版本可以直接下载 DMG、就地换包并重启）。

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

启动后到设置里点「Install hook」，把 `muster-hook` 写进 `~/.claude/settings.json`（写前备份）。不装 hook 也能用，只是没有审批功能。

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
- 审批只接 Claude Code；其他 agent 目前只有指令同步。

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
Scripts/test.sh          # 278 个测试 / 38 个 suite（只要 CLT 也能跑）
Scripts/package.sh       # 打 .app
python3 Scripts/make-icon.py   # 从蝠鲼动效重新生成 AppIcon.icns（需要 Pillow）
```

**发版**：版本号以 git tag 为准，`package.sh` 用 `git describe --tags --abbrev=0` 读它，显式传参可覆盖。

```bash
git tag v0.1.2 && git push origin v0.1.2
Scripts/package.sh --dmg
gh release create v0.1.2 dist/Muster-0.1.2.dmg --title "Muster 0.1.2"
```

release 里的 DMG 必须叫 `*.dmg`，app 的检查更新会挑第一个匹配的 asset。

---

## 已知限制

- 无 Developer ID、无公证：别人首次打开要手动放行；换包更新是重新 ad-hoc 签名，登录项和系统权限可能要求重新授权。
- 审批链路只有 Claude Code；Codex / Pi 等只支持指令同步。
- 更新下载没有进度条（网络慢时会看起来像卡住）。
- 仓库暂未声明许可证。
