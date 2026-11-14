# Muster：Agent 工作区与技能库实现方案

调研日期：2026-11-14。本文记录 1.1.0 的实现方案与完成状态，项目工作台、Agent 管理范围及小窗口快捷操作一并交付。Magpie 对照版本固定为 `df2b819c6784dad093500be27bd015ddea734ebd`，上游细节见 [源码调研](magpie-skills-research.md)。

## 1.1.0 实现状态（2026-11-14）

已完成 Agent 入口整合、本地与公开 HTTPS Git 技能导入、新建／编辑／草稿、Claude Code／Codex／Pi 部署、链接／副本、更新预览、库版本恢复、部署恢复和中断恢复。批次 4 中的可选扩展尚未实现。完整操作与限制以 README 的 Agent 工作区说明为准。

落地时将技能索引、部署记录和恢复日志合并进 `library/skills.json`，便于同一把文件锁和写前日志保护状态；草稿用 `drafts/<id>.json` 保存基准版本与正文。不可变技能目录为 `skills/<id>/revisions/<digest>/<name>/`，保留与技能名称一致的目录。Yams 6.2.2 以源码和许可证一起放在 Vendor 中，避免构建依赖在线拉取。下文保留原设计依据。

## 结论与范围

用户确认的范围：参考 Magpie 的技能功能与交互，在 Muster 中独立实现。技能模块不依赖安装或运行 Magpie，不调用其 API、CLI 或进程，不自动扫描其私有库，也不提供 Magpie 专用导入、迁移或接管入口。Magpie 仅作为产品和源码参考；使用对象是 Claude Code、Codex、Pi 等 Agent。

可以在 Muster 中实现截图里的技能管理，并把规则、技能、配置收进一个 Agent 入口。现有 SwiftUI/AppKit 界面、AgentRegistry、规则差异预览和配置备份都可继续使用。技能的存储、解析、导入与部署需要新增实现；不需要为了这项功能接入 AI API，也不需要增加常驻网关。

建议首版围绕用户级技能完成“查看 → 导入 → 选择 Agent → 预览 → 应用 → 停用／恢复”。本地目录和已有 Agent 技能优先；远程 Git 仓库导入作为紧接着的一批交付。MCP、Hooks、子代理、模型网关不随本次整合迁入，Skill 路由也不放在首版。

