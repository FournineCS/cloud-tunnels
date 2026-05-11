import AppKit
import SwiftUI

/// Brand assets loaded from the SwiftPM resource bundle (`Bundle.module`).
/// PNGs sourced from `Resources/Branding/MenuBarIcon.svg` (the SQV mark) and
/// `Resources/Branding/AppIcon-source.png`. Both are rendered as **template**
/// images so AppKit recolors them based on menu-bar / popover state instead of
/// using the asset's literal pixel colors.
enum BrandImages {
    /// SQV monogram used as the macOS menu-bar status item glyph.
    /// `MenuBarExtra` renders its label at the NSImage's *intrinsic* size and
    /// largely ignores SwiftUI `.frame(...)` modifiers, so we must size the
    /// NSImage to menu-bar dimensions here. 20×15 keeps the SVG's natural
    /// 1.35:1 aspect ratio and reads well inside the 22pt menu bar without
    /// crowding adjacent extras.
    static let menuBarIcon: Image = {
        let nsImage = loadTemplate(named: "MenuBarIconTemplate", ext: "png")
        nsImage.size = NSSize(width: 20, height: 15)
        return Image(nsImage: nsImage)
    }()

    /// Same mark, used inline in the popover's brand header next to the
    /// wordmark. Sized larger here than the menu-bar variant — the popover
    /// has the room and the logo doubles as a brand anchor for the window.
    static let brandHeaderLogo: Image = {
        let nsImage = loadTemplate(named: "BrandHeaderLogo", ext: "png")
        nsImage.size = NSSize(width: 30, height: 22)
        return Image(nsImage: nsImage)
    }()

    private static func loadTemplate(named name: String, ext: String) -> NSImage {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext),
              let image = NSImage(contentsOf: url) else {
            // Fall back to a SF Symbol so the UI never renders a void —
            // this only fires if the resource is missing from the bundle.
            return NSImage(systemSymbolName: "cloud.fill", accessibilityDescription: name)
                ?? NSImage()
        }
        image.isTemplate = true
        return image
    }
}
