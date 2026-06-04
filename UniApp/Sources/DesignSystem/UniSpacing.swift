import Foundation

/// Spacing scale on a 4-pt grid. Use these tokens for all paddings, gaps,
/// and offsets — never hard-code a raw number in feature views.
enum UniSpacing {
    /// 4 pt — tightest inline gap (icon to small label).
    static let xxs: CGFloat = 4
    /// 8 pt — element-to-element inside a tight group.
    static let xs: CGFloat = 8
    /// 12 pt — default control gap.
    static let s: CGFloat = 12
    /// 16 pt — default content padding and section gap.
    static let m: CGFloat = 16
    /// 20 pt — between sibling stacks.
    static let mPlus: CGFloat = 20
    /// 24 pt — screen horizontal padding default.
    static let l: CGFloat = 24
    /// 32 pt — section separator.
    static let xl: CGFloat = 32
    /// 48 pt — generous hero spacing.
    static let xxl: CGFloat = 48
    /// 64 pt — full-screen empty-state breathing room.
    static let xxxl: CGFloat = 64
}
