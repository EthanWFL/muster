import AppKit
import SwiftUI

/// 面板头部的蝠鲼动效：播 `Sources/Muster/Resources/manta-glide.gif`。
///
/// GIF 是黑蝠鲼 + 透明背景（220×220、80 帧、20fps、3.2s 一轮），配浅色面板；
/// 深色模式用 `CIColorInvert` 翻成白色，alpha 不变。
/// 「减弱动态效果」时停在首帧。
struct MantaPlayer: NSViewRepresentable {
    var size: CGFloat
    var animated: Bool
    var invert: Bool

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        // 不放大：即使外面给的 frame 反常，图也只会按逻辑尺寸画，不会撑爆标题区
        view.imageScaling = .scaleNone
        view.animates = animated
        view.wantsLayer = true
        // NSView 默认不裁剪：位图会按 220×220 原尺寸画出来盖住标题。
        // 把逻辑尺寸设成目标点数，并裁到边界内。
        view.image = MantaAssets.image(size: size)
        view.layer?.masksToBounds = true
        view.contentFilters = MantaAssets.filters(invert: invert)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        if view.image?.size != NSSize(width: size, height: size) {
            view.image = MantaAssets.image(size: size)
        }
        view.animates = animated
        view.contentFilters = MantaAssets.filters(invert: invert)
    }

    /// 让 SwiftUI 按外层 frame 布局这个 NSView，而不是按位图原始像素
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSImageView, context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }
}

enum MantaAssets {
    /// 多帧 GIF：`NSImageView.animates` 按 GIF 自带的帧延时播放
    private static let gif: NSImage? = {
        for bundle in AppResources.bundles {
            if let url = bundle.url(forResource: "manta-glide", withExtension: "gif") {
                return NSImage(contentsOf: url)
            }
        }
        return nil
    }()

    /// 同一个 NSImage 改逻辑尺寸会互相影响，按尺寸各留一份
    private static var cache: [CGFloat: NSImage] = [:]

    static func image(size: CGFloat) -> NSImage? {
        if let cached = cache[size] { return cached }
        guard let gif, let copy = gif.copy() as? NSImage else { return nil }
        copy.size = NSSize(width: size, height: size)
        cache[size] = copy
        return copy
    }

    static func filters(invert: Bool) -> [CIFilter] {
        guard invert, let filter = CIFilter(name: "CIColorInvert") else { return [] }
        return [filter]
    }
}
