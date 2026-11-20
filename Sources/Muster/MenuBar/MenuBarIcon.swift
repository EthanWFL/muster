import AppKit

/// 面板打开时熊猫眨一次眼，菜单栏始终使用睁眼的末帧。
enum MenuBarIcon {
    static let frames = loadStrip("panda-blink")
    static let wheelLayers = loadStrip("panda-wheel-layers")

    private static func loadStrip(_ name: String) -> [NSImage] {
        let url = AppResources.bundles.compactMap { $0.url(forResource: name, withExtension: "png") }.first
            ?? Bundle.module.url(forResource: name, withExtension: "png")
        guard let url, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let strip = CGImageSourceCreateImageAtIndex(source, 0, nil),
              strip.width.isMultiple(of: strip.height) else { return [] }
        let side = strip.height
        return stride(from: 0, to: strip.width, by: side).compactMap { x in
            guard let frame = strip.cropping(to: CGRect(x: x, y: 0, width: side, height: side)) else { return nil }
            let image = NSImage(cgImage: frame, size: NSSize(width: 18, height: 18))
            image.isTemplate = true
            return image
        }
    }

    static let image = frames.last ?? NSImage(systemSymbolName: "circle", accessibilityDescription: nil)!
}
