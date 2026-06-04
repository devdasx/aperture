import Foundation

/// Corner radius scale, plus a `nested(parent:padding:)` helper that enforces
/// the iOS 26 concentric-corner rule:
///
///     child radius = max(0, parent radius − padding)
///
/// Every nested shape must compute its radius this way so glass shapes nest
/// cleanly inside their parents.
enum UniRadius {
    /// 6 pt — tight chips, dense controls.
    static let xs: CGFloat = 6
    /// 10 pt — small buttons.
    static let s: CGFloat = 10
    /// 14 pt — list rows, default controls.
    static let m: CGFloat = 14
    /// 18 pt — primary CTAs, sheets.
    static let l: CGFloat = 18
    /// 24 pt — cards.
    static let xl: CGFloat = 24
    /// 32 pt — large feature surfaces.
    static let xxl: CGFloat = 32

    /// Concentric corner math (HIG iOS 26).
    static func nested(parent: CGFloat, padding: CGFloat) -> CGFloat {
        max(0, parent - padding)
    }
}
