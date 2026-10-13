import Foundation

/// The calendar and message board pages (shared/LAYOUTS.md): 800x480, the panel's 7 colours
/// only, no anti-aliasing, drawn with the bundled Noto Sans CJK TC subsets.
public enum PaperhuePages {
    /// `Fonts/` in this target's resource bundle: the two OTF subsets and their licence,
    /// byte-identical to python/src/ulani_epaper/fonts.
    public static var fontsDirectory: URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fonts", isDirectory: true)
    }
}
