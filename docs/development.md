# 开发说明

Muster 使用 SwiftUI / AppKit，要求 macOS 14+ 和 Swift 6 工具链。安装 Command Line Tools 即可，不必安装完整 Xcode。Yams 6.2.2 的源码及许可放在 Vendor 中，构建不需在线拉取解析器。

```bash
Scripts/test.sh --no-parallel   # 核心逻辑和模型测试
Scripts/package.sh             # dist/Muster.app，默认内置仓库中的发布公钥
swift run Muster               # 开发运行；命令行构建不是可原地更新的应用安装
bash Scripts/test-update-signing.sh
python3 Scripts/test-update-installation.py  # 先运行测试，提供可测试的 debug 模块
python3 Scripts/make-icon.py    # 更新图标，需要 Pillow
```

Sources/MusterCore 保存会话扫描、清理、规则、配置和技能等逻辑；Sources/Muster 保存界面及装配。Tests 使用临时目录和可替换的系统接口，不应写真实 Agent 文件或运行第三方技能脚本。

改动应遵守现有管理范围、草稿保留及写入前检查。涉及配置、规则或技能落盘时，需要验证外部修改冲突、失败恢复和原文件保留；涉及界面时检查大小窗口、中英文、深浅色及舒适布局。

CI 会执行测试、构建包含可信更新公钥的应用、验证签名工具与发布约束，并用隔离应用验证下载、签名拒绝、替换和重启。CI 不持有生产私钥，不自动发布版本。

版本号以 Git tag 为准，格式为 X.Y.Z；打包时可以显式传入版本。正式发布的密钥、校验和上传步骤见[发布说明](releasing.md)。
