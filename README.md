# Muster

Muster 是一个原生 macOS 菜单栏工具，用来集中管理本机 AI Agent 的会话、共享规则、技能和模型配置。经常同时使用 Claude Code、Codex、Pi 等工具时，可以在一个面板里切回正在使用的客户端、查看历史会话，或修改常用设置。

[下载最新版](https://github.com/EthanWFL/muster/releases/latest) · [1.3.2 更新记录](docs/releases/1.3.2.md) · [全部版本](https://github.com/EthanWFL/muster/releases) · [详细使用说明](docs/usage.md)

## 能做什么

| 功能 | 用途 |
| --- | --- |
| 项目工作台 | 添加或固定项目，集中查看相关会话、待处理事项和产物目录 |
| 会话记录 | 查找本机运行及历史会话，记录标题、分类和备注，通过来源 Logo 切回当前客户端 |
| AI 对话 | 使用自己的 OpenAI API 密钥，通过自然语言查询项目和会话，或确认后打开运行客户端 |
| 桌面轮盘 | 从桌面熊猫快速打开常用项目、网址和 AI 对话，按需开启剪贴板历史 |
| Agent 工作区 | 统一管理共享规则、独立技能库和已有的模型配置能力 |
| 快捷面板 | 直接编辑规则或配置；常用的预览、应用和保存按钮保持可见 |
| 清理 | 预览端口、孤儿进程及失效 worktree 的清理计划，确认后执行 |
| 偏好设置 | 选择需要管理的 Agent，设置外观、语言、通知和减弱动态效果 |

会话识别支持 Claude Code、Codex、Pi、DeepSeek Harness、Gemini CLI、Cursor、OpenCode。各 Agent 的能力不同：历史记录主要支持 Claude Code、Codex、Pi，原生模型表单支持 Codex、Pi。技能库由 Muster 独立实现，不依赖 Magpie。

## 安装与快速开始

当前安装包支持 **macOS 14 及以上、Apple Silicon（arm64）**，运行时不需要安装 Swift 或开发工具。

1. 在[最新发布页](https://github.com/EthanWFL/muster/releases/latest)下载 DMG，将 `Muster.app` 拖入 `/Applications`。
2. 启动后点击菜单栏的熊猫图标，或按 `⌃⌥A` 打开快捷面板。面板打开时熊猫眨一次眼，开启「减弱动态效果」时保持静止。应用不显示 Dock 图标。
3. 点击快捷面板右上角的「打开管理窗口」，在「设置 → Agent 管理范围」选择希望 Muster 处理的 Agent。侧栏可整列滚动，「轮盘配置」和「设置」的子项在各自入口下方展开。

安装包目前采用 ad-hoc 代码签名，尚未经过 Apple 公证。首次打开如被 macOS 阻止，可在“系统设置 → 隐私与安全性”中允许打开。发布页同时提供 SHA-256 校验文件。

### 更新

从 **1.1.1** 开始，正式构建内置固定的更新公钥。发现后续新版本时，在“设置 → 关于”点击“下载并安装”，应用会下载 DMG、验证发布签名及应用信息、替换当前安装并重启。下载阶段可以取消，不会在后台静默安装。

**1.0.0、1.1.0 等没有内置更新公钥的旧版本，需要手动安装一次 1.1.1。** 给远端补一个签名无法让旧版自行建立信任；完成这次迁移后，后续签名版本才可在应用内安装。应用应放在可写的应用目录中，更新不会绕过系统权限。

替换应用包会保留包外的会话标注、项目、规则、技能库、预设和设置；升级前请保存尚未落盘的编辑。校验步骤、数据位置与功能边界见[使用说明](docs/usage.md)。

## 常用操作与配置

- **管理范围**：「设置 → Agent 管理范围」的清单统一影响规则、会话、配置、技能、项目统计、通知和清理。取消勾选不会删除已有数据或部署。
- **规则和配置**：小窗口 Agent 页直接切换两者；规则草稿保存后先预览再应用，模型默认配置在新 Agent 会话中生效。
- **技能**：本机技能沿用原源地址，Git 导入及新建技能使用 Muster 固定源目录，各 Agent 统一通过符号链接读取；源更新后无需逐个重新部署。支持正文与附属文件编辑、版本回滚及批量连接。已有目标在接管前自动备份，源文件外部修改会触发冲突检查；旧部署只在状态仍一致时迁移。
- **会话与项目**：给会话标记待处理、填写备注或关联产物目录；在项目页集中回到上次的工作。
- **AI 对话**：在管理窗口进入「设置 → 对话模型」，保存 OpenAI API 密钥并测试连接，再从侧栏进入「AI 对话」。密钥存放在 macOS 钥匙串。
- **桌面轮盘**：点击管理窗口底部的轮盘图标启用桌面熊猫，悬停展开菜单。在侧栏的「轮盘配置」选择可见入口、常用项目和网址。剪贴板历史默认关闭，开启后仅保存在内存中。
- **快捷键**：`⌘1`–`⌘4` 按当前顺序切页，`⌘F` 搜索，`⌘S` 保存当前编辑，`⌘,` 打开设置。

环境变量路径、备份恢复、共享技能可见性及清理限制见[详细使用说明](docs/usage.md)。

## 开发与贡献

源码构建需要 Swift 6 工具链，安装 Xcode Command Line Tools 即可。

```bash
git clone https://github.com/EthanWFL/muster.git
cd muster
Scripts/test.sh --no-parallel
Scripts/package.sh
```

构建产物位于 `dist/Muster.app`。修改前请查看[开发说明](docs/development.md)，发布维护者使用[签名与发布流程](docs/releasing.md)。问题反馈请附上 macOS 版本、Muster 版本、复现步骤和必要日志，并移除令牌、Webhook 与私人会话内容。

## 许可证与第三方声明

**本仓库目前尚未声明项目整体许可证。** 第三方依赖的许可不代表 Muster 源码已采用同一许可证。

Yams 和 LibYAML 的许可分别保留在 [Yams LICENSE](Vendor/Yams/LICENSE) 与 [LibYAML LICENSE](Vendor/Yams/LICENSE-libyaml)，应用内也包含[第三方声明](Sources/Muster/Resources/ThirdPartyNotices.txt)。

Muster 主要读取本机进程和 Agent 文件。使用对话功能时，你的消息及匹配的项目和会话摘要会发送给 OpenAI，Agent 会话原文保留在本机。获取远程技能、检查或下载更新、发送已配置的通知也会使用网络。它不会接管 Agent 的工具审批；旧 Hook 的移除方法见[清理说明](docs/remove-legacy-hook.md)。
