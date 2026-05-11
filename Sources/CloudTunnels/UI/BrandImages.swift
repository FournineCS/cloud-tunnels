import AppKit
import SwiftUI

/// Brand assets loaded from the app bundle's `Contents/Resources/` directory.
/// PNGs sourced from `Resources/Branding/MenuBarIcon.svg` (the SQV mark) and
/// `Resources/Branding/AppIcon-source.png`. Both are rendered as **template**
/// images so AppKit recolors them based on menu-bar / popover state instead of
/// using the asset's literal pixel colors.
///
/// Loaded via `Bundle.main` rather than SwiftPM's generated `Bundle.module` —
/// SPM's `Bundle.module` accessor for `.executableTarget` resolves to
/// `Bundle.main.bundleURL.appendingPathComponent("CloudTunnels_CloudTunnels.bundle")`,
/// which on an installed `.app` resolves to a sibling-of-Contents path that
/// does not exist, causing a fatal crash at launch. Copying the PNGs directly
/// into `Contents/Resources/` and reading via `Bundle.main` is the standard
/// Mac-app resource pattern.
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
        guard let url = Bundle.main.url(forResource: name, withExtension: ext),
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
