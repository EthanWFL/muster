# Magpie 技能资源库源码调研

调研日期：2026-11-14。上游仓库：[yetone/magpie](https://github.com/yetone/magpie)。本记录固定在提交 [`df2b819c6784dad093500be27bd015ddea734ebd`](https://github.com/yetone/magpie/commit/df2b819c6784dad093500be27bd015ddea734ebd)，提交时间为北京时间 2026-11-14 15:05:21。通过 GitHub tree API 和固定提交的 raw 文件核对源码，没有运行上游应用、安装脚本或测试。

结论：截图里的功能已有完整实现，Muster 可以在现有 SwiftUI / MusterCore 结构内复现其主要流程。适合借鉴的是技能目录、来源记录、部署归属和冲突处理；UI 与文件操作实现需要按 Muster 的结构重写。完整实施安排见 [Agent 与技能整合方案](agent-skills-implementation-plan.md)。

范围说明：本文记录 Magpie 的行为作为功能参考。用户已明确要求 Muster 独立复刻技能功能，不对接 Magpie。下文关于 Magpie 库、接管和同步的说明不构成 Muster 的集成需求；实际范围以实现方案为准。

## 1. 截图功能对应的真实实现

| 功能 | 上游实际行为 | 源码 |
|---|---|---|
| 查找技能 | 输入 GitHub owner/repo、GitHub/GitLab 页面、其他 Git 地址或本地目录；先探测候选技能，后选择技能和目标 Agent 安装 | [UI 查找与新建](https://github.com/yetone/magpie/blob/df2b819c6784dad093500be27bd015ddea734ebd/internal/gui/assets/plugins/library/client.js#L7302-L7378)、[ProbeSkills](https://github.com/yetone/magpie/blob/df2b819c6784dad093500be27bd015ddea734ebd/internal/library/skills.go#L1399-L1511) |
| 新建技能 | 校验名称及描述，创建含 YAML front matter 的 SKILL.md，并记录目标 Agent；不需要模型 API | [CreateSkill](https://github.com/yetone/magpie/blob/df2b819c6784dad093500be27bd015ddea734ebd/internal/library/skills.go#L1740-L1783) |
| 按 Agent 分发 | 技能保存 Agents 列表；统一同步流程将链接或副本部署到目标目录，并记录已管理的内容 | [Skill](https://github.com/yetone/magpie/blob/df2b819c6784dad093500be27bd015ddea734ebd/internal/library/skills.go#L32-L79)、[changeLocked](https://github.com/yetone/magpie/blob/df2b819c6784dad093500be27bd015ddea734ebd/internal/library/library.go#L345-L371) |
| 链接／副本 | 默认链接；可以设置全局方式和每个 Agent 的覆盖值。副本带管理标记和内容哈希，更新时整目录替换 | [skill_how.go](https://github.com/yetone/magpie/blob/df2b819c6784dad093500be27bd015ddea734ebd/internal/library/skill_how.go#L3-L83)、[copyIn](https://github.com/yetone/magpie/blob/df2b819c6784dad093500be27bd015ddea734ebd/internal/library/skills.go#L254-L362) |
| Agent 中已有 | 扫描资源库未登记目录、共享技能目录和各 Agent 目录，区分同一真实路径、内容相同副本与同名不同内容 | [foundSkills](https://github.com/yetone/magpie/blob/df2b819c6784dad093500be27bd015ddea734ebd/internal/library/skills.go#L2401-L2476) |
| 技能内容编辑 | 支持读取技能内文本文件；保存时检查原文本是否变化，拒绝目录外路径和越界符号链接，使用原子文件写入 | [ReadSkillFile / SaveSkillFile](https://github.com/yetone/magpie/blob/df2b819c6784dad093500be27bd015ddea734ebd/internal/library/skill_file.go#L42-L150) |
| 更新 | 记录远程来源、内容哈希和提交；更新前检测本地修改，下载结束后再次检测；批量更新可以部分成功，修改过的技能默认跳过 | [UpdateSkill / UpdateSkills](https://github.com/yetone/magpie/blob/df2b819c6784dad093500be27bd015ddea734ebd/internal/library/skills.go#L1786-L1845)、[skillcheck.go](https://github.com/yetone/magpie/blob/df2b819c6784dad093500be27bd015ddea734ebd/internal/library/skillcheck.go) |
| Skill 路由 | 生成一个 magpie-skills，其正文列出可用技能的描述及 SKILL.md 路径，Agent 再读取具体文件；它是本地索引技能 | [skill_router.go](https://github.com/yetone/magpie/blob/df2b819c6784dad093500be27bd015ddea734ebd/internal/library/skill_router.go#L100-L178) |

## 2. 存储、解析与导入

资源库的登记数据在配置目录下的 `library.json`；技能目录在 `library/skills/<name>/`。`Library.Applied` 保存 Magpie 对每个 Agent 管理过的内容。技能的 `Source` 区分 `github`、`git` 和 `folder`，记录仓库、ref、仓库内路径或本地目录；`Hash`、`Commit` 用于判断远端和本地是否发生变化。[Library 定义与路径](https://github.com/yetone/magpie/blob/df2b819c6784dad093500be27bd015ddea734ebd/internal/library/library.go#L22-L74)、[库路径](https://github.com/yetone/magpie/blob/df2b819c6784dad093500be27bd015ddea734ebd/internal/library/library.go#L199-L202)、[Source 定义](https://github.com/yetone/magpie/blob/df2b819c6784dad093500be27bd015ddea734ebd/internal/library/skills.go#L123-L166)。

技能是一个包含 `SKILL.md` 的完整目录，脚本和引用文件跟随目录一起部署。元数据使用 YAML 解析，读取 `name`、`description` 和 `disable-model-invocation`。解析前统一 CRLF，名称和描述再做空白清理。当前解析器会忽略 YAML 解析错误，退回文件夹名称等信息；Muster 应明确显示“元数据无效”，不能把“有 SKILL.md”直接等同于“目标 Agent 能正常加载”。[元数据解析](https://github.com/yetone/magpie/blob/df2b819c6784dad093500be27bd015ddea734ebd/internal/library/skills.go#L168-L210)。

候选扫描有深度限制，会跳过 `node_modules`，也识别 `.claude/skills` 一类隐藏目录下的技能。普通技能内部不会无限递归；包含多个子技能的集合另作处理。这意味着复现时不能只检查仓库根目录，也不能把扫描范围直接扩展为整个用户主目录。[candidates](https://github.com/yetone/magpie/blob/df2b819c6784dad093500be27bd015ddea734ebd/internal/library/skills.go#L1244-L1294)。

三类导入行为并不相同：

- 远程仓库：复制选中的完整技能目录到资源库，并保存来源。已有相同来源不重复安装；来自另一仓库的同名技能可以生成新名称，并调整受管理副本的 front matter 名称。
- 本地文件夹：通常在资源库内链接到原文件夹，修改原目录就会影响技能。与现有技能同名时，不能擅自改写原目录的 SKILL.md。
- Agent 已有技能：普通实体目录可能迁入库，再替原 Agent 建链接；外部链接或共享目录里的技能通常先保留原位置，仅在库里建立引用。

这些区别已写在实际安装和导入流程中。[installFrom](https://github.com/yetone/magpie/blob/df2b819c6784dad093500be27bd015ddea734ebd/internal/library/skills.go#L1573-L1712)、[importSkill](https://github.com/yetone/magpie/blob/df2b819c6784dad093500be27bd015ddea734ebd/internal/library/skills.go#L2576-L2643)。Muster 第一版建议采用“复制导入并保留原目录”，将来源、外部管理状态和重复项展示给用户；不移动用户原有的文件夹，也不增加针对来源应用的专用迁移逻辑。

## 3. 共享目录决定了开关能做到什么

`~/.agents/skills` 会被多个 Agent 自行扫描。放在那里的一项技能，即便取消 Magpie 中某个 Agent 的勾选，也可能继续可见。Magpie 的 `SkillView.Always` 专门表示这种状态，UI 使用锁定提示；它也记录 Agent 会读取其他 Agent 目录的关系。[Always 计算](https://github.com/yetone/magpie/blob/df2b819c6784dad093500be27bd015ddea734ebd/internal/library/sync.go#L470-L510)、[共享可见性](https://github.com/yetone/magpie/blob/df2b819c6784dad093500be27bd015ddea734ebd/internal/library/sync.go#L748-L759)、[UI 提示](https://github.com/yetone/magpie/blob/df2b819c6784dad093500be27bd015ddea734ebd/internal/gui/assets/plugins/library/client.js#L7283-L7295)。

截图中的“SKILLS 放在”选择有两种含义：

| 模式 | 实际效果 |
|---|---|
| 各 Agent 自己的目录 | 按分配关系部署；仍需考虑 Agent 对共享目录及其他目录的额外扫描 |
| `~/.agents/skills` | 将本机开启的库技能也链接到共享目录，读取该目录的 Agent 会看到它们，不能承诺逐 Agent 隔离 |

此行为在 [skills_shared.go](https://github.com/yetone/magpie/blob/df2b819c6784dad093500be27bd015ddea734ebd/internal/library/skills_shared.go#L3-L65) 和 [选择控件](https://github.com/yetone/magpie/blob/df2b819c6784dad093500be27bd015ddea734ebd/internal/gui/assets/plugins/library/client.js#L6851-L6867) 中一致。

Magpie 提供显式 `HandOverSkills`：把共享目录中的实体技能迁入库，移除原共享入口，给之前读取它的 Agent 重新分配；跨盘复制要读回校验，失败则保留原目录。普通“导入”和“接管共享技能”是两个动作，不应合并成一个无说明的开关。[接管说明与流程](https://github.com/yetone/magpie/blob/df2b819c6784dad093500be27bd015ddea734ebd/internal/library/skill_handover.go#L13-L31)、[moveIn 的失败恢复](https://github.com/yetone/magpie/blob/df2b819c6784dad093500be27bd015ddea734ebd/internal/library/skill_handover.go#L184-L241)。

当前 Magpie 的 Codex 部署目录仍是 `codexDir()/skills`，同时在额外读取共享目录的 Agent 列表里登记 Codex；Pi 则按版本识别共享目录支持。[Agent 目标路径](https://github.com/yetone/magpie/blob/df2b819c6784dad093500be27bd015ddea734ebd/internal/library/targets.go#L182-L247)、[共享读取能力](https://github.com/yetone/magpie/blob/df2b819c6784dad093500be27bd015ddea734ebd/internal/library/targets.go#L1087-L1119)。这是 Magpie 当前适配策略，不是各 Agent 最新目录规范的替代。Codex 当前官方说明以用户目录 `~/.agents/skills` 为入口；Muster 应按目标版本验证兼容目录，不直接沿用上游的 `~/.codex/skills` 假定。[Codex 官方技能说明](https://learn.chatgpt.com/docs/build-skills)。

因此 Muster 需要分别表示“已分配”“受本应用管理的链接／副本存在”“还可从外部目录发现”“需要重新加载”。文件分发成功不能直接显示为“正在运行的 Agent 已加载”。

## 4. 路由功能适合后置

路由为每个可支持的 Agent 生成一个索引技能，并把被路由技能放在隐藏 `.skills` 引用路径下。手动调用技能、共享目录技能、副本部署等情况会保留直接部署；索引名称被占用也会退回普通部署。它会影响 `/技能名` 直接调用方式。[routerWhy / routable / routedFor](https://github.com/yetone/magpie/blob/df2b819c6784dad093500be27bd015ddea734ebd/internal/library/skill_router.go#L120-L176)。

上游还会为 Claude Code 写入受管理的 `permissions.allow` Read 规则。Muster 目前没有这条权限写入流程，第一版不宜为了路由顺带增加它。[routerRules / routerAllow](https://github.com/yetone/magpie/blob/df2b819c6784dad093500be27bd015ddea734ebd/internal/library/skill_router.go#L230-L318)。UI 已明确提示重启 Agent 后读取变更。[路由 UI](https://github.com/yetone/magpie/blob/df2b819c6784dad093500be27bd015ddea734ebd/internal/gui/assets/plugins/library/client.js#L6870-L6915)。

建议先验证常规技能部署，再评估索引是否改善实际使用。不要提前承诺确定的 token 节省比例或执行效果。

## 5. 可借鉴的文件保护与测试

远程 Git 地址通过参数传给进程，避免拼接 Shell；拒绝命令型 transport、以选项形式开头的地址及含密码的 URL，限制命令时间。检出时禁用符号链接，下载后做大小检查；GitHub 压缩包解包只处理普通文件和目录，过滤越界路径。[Git 输入与执行](https://github.com/yetone/magpie/blob/df2b819c6784dad093500be27bd015ddea734ebd/internal/library/skillgit.go#L46-L131)、[runGit](https://github.com/yetone/magpie/blob/df2b819c6784dad093500be27bd015ddea734ebd/internal/library/skillgit.go#L219-L234)、[fetchGit](https://github.com/yetone/magpie/blob/df2b819c6784dad093500be27bd015ddea734ebd/internal/library/skillgit.go#L302-L354)、[untar](https://github.com/yetone/magpie/blob/df2b819c6784dad093500be27bd015ddea734ebd/internal/library/skills.go#L1191-L1242)。

部署先识别归属：链接检查目标，副本检查管理标记和哈希。副本在旁边生成完整目录后替换，失败尝试恢复旧目录。冲突时可以保留 Agent 自己的版本，或将其备份后使用库版本。备份按操作分组；包含被移走技能实体的备份不按普通最近 30 次规则清理。[归属与副本替换](https://github.com/yetone/magpie/blob/df2b819c6784dad093500be27bd015ddea734ebd/internal/library/skills.go#L254-L362)、[冲突操作](https://github.com/yetone/magpie/blob/df2b819c6784dad093500be27bd015ddea734ebd/internal/library/skills.go#L2280-L2357)、[备份](https://github.com/yetone/magpie/blob/df2b819c6784dad093500be27bd015ddea734ebd/internal/library/backup.go)。

上游总同步流程是先保存期望状态，再同步目标，最后保存实际写入记录。它允许每个目标部分失败，并不提供跨所有 Agent 的原子事务。Muster 应返回逐项结果，写入前重新验证预览涉及的文件，保留每项可恢复记录；不能用一个成功布尔值覆盖整个批次。[changeLocked](https://github.com/yetone/magpie/blob/df2b819c6784dad093500be27bd015ddea734ebd/internal/library/library.go#L355-L371)。

Magpie 还会把 Agent 副本中较新的编辑收回资源库，再同步给其他 Agent；冲突版本另行备份。Muster 第一版建议仅报告副本差异，由用户选择采用哪一版，避免一次局部编辑自动传播给其他 Agent。[takeEdits](https://github.com/yetone/magpie/blob/df2b819c6784dad093500be27bd015ddea734ebd/internal/library/skill_edits.go#L3-L26)。

已确认存在以下测试，本文仅检查测试代码，未运行上游测试：

- [skill_how_test.go](https://github.com/yetone/magpie/blob/df2b819c6784dad093500be27bd015ddea734ebd/internal/library/skill_how_test.go)：链接／副本切换，保留无法读取的副本。
- [skills_shared_test.go](https://github.com/yetone/magpie/blob/df2b819c6784dad093500be27bd015ddea734ebd/internal/library/skills_shared_test.go)：共享模式和 Pi 版本条件。
- [skill_handover_test.go](https://github.com/yetone/magpie/blob/df2b819c6784dad093500be27bd015ddea734ebd/internal/library/skill_handover_test.go)：共享实体／链接接管、失败保留原目录、异名入口。
- [skill_file_test.go](https://github.com/yetone/magpie/blob/df2b819c6784dad093500be27bd015ddea734ebd/internal/library/skill_file_test.go)：保存冲突、限制技能目录范围、保留换行符。
- [skillgit_test.go](https://github.com/yetone/magpie/blob/df2b819c6784dad093500be27bd015ddea734ebd/internal/library/skillgit_test.go)：Git 来源、子目录、认证失败、选项及 transport 拒绝。
- [skill_router_test.go](https://github.com/yetone/magpie/blob/df2b819c6784dad093500be27bd015ddea734ebd/internal/library/skill_router_test.go)：路由开关、最后一项取消、保留用户自有索引、描述长度与 Read 规则。

## 6. 移植建议

| 可以沿用的设计 | Muster 需要重新实现的部分 |
|---|---|
| 一份受管理技能目录、来源记录、内容哈希 | 使用 Application Support 下的私有目录与 Swift 数据模型 |
| 探测候选 → 选择 → 导入 → 部署 | 原生 SwiftUI 窗口、异步进度、取消和错误反馈 |
| 期望分配与实际部署状态分离 | 接入现有 AgentRegistry，分别记录部署路径、额外发现目录、版本与重载行为 |
| 只管理自己建立的链接／副本 | 受管理清单、写入预检、文件变化检查、恢复记录 |
| 不覆盖同名外部技能，部分失败可见 | 统一识别非 Muster 创建的目录／链接并报告冲突，无需识别来源应用 |
| YAML front matter 与目录级技能 | 完整 YAML 解析、保留未知字段、不误删附带文件 |

第一阶段宜实现本地扫描、复制导入、新建、查看／编辑、按已验证 Agent 部署和取消部署。GitHub／Git 来源、版本更新、共享布局设置、路由及技能市场可以逐阶段增加。Muster 的规则与配置模块只需迁入 Agent 页的子导航，先保留原存储与写入流程，避免 UI 整合同时演变为全量数据迁移。

上游主许可证是 MIT，版权归属为 `Copyright (c) 2026 yetone`；复制或改编实质代码时须保留对应版权及许可声明，第三方代码另查 `THIRD_PARTY_NOTICES`。独立 Swift 实现也应在设计记录中保留来源，不复用 Magpie 品牌或图标。[LICENSE](https://github.com/yetone/magpie/blob/df2b819c6784dad093500be27bd015ddea734ebd/LICENSE)、[THIRD_PARTY_NOTICES](https://github.com/yetone/magpie/blob/df2b819c6784dad093500be27bd015ddea734ebd/THIRD_PARTY_NOTICES)。
