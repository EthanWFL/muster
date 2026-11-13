import Foundation

/// macOS 会为这些目录弹「想访问文档/桌面/下载文件夹」的授权框。扫描类功能碰到它们就跳过，
/// 否则用户第一次打开面板就被系统弹窗打断（面板失焦会直接收起）。
/// shortcut: 这些目录里的项目拿不到分支和 worktree 清理，要支持再做显式授权入口。
public enum ProtectedFolders {
    public static func contains(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        let roots = ["Documents", "Desktop", "Downloads", "Library/Mobile Documents"].map { home + "/" + $0 }
            + ["/Volumes"]
        let target = (path as NSString).standardizingPath
        return roots.contains { target == $0 || target.hasPrefix($0 + "/") }
    }
}
