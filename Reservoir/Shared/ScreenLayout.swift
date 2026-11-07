import CoreGraphics

/// How a screen arranges its cards for the space it is given (reservoir-h2k). Chosen from
/// the container's width and height, not the device model, so the cover display, the
/// inner display, a rotated phone and any future wide window all fall out of the same
/// rule. Pure so the thresholds are unit-testable.
enum ScreenLayout: Equatable {
    /// One column, the layout every phone has used so far.
    case column
    /// Wide and tall: the lead content full width, supporting cards side by side below.
    case wideColumn
    /// Wide and short: the lead content pinned on the left, supporting cards on the right.
    case panes

    /// Width in points from which a second column fits (the inner display is about 626).
    static let wideMinimumWidth: CGFloat = 600

    static func layout(for size: CGSize) -> ScreenLayout {
        guard size.width >= wideMinimumWidth else { return .column }
        return size.width > size.height ? .panes : .wideColumn
    }
}