Magpie 的相关实现采用 Go 和 Web UI。借鉴它的资源模型、导入与分发流程，界面仍使用 Muster 的原生 SwiftUI。引入 Go 子进程会增加打包、进程通信和两套状态同步，当前需求没有必要承担这些成本。[上游库模块](https://github.com/yetone/magpie/tree/df2b819c6784dad093500be27bd015ddea734ebd/internal/library)、[Web UI](https://github.com/yetone/magpie/tree/df2b819c6784dad093500be27bd015ddea734ebd/internal/gui/assets/plugins/library)

## 截图功能如何落到 Muster

| Magpie 中的能力 | Muster 方案 | 难度与交付位置 |
| --- | --- | --- |
| 本地与 Agent 已有技能的发现、导入 | 读取指定技能根，候选预览后把完整目录复制到自己的库 | 中；批次 1 只读，批次 2 可导入 |
| 新建、编辑、查看技能 | 普通 Markdown 编辑器，保留附属资源，草稿与发布修订分开 | 中；批次 2 |
| 每个技能按 Agent 启用 | 记录目标与可见性，预览链接／副本变更后应用 | 中至高；批次 2 |
| 符号链接／副本与按 Agent 设置 | macOS 默认用经验证的链接方案，单个目标可选副本 | 中；批次 2 |
| Git 仓库搜索、选择多个 Skill | 首批 HTTPS、GitHub 简写和 ref／子目录；从候选列表选择 | 中至高；批次 3 |
| 来源更新、备份与恢复 | 比较新修订、保留外部编辑、逐目标恢复 | 高；部署恢复在批次 2，来源更新在批次 3 |
| 放进共享 ~/.agents/skills | 明确共同可见范围；已有外部共享项只读显示，仅管理 Muster 自己部署的内容 | 高；必要的共享目标在批次 2，全库共享开关后置 |
| Skill 路由 | 暂不复制默认入口；后续做可选的索引 Skill 与直连例外 | 高；批次 4 |

Magpie 的 Skill 路由生成一个 `magpie-skills` 索引，由它列出其他技能；这会改变直接命令和模型发现方式，并涉及共享目录、副本模式及读取权限的例外。首版保留 Agent 原生发现链路，等普通技能管理稳定后再评估路由。该索引本身是本地技能机制，不需要为它接入模型网关。[上游路由实现说明](https://github.com/yetone/magpie/blob/df2b819c6784dad093500be27bd015ddea734ebd/docs/subsystems/skill-router.md)

## 界面与操作

主导航调整为“项目、会话、Agent、清理”；设置继续固定在左下角。原“规则”和“配置”入口迁入 Agent，不额外新增一个资源库顶级页面。

```text
Muster
├─ 项目
├─ 会话
├─ Agent
│  ├─ 规则
│  ├─ 技能
│  └─ 配置
├─ 清理
└─ 设置（底部固定）
```

大窗口进入 Agent 后，顶部是 Agent 筛选器：全部、Claude Code、Codex、Pi，以及其他已检测到的集成。下方是规则／技能／配置三个分段。筛选器代表当前查看对象，不代表切换底层模型或运行 Agent。

| 页面 | 全部 Agent | 选中某个 Agent |
| --- | --- | --- |
| 规则 | 共享规则库、目标列表、逐项和批量预览应用 | 同一规则库，突出该 Agent 的目标文件及其计划；应用按钮明确写目标名称 |
| 技能 | 共用技能库，显示每项在哪些 Agent 可见、是否由 Muster 管理 | 显示该 Agent 已用和可启用的技能，解释共享目录、外部管理及不支持的状态 |
| 配置 | 显示各 Agent 的配置入口及能力摘要，点击后同步选择顶部 Agent | 进入该 Agent 的配置；支持表单的可编辑，其余保留打开原文件入口 |

技能页使用列表＋详情布局，沿用现有字体、灰阶、按钮和动效：

- 顶栏提供搜索、本地导入、仓库导入、新建技能、刷新，以及打开库目录。
- 主列表区分“库中技能”和“Agent 已有、尚未导入”。每行显示名称、摘要、来源、可见 Agent 和同步状态。
- 详情展示 SKILL.md、附属文件清单、来源版本、兼容性提示和部署位置；不把密集路径放在主列表。
- 勾选 Agent 或切换链接／副本后显示“待应用”，底部一次预览并应用，不直接在切换筛选器时写外部文件。
- 新建技能用名称、描述和 Markdown 正文的普通表单，生成模板；默认不调用模型，也不执行 Skill。

小窗口的 Agent 页保留规则／技能／配置三个入口和摘要。技能的导入、编辑、冲突处理在大窗口完成，打开时带上当前 Agent 与子页，避免把完整管理器挤进 420pt 面板。

## 必须区分的几个概念

**技能是一个目录。** SKILL.md 之外可能有 scripts、references、assets 等相对引用。导入必须保留完整的目录结构、执行位和许可文件，不能只复制 Markdown。元数据按 Agent Skills 规范解析，保留未知字段及原始正文；新建时验证必填字段，外部旧技能不合规范时给出具体提示，不擅自改写。[Agent Skills 规范](https://agentskills.io/specification)

**规则、技能和配置的存储语义不同。** 规则继续沿用 `instructions.md`、规则集和 `instructions.json`；配置仍读写各 Agent 原文件；技能新增独立库和部署记录。界面归入一个入口，不意味着将三种数据塞进一个 JSON 或用一个“全部保存”按钮处理。

**按 Agent 部署不等于仅该 Agent 可见。** 当前 Codex 文档将用户技能目录列为 `~/.agents/skills`，Pi 也读取这一共享目录。复制或链接到此处可能影响多个 Agent，不能给其他 Agent 显示假的“关闭”状态。[Codex 文档](https://learn.chatgpt.com/docs/build-skills)、[Pi 技能文档](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/skills.md)

**Muster 的启用状态不等于会话已加载。** UI 应显示“已部署”“共享可见”“待更新”“外部管理”“冲突”等文件层面的结果。Agent 是否重新扫描、是否需要新开会话，由已核实的适配信息说明，不能统一承诺即时生效。

## 能力与路径定义

扩展现有 [AgentRegistry.swift](../Sources/MusterCore/Agents/AgentRegistry.swift)，在 AgentDescriptor 内增加可选的技能能力描述。路径仍通过统一定义解析，View 不自行拼接 `~/.xxx/skills`。

建议定义：

```swift
struct AgentSkillCapability {
    var discoveryRoots: [SkillSearchRoot] // 读取位置及 user/project/shared/legacy 来源
    var deploymentTargets: [SkillTarget] // 经验证可写的位置
    var supportsSymlink: Bool
    var isolation: SkillIsolation        // 专属目录、原生排除规则、共享可见、未知
    var reloadBehavior: SkillReloadBehavior
}
```

每个能力记录需要附测试版本／证据；环境变量覆盖仅在该 Agent 确实支持时使用。技能目录存在、CLI 可执行、支持部署是三个状态，不能用“发现一个配置文件”同时推断。

首批适配对象建议与 Muster 当前会话与配置能力重叠：Claude Code、Codex、Pi。其他 Agent 先保留原规则和配置能力，技能入口明确标注未适配，后续逐个增加。

本机只读版本探测返回：`codex-cli 0.167.0-alpha.4.1`、`Claude Code 2.1.292`、`pi 1.5.2`。这里只执行了 `--version`，没有启动会话或让这些程序加载技能；尤其 Codex 为 alpha 版本，仍需用临时技能目录做加载验证。Pi 的可执行来源也需要与所适配的实现对应，不能只凭程序名推断兼容。

| Agent | 已核实的路径依据 | 实现策略 |
| --- | --- | --- |
| Claude Code | 用户级 `~/.claude/skills/<name>/SKILL.md`，官方说明支持技能目录符号链接 | 核对版本与自定义配置目录后，提供专属目标；插件／同步目录只读识别 |
| Codex | 当前官方用户级位置为 `~/.agents/skills`，支持符号链接；现有环境还可能有 `~/.codex/skills` | 新旧位置分开识别；`.codex/skills` 仅在版本与实测通过后用于独立部署，否则明确共享影响 |
| Pi | 官方同时支持 Agent Skills 共享目录及用户／项目技能位置 | 结合实际安装版本核实专属根与环境覆盖；共享项仍按共同可见处理 |

[Claude Code 路径说明](https://code.claude.com/docs/en/skills#choose-where-skills-load)、[Codex 本地目录说明](https://learn.chatgpt.com/docs/build-skills#where-codex-loads-local-skills)、[Pi 技能说明](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/skills.md)

首版默认选用已经验证的 Agent 专属目录；不支持独立投放时，应提供带影响说明的共享部署，而不是假设隔离已成立。共享项的关闭操作只能移除 Muster 自己创建、且所有者校验通过的部署，不改别人放置的文件。已有共享目录的可见性按 Agent 的实际读取规则显示，不为逐 Agent 开关自动迁走外部文件。

## 技能库的数据与模块

沿用 Muster 的 Application Support 根目录，新增：

```text
~/Library/Application Support/Muster/
├─ instructions.md / instructions.json / instruction-sets/   # 保持原路径
├─ configuration-presets.json                               # 保持原路径
└─ library/
   ├─ skills.json          # 技能索引、来源、当前修订
   ├─ deployments.json     # Agent、目标位置、方式、上次写入摘要
   ├─ skills/<id>/revisions/<digest>/<slug>/SKILL.md
   │                                      ├─ scripts/
   │                                      ├─ references/
   │                                      └─ assets/
   ├─ drafts/<id>/         # 未发布编辑，不被 Agent 读取
   ├─ staging/             # 导入与更新暂存
   └─ transactions/        # 应用日志与回退资料
```

修订目录按内容摘要保存，同一修订不会为每个 Agent 重复存一份；保留必要历史用于恢复。链接指向已发布修订，不指向草稿。这样“保存草稿”不会通过符号链接悄悄改变 Agent 正在读取的内容。副本部署记录各自的版本，更新时可以准确列出需要同步的目标。

主要记录：

| 记录 | 必要内容 |
| --- | --- |
| SkillRecord | 稳定 UUID、slug、名称、描述、许可、原始 frontmatter、来源类型／仓库／ref／commit／子目录、当前修订、内容摘要 |
| SkillDeployment | skillID、agentID、作用域、解析后的目标路径、链接／副本、已部署修订、链接目标或目录摘要 |
| DiscoveredSkill | 原始路径、真实路径、关联 Agent、元数据、来源所有者、是否共享及可导入状态 |
| SkillPlan | 将新增／替换／删除的目标、预期原状态、来源修订、冲突、备份与影响范围 |

同名技能以来源和 UUID 区分，不按名称直接覆盖。macOS 常见的不区分大小写文件系统上，目标名称碰撞也必须提前发现。来自多个 Agent、实际指向同一技能目录的项目可合并为一个发现项，同时保留各目标链接。

建议只对 UI 暴露少量职责明确的 Module：

| Module | Interface 职责 | Implementation 放在哪里 |
| --- | --- | --- |
| SkillLibrary | 列表、导入、新建、保存草稿、发布修订 | 文件树校验、元数据解析、去重、来源记录、索引持久化 |
| SkillDeployment | 扫描、生成计划、应用、恢复 | 各 Agent 路径、链接／副本、所有者校验、冲突与事务恢复 |
| AgentWorkspaceModel | 当前 Agent／子页、导航与草稿切换 | 组合既有 InstructionsModel、ConfigurationModel 和新增 SkillsModel |

解析器、Git 获取器和文件写入器可以在 Module 内部拆分；不要让 View 自己组合扫描、删除、复制、写索引的顺序。Git 获取和文件操作使用可替换的内部 Seam，以便测试失败、取消和外部修改。

建议文件落点：

```text
Sources/MusterCore/Skills/
  SkillRecord.swift
  SkillLibrary.swift
  SkillDeployment.swift
  SkillDocument.swift
  SkillSource.swift
Sources/Muster/
  AgentWorkspaceModel.swift
  AgentWorkspaceView.swift
  SkillsModel.swift
  SkillsView.swift
  SkillImportView.swift
```

## 四条实际操作链

**从本地或已有 Agent 导入**

1. 用户选择普通本地文件夹，或在“Agent 已有”中选择具体技能；保留来源路径。不增加任何应用专用扫描入口。
2. 在有边界的目录遍历中发现 SKILL.md，跳过 `.git` 等无关目录；超出深度、数量或体积限制时明确说明哪些内容未扫描。
3. 展示候选名称、摘要、来源和问题，用户选择导入项。
4. 拷贝完整技能目录到 staging，解析并校验；符号链接越界或缺少引用文件时先报告，不沿链接把整个主目录带进库。
5. 原子提交技能修订与索引。只导入不会改变各 Agent 当前的文件或链接。
6. 用户选择目标 Agent，进入单独的部署预览。

Muster 采用复制导入并保留原目录。目标位置已有非 Muster 创建的目录或链接时，按普通文件冲突处理；导入技能不赋予 Muster 修改原文件或原链接的权限。这套检查只依据文件与部署记录，不识别或对接来源应用。

**从 Git 仓库导入**

首批支持 HTTPS 仓库 URL、GitHub `owner/repo`，以及明确的 ref 和子目录字段。GitHub tree 链接需要正确处理含 `/` 的分支，不能简单按第一个路径片段拆分；无法确定时让用户在已解析的 ref 列表中选择。GitLab、自定义 SSH 和私有认证可分批扩展，不承诺首版支持所有 git 地址。

所有来源均克隆到私有暂存目录，使用参数数组调用系统 git，不拼接 Shell 命令；设超时、取消、日志脱敏和体积限制。隔离模板、Hook、filter／LFS、子模块与外部协议，不执行仓库提供的安装器。下载结果记录实际 commit 后，再走同一套本地候选扫描和选择流程。没有 git 时保留本地导入，并给出明确原因。

**启用、更新与停用**

1. 读取当前库修订及目标状态，生成 SkillPlan，展示实际路径与受影响 Agent。
2. 应用前重新核对来源摘要、目标身份和上次写入记录。
3. 链接通过临时链接加 rename 替换；副本先在同一文件系统的临时目录构建，再提交目录变更。应用日志记录每个已完成步骤。
4. 整个技能目录都纳入内容摘要，不能只校验 SKILL.md 而遗漏脚本变化。
5. 停用只移除本应用拥有且仍符合预期的目标；外部目录、被改过的副本和改指向的链接均进入冲突处理。
6. 多 Agent 应用是可恢复的逐项事务，不宣称跨目录原子提交。失败时显示每个目标的结果；回退只恢复仍匹配本次写入状态的目标，保护执行期间的外部编辑。

更新从原始来源获取新 commit，在 staging 中比较正文与附属文件，再预览并发布。用户本地草稿和外部改过的副本不会被后台更新覆盖。发现 Agent 副本被手改时，只报告差异并让用户选择版本，不自动回收并传播到其他 Agent。首版只提供手动检查更新，不做静默自动更新。

**编辑与新建**

表单编辑保存到 drafts；发布时产生新修订。发布页列出哪些链接或副本将切换版本。使用 YAML 解析器支持多行描述及未知字段，不用逐行字符串截取代替解析；依赖选型与版本锁定在实现前确定。编辑外部技能默认先导入，不直接修改源目录或插件缓存中的原件。

## 旧入口与草稿迁移

这部分需要先做，不能直接删除枚举值：

- 旧 `MusterLastTab=Instructions` 映射到 `Agent + rules`；`Configuration` 映射到 `Agent + configuration`。
- 原 `MusterTabOrder` 中首次出现规则／配置的位置映射为 Agent，后续重复项移除；其余项目、会话、清理的相对顺序保留。没有旧入口时补入默认位置。
- 新增 `MusterAgentSection` 和当前 Agent ID，迁移只执行一次且可重复运行；不要重置用户规则集、启用目标或模型预设。
- 复用 `PanelModel.instructions` 和 `configuration` 的实例，避免 View 切换重建导致丢草稿。
- 规则仍是共享草稿。筛选 Agent 不创建私有规则集，不自动写文件；批量应用必须接收明确的目标集合，不能过滤了界面却仍写全部 Agent。
- 当前 ConfigurationModel 在 dirty 时直接拒绝 select。新容器必须先处理保存／放弃／取消，再更新顶部 Agent 选择，避免标题变成 Claude、表单仍是 Codex。
- 搜索快捷键按当前子页处理，页签数量缩为四个后同步更新快捷键、排序设置与 README。

对应修改入口：[PanelModel](../Sources/Muster/PanelModel.swift)、[PanelView](../Sources/Muster/PanelView.swift)、[ManagementSidebar](../Sources/Muster/ManagementSidebar.swift)、[InstructionsModel](../Sources/Muster/InstructionsModel.swift)、[ConfigurationModel](../Sources/Muster/ConfigurationModel.swift)。

## 交付顺序与验收

| 批次 | 交付内容 | 验收标准 |
| --- | --- | --- |
| 1：统一入口 | Agent 容器、规则／配置迁入、偏好迁移、技能只读发现 | 原操作和草稿不丢；旧页签偏好迁移正确；能看见已适配 Agent 目录中的技能及来源 |
| 2：本地技能闭环 | 库、完整目录导入、新建／编辑、三类 Agent 适配、链接／副本、计划应用与停用恢复 | 添加一个技能到多个目标；重启后状态一致；外部文件不被覆盖；共享可见项有准确解释 |
| 3：远程与更新 | HTTPS／GitHub 导入、候选选择、来源版本、手动更新及回退 | 多技能仓库可选择；ref／子目录不串；取消不留半成品；变更副本不会被更新覆盖 |
| 4：可选扩展 | 项目级技能、更多 Agent、共享布局设置、仓库来源扩展、Skill 路由 | 每项独立验证能力、迁移和回退；路由有实际召回与兼容性证据后再默认提供 |

测试重点是行为：含空格／中文的绝对路径；完整目录与相对引用；多行 frontmatter；同名／大小写冲突；环境路径；共享技能可见性；非 Muster 创建的原链接；断链、越界链接和目录循环；发布后外部修改；同时操作与应用中断；历史偏好迁移；未保存草稿切换；中英文、深浅色、舒适布局和大小窗口。

实现时为测试注入临时 HOME 与目标根，禁止测试触碰真实 `~/.claude`、`~/.codex`、`~/.agents` 或其他应用的私有目录。当前项目已有 206 项通过的测试可作为回归基线，但新增技能能力需要上述独立验收，不能仅依赖现有测试数量。

## 尚需在实现前验证的点

- 当前安装的 Codex、Pi 版本是否仍读取各自的旧技能根，以及共享目录是否能通过原生设置按 Agent 排除。未验证时显示能力未知，不通过删除共享目录绕过。
- 第三方 Skill 是否依赖特定 Agent 的工具、变量或运行环境。文件能导入不代表在所有 Agent 中都能执行。
- 新增 YAML 依赖的具体版本、许可与解析限制。
- Skill 路由需要额外评估：单一索引 Skill 可能减少初始列表，但会改变发现与调用路径；首版不为此增加网关依赖。

上游固定版本采用 MIT License（Copyright 2026 yetone）。若移植实现片段，保留原许可与版权声明。这个许可不自动覆盖从第三方仓库导入的每个 Skill；技能自身的 LICENSE、frontmatter 许可和来源信息分别保存。[Magpie LICENSE](https://github.com/yetone/magpie/blob/df2b819c6784dad093500be27bd015ddea734ebd/LICENSE)
