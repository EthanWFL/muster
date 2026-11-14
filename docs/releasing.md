# 签名与发布

正式更新同时依赖安装在用户电脑里的可信公钥和发布页的 DMG 签名。SHA-256 只用于完整性校验，不能代替签名，也不能让无公钥的旧构建自动建立信任。

## 长期密钥

发布公钥固定保存在 [Resources/UpdatePublicKey.txt](../Resources/UpdatePublicKey.txt)，每次正常打包都会嵌入 Info.plist 的 MusterUpdatePublicKey。私钥不在仓库、应用包或发布附件中。

本机默认从 `~/.config/muster/release/update-signing.key` 读取发布私钥（配置 XDG_CONFIG_HOME 时使用相应目录）。也可通过 MUSTER_UPDATE_KEY_FILE 指向仓库外的绝对路径。私钥文件必须属于当前用户且为 0600 权限，所在目录为 0700，并应另做安全备份。打包前会验证其公钥与仓库公钥一致。

缺少已有私钥时，应从安全备份恢复。不要为每次发布重新生成密钥，也不要为了通过打包检查而替换仓库公钥；密钥丢失或受控轮换需要另行安排信任迁移。

只有初始化新产品或明确安排信任迁移时才使用 `swift Scripts/sign-update.swift generate-key /outside/repository/update-signing.key`。该命令拒绝覆盖既有文件，只输出公钥。私钥、令牌和其他凭据不得提交、打印或作为附件上传。

## 正式发布

1. 完成代码与文档、必要测试及版本说明，提交并推送主分支，等待 CI 通过。
2. 在经过验证的提交上创建准确的 X.Y.Z 标签并推送，等待该标签的 CI 全部通过；不要覆盖已有版本。
3. 执行发布入口，例如本次修复版：

```bash
python3 Scripts/release.py 1.1.1 --notes docs/releases/1.1.1.md
```

发布入口要求工作区干净、本地和远端标签指向当前提交、对应标签 CI 成功、版本尚未发布。随后构建、签名和验证产物，发布正式 Release 并附上：

- Muster-X.Y.Z.dmg
- Muster-X.Y.Z.dmg.sig
- Muster-X.Y.Z.sha256

`Scripts/package.sh --dmg X.Y.Z` 也会要求匹配的长期私钥；缺少或不匹配时在构建前失败。无私钥的本地实验可显式传入 `--allow-unsigned-dmg`，其产物不能通过正式发布校验，不应作为官方版本分发。CI 仅构建应用，因此无需生产私钥。

`python3 Scripts/verify-release.py X.Y.Z` 检查应用公钥、版本、代码签名、DMG 发布签名、SHA-256，并挂载 DMG 核对包内应用。发布后应重新下载三个附件，以固定公钥和校验文件回验。

## 安装安全与旧版迁移

应用从当前安装包取可信公钥，不信任更新包自行声明的新公钥。安装前检查发布签名、应用标识、版本、架构、目标安装路径及密钥连续性；替换失败尝试恢复旧包。进程退出后才从同一路径重新启动。

1.0.0、1.1.0 等无公钥构建需先手动安装一次 1.1.1 或更新的正式版本。对远端增加 .sig 不会改变旧应用的信任锚点。隔离测试中的带公钥旧版副本只是更新链路模拟，不能证明已发布的无公钥旧版可以直接自动升级。

Ed25519 更新签名与 Apple Developer ID／公证是两回事。目前安装包仍使用 ad-hoc 代码签名，尚未公证；MUSTER_SIGNING_IDENTITY 可指定已有 Developer ID。若将来公证或装订改变 DMG，必须对最终 DMG 重新签名和计算校验值。
