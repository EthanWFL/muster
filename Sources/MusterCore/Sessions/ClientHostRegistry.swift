import Foundation

/// GUI hosts that can own an Agent process. Adding a terminal or editor is a
/// table entry, not another branch in the process walk.
public struct ClientHost: Sendable, Equatable {
    public let application: String
    public let name: String

    public init(application: String, name: String) {
        self.application = application
        self.name = name
    }
}

public enum ClientHostRegistry {
    public static let all: [ClientHost] = [
        .init(application: "Warp.app", name: "Warp"),
        .init(application: "WarpPreview.app", name: "Warp Preview"),
        .init(application: "Terminal.app", name: "Terminal"),
        .init(application: "iTerm.app", name: "iTerm"),
        .init(application: "iTerm2.app", name: "iTerm2"),
        .init(application: "Codex.app", name: "Codex"),
        .init(application: "ChatGPT.app", name: "ChatGPT"),
        .init(application: "Claude.app", name: "Claude"),
        .init(application: "Visual Studio Code.app", name: "VS Code"),
        .init(application: "Visual Studio Code - Insiders.app", name: "VS Code Insiders"),
        .init(application: "Cursor.app", name: "Cursor"),
        .init(application: "DeepSeek Harness.app", name: "DeepSeek Harness"),
        .init(application: "magpie.app", name: "Magpie"),
        .init(application: "Ghostty.app", name: "Ghostty"),
        .init(application: "Alacritty.app", name: "Alacritty"),
        .init(application: "kitty.app", name: "Kitty"),
        .init(application: "WezTerm.app", name: "WezTerm"),
    ]

    public static func name(forApplication application: String) -> String? {
        all.first { $0.application == application }?.name
    }
}
