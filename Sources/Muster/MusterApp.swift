import MusterCore
import SwiftUI

@main
struct MusterApp: App {
    @StateObject private var model = PanelModel()

    init() {
        // 打包前也不出现 Dock 图标；打包后由 Info.plist 的 LSUIElement 接管
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "terminal")
                if !model.pending.isEmpty { Text("\(model.pending.count)") }
            }
            // label 在启动时就会渲染，借此启动 daemon（菜单内容视图要点开才创建）
            .task { model.start() }
        }
        .menuBarExtraStyle(.window)
    }
}
