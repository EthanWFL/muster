# 移除旧版 Muster Hook

Muster 已移除工具调用审批功能，不再提供 `muster-hook` 可执行文件、审批 socket 或 Hook 设置入口。Agent 自己的权限确认机制不受影响。

如果从未安装过 Muster Hook，无需操作。旧设置中若仍引用该可执行文件，Agent 可能提示命令不存在；文件仍在其他旧安装目录时，也会继续尝试执行它。

## 清理步骤

1. 退出旧版 Muster。若旧版还可打开，可先在其设置页选择「卸载 Hook」。
2. 手动清理时，先复制一份配置文件作为备份。默认用户配置为 `~/.claude/settings.json`；使用 `CLAUDE_CONFIG_DIR` 时检查该目录的 `settings.json`。如果曾手动在项目里安装，也检查 `.claude/settings.json` 和 `.claude/settings.local.json`。
3. 在 `hooks.PreToolUse` 中找到 `type` 为 `command`、且命令确实指向旧 Muster 的 `muster-hook` 程序的条目，只删除该命令对象。不要仅凭命令字符串里出现该词就删除不明脚本。
4. 同一 matcher 下如果还有其他 Hook，保留它们。仅当删除后数组为空时，才删除对应的空 matcher 分组；其他事件及配置保持原样。
5. 保存合法 JSON 后，重新启动 Claude Code 会话，确认不再出现旧 Muster Hook 的执行错误。

不要删除 `permissions.allow` / `permissions.deny`，也不要用旧备份整体覆盖最新配置。旧版添加的永久放行规则与用户自行维护的规则可能混在一起，不自动撤销。

旧的 `~/Library/Application Support/Muster/backups/` 可保留作为历史备份；不必为了升级删除该目录。旧 Tab 偏好中的 `Approvals` 会被新版忽略，若上次停在审批页，会回到会话页。
