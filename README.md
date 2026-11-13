# Muster

macOS 菜单栏上的 agent 控制台。一个面板里把本机 agent 会话、残留进程清理、共享规则同步和模型配置收在一起。

**当前版本：1.0.0** · [下载 macOS 安装包](https://github.com/EthanWFL/muster/releases/download/1.0.0/Muster-1.0.0.dmg) · [更新说明](https://github.com/EthanWFL/muster/releases/tag/1.0.0) · [SHA-256 校验文件](https://github.com/EthanWFL/muster/releases/download/1.0.0/Muster-1.0.0.sha256)

没有 Dock 图标（`LSUIElement`），点状态栏的蝠鲼或按 `⌃⌥A` 打开快速面板。面板顶部和右键菜单均可打开独立管理窗口，窗口支持调整大小并记住位置；两处共用草稿、筛选和当前工作页面。

## 1.0.0 更新

- **会话库**：导入最近与历史会话，自定义标题、分类、待处理标记、备注和产物目录，支持撤销及在终端继续。
- **独立管理窗口**：统一标题栏、动态图标和侧栏；修复关闭后再次展开时窗口缩成窄条的问题，保留用户调整的大小和位置。
- **集中设置**：小窗口的设置入口直接打开管理窗口，右侧连续展示设置分区，左侧通过锚点定位并随滚动同步高亮。
- **Agent 与配置**：统一能力和路径定义，增加环境诊断、模型预设，改进会话匹配、活动暂停提醒及文件写入冲突检查。
- **构建与更新**：接入 GitHub Actions，增加下载进度、取消和更新签名验证能力。本次安装包仍采用手动更新，具体见下方安装说明。

本版本已通过 190 项测试，并验证窗口重开、设置锚点和更新签名工具。

---

## 功能

**会话（Sessions）**
扫描本机进程，识别 Claude Code / Codex / Pi / DeepSeek Harness / Gemini CLI / Cursor / OpenCode 七个 CLI，按 Agent 分组。每 15 秒自动刷新，也可手动重扫。Claude Code、Codex、Pi 会结合本地 transcript 元数据显示「最近活跃」或「暂无新活动」；只有进程信息时显示「活动未知」，这些状态都不代表任务完成。

进程与 transcript 只在候选唯一、时间吻合时关联；同目录多个候选会保留独立条目，不猜测对应关系。悬停状态可查看是否已关联存活进程。行内显示项目路径、git 分支和距最近活动的时间（仅进程条目显示启动时长），可跳转终端，或复制 Claude Code、Codex、Pi 的 resume 命令。

已关联存活进程的会话，在观察到活动后持续 60 秒没有新活动时提醒，同一轮暂停只提醒一次。设置飞书自定义机器人 webhook 后也可同步推送。

支持搜索项目路径、Agent、分支、会话 ID 和 PID，空格分隔的词需同时匹配；可按活动状态筛选，或按 Agent／完整工作目录分组。同名但不同路径的项目分别展示，分组方式会记住。没有匹配结果时可一键重置筛选。

独立管理窗口的「会话」页提供本地会话库：顶部切换「最近」（24 小时内或仍关联存活进程）和「历史」，按全部、待处理、未分类或自建分类筛选。选中会话后可修改标题、标记待处理、填写备注、关联产物目录，按 `⌘S` 保存。搜索同时覆盖标题、项目路径、Agent、备注、分类和产物路径。菜单栏面板显示自定义标题、待处理总数和会话库入口。

每次启动后首次打开会话库，导入最近 30 天的 Claude Code、Codex、Pi 本地记录；右上角刷新菜单可以导入全部历史，也可取消正在进行的扫描。导入只保存会话元数据，不保存对话正文。没有 transcript 的临时进程仍可查看和聚焦终端，暂不支持历史整理。历史条目不推断进程仍在运行；「在终端继续」会向新的 macOS Terminal 窗口发送恢复命令，也可单独复制到其他终端。

标题、分类、备注、待处理标记和产物目录保存在 `~/Library/Application Support/Muster/session-library.json`，退出 Agent 或重启 Muster 后仍保留。整理操作支持撤销最近 50 次更改，导入不会覆盖标注或占用撤销记录。删除分类会将其中会话改为未分类，保留会话和原文件。本阶段标注仅在 Muster 内生效，不同步修改 Claude / Codex 的标题或侧边栏。

`⌘F` 定位搜索；菜单栏快速面板中，搜索框内按 Enter 或 ↓ 进入结果列表，上下键选择会话，Enter 跳转终端，`⌘R` 刷新。`⌘1`–`⌘4` 按当前标签顺序切页，`⌘,` 打开设置，管理窗口中 `⌘W` 关闭窗口。

**清理（Cleanup）**
三类残留：监听端口、孤儿进程、已合并但没删的 worktree。先给计划（哪条命令、影响什么对象），确认后才执行——展示和执行用的是同一份数据。归属靠启发式打分（命令行、父子进程树、cwd），拿不准的标「不确定」且默认不勾；删目录这类不可逆操作要再点一次确认。只有页面可见时才做完整扫描，后台每 10 秒采一次进程快照（孤儿判定需要历史），最后一个会话退出后仍继续跟踪已登记的子进程，直到这些进程退出。扫描不会并发叠加。

执行后区分「已发送 SIGTERM」「等待退出」和「进程已退出」，面板收起后仍跟踪退出结果。10 秒后仍未退出的进程会提供「强制结束」入口，需要单独确认，且执行前再次核对进程身份。

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

面板里每套规则是一行可折叠条目。展开只切换查看的草稿，编辑后自动保存到本地，也可按 `⌘S` 保存；名字可行内修改。查看、保存草稿和调整 Agent 开关都不会立即写入 Agent 文件。

查看「预览改动」后，可逐项或批量「应用改动」。关闭目标开关会预览移除该文件中的 Muster 共享块，点击应用后才执行。预览后若文件被其他程序修改，会拒绝覆盖并刷新预览，需要重新检查后再应用。

**配置（Configuration）**
只展示本机已有配置文件的 Agent。页面顶部是配置文件卡片：路径、大小、修改时间，以及打开文件和 Finder 定位入口。Codex、Pi 可编辑用户级默认服务商和模型 ID：有本地模型列表时用下拉选，手填收在下拉底部的「自定义…」里，没有列表时直接是两个输入框；Claude Code、Hermes、Cursor、Warp、Magpie 只提供打开文件入口。Codex、Pi、Claude Code、Hermes 的配置目录分别遵循 `CODEX_HOME`、`PI_CODING_AGENT_DIR`、`CLAUDE_CONFIG_DIR`、`HERMES_HOME`。

改动会在页内实时以 diff 展示（键名取文件里的真实键），点一次保存即可；只替换目标字段，保留其他内容、格式和注释。底栏有「放弃修改」和「恢复上次配置」。写入前在 `~/Library/Application Support/Muster/configuration-backups/` 保存一份私有备份；仅当前文件仍与上次写入一致时允许恢复。检测到文件被其他程序修改会停止保存，需重新读取。符号链接保留，写入其目标文件。

第一版不编辑认证信息、不查询远端模型，也不热切换正在运行的会话。项目配置、Profile 和启动参数仍可能覆盖用户级默认值。Codex 顶层多行 TOML 值暂不支持表单编辑，遇到此类写法请使用原文件入口；表内内容保持原样。

Codex、Pi 支持保存具名模型预设，每个 Agent 分开管理。预设只保存名称、服务商和模型 ID，存于 `~/Library/Application Support/Muster/configuration-presets.json`，文件权限为 `0600`。点击「使用预设」后先填入表单，检查 diff 并保存后才修改 Agent 配置；有未保存改动时不能切换预设。

**设置**
设置包含通用（开机启动、全局热键 `⌃⌥A`）、通知（活动暂停提醒、飞书机器人 webhook 和测试）、界面（语言、舒适布局、tab 顺序）、环境诊断和关于。

管理窗口的侧栏采用图标导航，设置固定在左下角。右侧连续展示常规、通知、界面、环境诊断和关于，点击左侧分区会滚动到对应标题，手动滚动时同步高亮当前分区；窗口内 `⌘,` 打开或收起设置，`⌘1`–`⌘4` 按自定义顺序切换主菜单。设置统一在管理窗口编辑：快速面板的齿轮和 `⌘,` 会收起面板、打开管理窗口并选中设置，保留上次的设置分区；右键菜单的「检查更新」会直接定位到「关于」。

「检查环境」会查看各 Agent 的命令行工具位置、配置与规则文件状态，以及 Muster 支持的功能。检查只读本地文件，不启动 Agent 或联系模型服务；Codex、Pi 的配置会通过现有解析器检查。其他配置只检查是否可读，不代表内容有效。自定义 Shell 路径可能与应用不同，因此「未找到」不等于未安装。

检查更新的结果直接显示在设置页。配置了发布公钥的构建，可下载带签名的 DMG，显示下载进度和已接收大小，支持取消下载。安装前用内置公钥验证 Ed25519 签名，再检查代码签名、应用标识、版本和 CPU 架构，之后才替换应用并重启。缺少公钥或签名时显示发布页入口。下载上限为 256 MiB；进入校验和安装阶段后不再提供取消。

中英文两套文案，跟随系统语言，也可在设置里指定。舒适布局会放大文字和行高；选择菜单与开关使用原生控件，支持标准键盘导航。管理窗口提供侧栏导航和更大的规则编辑区，较长的规则预览可展开查看全部行。

---

## 安装

1.0.0 安装包支持 **macOS 14+、Apple Silicon（arm64）**。下载后无需安装 Swift 或开发工具。

下载 [Muster-1.0.0.dmg](https://github.com/EthanWFL/muster/releases/download/1.0.0/Muster-1.0.0.dmg)，把 `Muster.app` 拖进 `/Applications`。其他版本见 [Releases](https://github.com/EthanWFL/muster/releases)。

如需校验下载，将 [Muster-1.0.0.sha256](https://github.com/EthanWFL/muster/releases/download/1.0.0/Muster-1.0.0.sha256) 放在 DMG 同一目录，在该目录执行：

```bash
shasum -a 256 -c Muster-1.0.0.sha256
```

本次安装包未配置发布签名密钥，应用内自动安装更新未启用。升级时请先退出旧版，再用下载的 `Muster.app` 替换原应用；本地会话标注和配置保存在应用包之外。

本地构建需要 Swift 6 工具链。只安装 Command Line Tools 即可，**不需要完整 Xcode**：

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
- Agent 路径、可执行文件名和支持能力统一定义在 `AgentRegistry`，供会话扫描、规则同步、配置和环境诊断复用。
- 应用不运行审批 socket、不拦截 Agent 工具调用，也不请求审批通知权限。

---

## 项目结构

```
Sources/
  MusterCore/       纯逻辑：会话扫描、清理计划、规则同步、配置读写
  Muster/           SwiftUI app（菜单栏 + 面板 + 设置），仅 UI 与装配
Tests/              核心逻辑与应用模型测试（不包含界面截图测试）
Resources/          Info.plist、AppIcon.icns（打包用）
Scripts/            打包、测试、更新签名与图标生成脚本
```

---

## 开发

```bash
Scripts/test.sh --no-parallel  # 运行测试（只要 CLT 也能跑）
Scripts/package.sh       # 打 .app
bash Scripts/test-update-signing.sh  # 用临时测试密钥验证签名工具
python3 Scripts/make-icon.py   # 从蝠鲼动效重新生成 AppIcon.icns（需要 Pillow）
```

仓库包含 GitHub Actions 工作流，push 和 PR 会运行测试、Release 打包与代码签名检查，以及更新签名工具的临时密钥测试。工作流不发布版本、不使用发布私钥。

**发版**：版本号以 git tag 为准，`package.sh` 用 `git describe --tags --abbrev=0` 读它，显式传参可覆盖，格式为 `X.Y.Z`。不提供密钥时仍可生成供手动安装的本地构建。

启用应用内更新前，在仓库之外保存一把固定的发布私钥。以下初始化命令仅执行一次，输出的是可公开的公钥；已有文件会被拒绝覆盖：

```bash
swift Scripts/sign-update.swift generate-key /absolute/private/muster-update.key
```

后续版本必须使用同一把私钥，公钥会自动写入应用：

```bash
MUSTER_UPDATE_KEY_FILE=/absolute/private/muster-update.key Scripts/package.sh --dmg 1.0.0
# 检查产物后再创建对应 tag 和 release，并同时上传两个文件：
gh release create 1.0.0 dist/Muster-1.0.0.dmg dist/Muster-1.0.0.dmg.sig --title "Muster 1.0.0"
```

发布资产名称必须为 `Muster-X.Y.Z.dmg` 和 `Muster-X.Y.Z.dmg.sig`，tag 支持 `X.Y.Z` 和历史使用的 `vX.Y.Z`，应用内版本为 `X.Y.Z`。没有私钥的构建环境可通过 `MUSTER_UPDATE_PUBLIC_KEY` 注入固定公钥，但不能生成更新签名。首次从未内置公钥的旧版迁移时，需手动安装带公钥的新构建。

`MUSTER_SIGNING_IDENTITY` 可指定 Keychain 中的 Developer ID 身份；未设置时使用 ad-hoc 签名。Apple 公证仍需在发布流程中单独完成；如果公证或装订改变了 DMG，上传前应对最终 DMG 重新生成 `.sig`。Ed25519 更新签名不替代 Developer ID 或公证。

---

## 已知限制

- 默认本地构建没有 Developer ID 或公证，首次打开可能需要手动放行，更新后登录项和系统权限可能需要重新授权。
- 更新不支持断点续传；构建只包含当前机器的架构，发布时需使用兼容目标设备的包，架构不兼容会拒绝替换。
- 只有 Claude Code、Codex、Pi 有 transcript 扫描，能区分运行与空闲、能复制 resume 命令；其余四个 agent 显示「活动未知」。同目录多候选的会话可能保留独立的进程与 transcript 条目。
- Codex 的本地模型下拉只在服务商为 openai 时读取缓存目录，使用自定义目录（`model_catalog_json`）的配置暂时要手填。
- 飞书 webhook 明文存在偏好设置里，且不支持机器人的「签名校验」。
- 仓库暂未声明许可证。
