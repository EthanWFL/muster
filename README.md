# Muster

macOS 菜单栏上的 agent 控制台。一个面板里把本机 agent 会话、残留进程清理、共享规则同步和模型配置收在一起。

没有 Dock 图标（`LSUIElement`），点状态栏的蝠鲼或按 `⌃⌥A` 打开。

---

## 功能

**会话（Sessions）**
扫描本机进程，认出 Claude Code / Codex / Pi / DeepSeek Harness / Gemini CLI / Cursor / OpenCode 七个 CLI（直接启动的按可执行名，node 启动的按包路径判断），按 agent 分组。每行显示工作目录（悬停看全路径）和已运行时长，时长每秒自己走；右上角 `↻` 立即重扫，另有 15 秒自动重扫，进程结果会与本地 transcript 记录合并（Claude Code、Codex、Pi，只读文件头尾，不留对话内容；其余 agent 状态恒为运行），保留会话 ID 和较早的启动时间；transcript 中的近期活动用于推断运行与空闲状态，不再接收工具调用或审批事件。行内显示 git 分支，可一键复制「cd 到原目录并 resume」的命令（Claude Code、Codex、Pi）。会话从运行变空闲时发系统通知；设置里填飞书自定义机器人 webhook 可同步推送。

**清理（Cleanup）**
三类残留：监听端口、孤儿进程、已合并但没删的 worktree。先给计划（哪条命令、影响什么对象），确认后才执行——展示和执行用的是同一份数据。归属靠启发式打分（命令行、父子进程树、cwd），拿不准的标「不确定」且默认不勾；删目录这类不可逆操作要再点一次确认。只有页面可见时才做完整扫描，后台每 10 秒采一次进程快照（孤儿判定需要历史）。

**规则（Rules）**
把一份共享规则写进 6 个 agent 的用户级 md（只列用户级，仓库里的 `AGENTS.md` 不在范围内）：

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

面板里每套规则是一行可折叠的条目：点开即切换为该套并展开正文，名字可以直接在行内改（失焦保存），页脚有 `Markdown · ⌘S` 提示，`⌘S` 保存正文，新建的套在列表底部。

**配置（Configuration）**
只展示本机已有配置文件的 Agent。页面顶部是配置文件卡片：路径、大小、修改时间，以及打开文件和 Finder 定位入口。Codex、Pi 可编辑用户级默认服务商和模型 ID：有本地模型列表时用下拉选，手填收在下拉底部的「自定义…」里，没有列表时直接是两个输入框；Claude Code、Hermes、Cursor、Warp、Magpie 只提供打开文件入口。Codex、Pi、Claude Code、Hermes 的配置目录分别遵循 `CODEX_HOME`、`PI_CODING_AGENT_DIR`、`CLAUDE_CONFIG_DIR`、`HERMES_HOME`。

改动会在页内实时以 diff 展示（键名取文件里的真实键），点一次保存即可；只替换目标字段，保留其他内容、格式和注释。底栏有「放弃修改」和「恢复上次配置」。写入前在 `~/Library/Application Support/Muster/configuration-backups/` 保存一份私有备份；仅当前文件仍与上次写入一致时允许恢复。检测到文件被其他程序修改会停止保存，需重新读取。符号链接保留，写入其目标文件。

第一版不编辑认证信息、不查询远端模型，也不热切换正在运行的会话。项目配置、Profile 和启动参数仍可能覆盖用户级默认值。Codex 顶层多行 TOML 值暂不支持表单编辑，遇到此类写法请使用原文件入口；表内内容保持原样。

**设置**
设置分四块：通用（开机启动、全局热键 `⌃⌥A`）、通知（会话停下提醒、飞书机器人 webhook 和测试）、界面（语言、tab 顺序）、关于（版本、检查更新）。检查更新的结果直接显示在设置页里，不弹模态窗；发现新版本可以直接下载 DMG、就地换包并重启。

中英文两套文案，跟随系统语言，也可在设置里指定。

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

会话、清理、规则页无需安装 Hook。审批功能已移除；以前安装过 Muster Hook 的用户，请按[旧 Hook 清理说明](docs/remove-legacy-hook.md)移除遗留配置。Muster 不会自动修改现有 Claude 权限规则。

---

## 工作原理

- 会话：每 15 秒读取本机进程和 Claude Code、Codex、Pi 的 transcript 头尾元数据，不保存对话正文。
- 受保护目录：会话落在文档、桌面、下载、iCloud 云盘或外接卷里时，跳过 git 分支读取和 worktree 扫描，避免首次打开被系统授权弹窗打断；这些目录里的项目不显示分支，也不会被清理页扫描。
- 清理：基于进程和工作树信息生成清理计划，确认后执行。
- 规则与配置：写入目标文件前保留备份，数据存于 `~/Library/Application Support/Muster/`。
- 应用不运行审批 socket、不拦截 Agent 工具调用，也不请求审批通知权限。

---

## 项目结构

```
Sources/
  MusterCore/       纯逻辑：会话扫描、清理计划、规则同步、配置读写
  Muster/           SwiftUI app（菜单栏 + 面板 + 设置），仅 UI 与装配
Tests/              单元测试（逻辑层为主，UI 很少）
Resources/          Info.plist、AppIcon.icns（打包用）
Scripts/            package.sh、test.sh、make-icon.py
```

---

## 开发

```bash
Scripts/test.sh --no-parallel  # 运行测试（只要 CLT 也能跑）
Scripts/package.sh       # 打 .app
python3 Scripts/make-icon.py   # 从蝠鲼动效重新生成 AppIcon.icns（需要 Pillow）
```

**发版**：版本号以 git tag 为准，`package.sh` 用 `git describe --tags --abbrev=0` 读它，显式传参可覆盖。

```bash
git tag v0.4.1 && git push origin v0.4.1
Scripts/package.sh --dmg
gh release create v0.4.1 dist/Muster-0.4.1.dmg --title "Muster 0.4.1"
```

release 里的 DMG 必须叫 `*.dmg`，app 的检查更新会挑第一个匹配的 asset。

---

## 已知限制

- 无 Developer ID、无公证：别人首次打开要手动放行；换包更新是重新 ad-hoc 签名，登录项和系统权限可能要求重新授权。
- 更新下载没有进度条（网络慢时会看起来像卡住）。
- 只有 Claude Code、Codex、Pi 有 transcript 扫描，能区分运行与空闲、能复制 resume 命令；其余四个 agent 状态恒为运行。
- Codex 的本地模型下拉只在服务商为 openai 时读取缓存目录，使用自定义目录（`model_catalog_json`）的配置暂时要手填。
- 飞书 webhook 明文存在偏好设置里，且不支持机器人的「签名校验」。
- 仓库暂未声明许可证。
