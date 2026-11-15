import SwiftUI
#if os(macOS)
import AppKit

typealias PlatformImage = NSImage

extension NSImage {
    var cgImageValue: CGImage? {
        var rect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    static func load(_ url: URL) -> NSImage? { NSImage(contentsOf: url) }

    static func make(cgImage: CGImage, like original: NSImage) -> NSImage {
        NSImage(cgImage: cgImage, size: original.size)
    }
}

extension Image {
    init(platformImage: NSImage) { self.init(nsImage: platformImage) }
}

func sRGBComponents(_ color: Color) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
    let ns = NSColor(color)
    let rgb = ns.usingColorSpace(.sRGB) ?? ns
    return (rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
}
#else
import UIKit

typealias PlatformImage = UIImage

extension UIImage {
    var cgImageValue: CGImage? {
        if imageOrientation == .up, let cgImage { return cgImage }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in draw(at: .zero) }.cgImage
    }

    static func load(_ url: URL) -> UIImage? { UIImage(contentsOfFile: url.path) }

    static func make(cgImage: CGImage, like original: UIImage) -> UIImage {
        UIImage(cgImage: cgImage, scale: original.scale, orientation: .up)
    }
}

extension Image {
    init(platformImage: UIImage) { self.init(uiImage: platformImage) }
}

func sRGBComponents(_ color: Color) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
    let resolved = UIColor(color).resolvedColor(with: UITraitCollection.current)
    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
    resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    return (red, green, blue)
}
#endif
