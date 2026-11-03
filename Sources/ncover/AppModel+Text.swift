import AppKit
import NCoverKit
import SwiftUI

// The type controls, and the one place the font comes from.
//
// Font choice goes through `NSFontPanel` rather than a hand-rolled list: it is
// what a Mac user reaches for, it has search, favourites and collections
// already, and a popup of every installed PostScript name is a worse version
// of a thing the system ships.

extension AppModel {

    var textSpec: TextSpec {
        TextSpec(string: textString, font: textFont, size: textSize,
                 colour: textColour.rgb, x: textX, y: textY,
                 tracking: textTracking, lineSpacing: textLineSpacing)
    }

    /// Whether the chosen font is the one that will be used, or Core Text is
    /// quietly substituting. It matters less here than elsewhere — the glyphs
    /// become paths on the way out, so what is on screen is what the file gets
    /// — but "that is not the font I asked for" is worth being able to answer.
    var textFontIsReal: Bool { fontIsAvailable(textFont) }

    /// How the font reads in the inspector: the family and face, not the
    /// PostScript name, which is what the panel shows and what a person knows
    /// the font by.
    var textFontDisplayName: String {
        let f = NSFont(name: textFont, size: 13) ?? NSFont.systemFont(ofSize: 13)
        return f.displayName ?? textFont
    }

    /// Open the system font panel, pointed at the current font.
    func chooseFont() {
        let manager = NSFontManager.shared
        fontPanelBridge.listen(self)
        manager.target = fontPanelBridge
        manager.action = #selector(FontPanelBridge.changeFont(_:))
        manager.setSelectedFont(NSFont(name: textFont, size: max(12, textSize * 400))
                                ?? NSFont.systemFont(ofSize: 24),
                                isMultiple: false)
        manager.orderFrontFontPanel(nil)
    }

    /// Put the type where the artwork is not — the usual reason to move it off
    /// centre. Nothing clever: three thirds, which is where a label's wording
    /// nearly always wants to be.
    func placeText(x: Double, y: Double) {
        textX = x; textY = y
    }
}

/// Carries `NSFontManager`'s choice into the model.
///
/// Target/action again, for the same reason as the colour panel: this is the
/// interface AppKit offers. `changeFont(_:)` is handed the *old* font and asks
/// the manager to convert it, which is how the panel expresses "make this
/// bolder" as well as "use this family".
@MainActor
final class FontPanelBridge: NSObject {
    private weak var model: AppModel?

    func listen(_ model: AppModel) { self.model = model }

    @objc func changeFont(_ sender: Any?) {
        guard let manager = sender as? NSFontManager, let model else { return }
        let old = NSFont(name: model.textFont, size: 24) ?? NSFont.systemFont(ofSize: 24)
        let new = manager.convert(old)
        model.textFont = new.fontName
    }

    /// Only the face matters here; the size is the canvas-relative slider, and
    /// letting the panel set points too would give one quantity two owners.
    @objc func validModesForFontPanel(_ panel: NSFontPanel) -> NSFontPanel.ModeMask {
        [.face, .collection]
    }
}

@MainActor let fontPanelBridge = FontPanelBridge()
