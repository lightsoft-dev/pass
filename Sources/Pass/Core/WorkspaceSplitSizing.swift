import Foundation

/// Shared resize policy for the browser and device panes. Their stored fraction is a
/// preference, not a promise: narrow panels must still leave both panes usable.
enum WorkspaceSplitSizing {
    static let preferredFractionRange: ClosedRange<CGFloat> = 0.2...0.8
    static let minimumPaneWidth: CGFloat = 120

    static func clampedFraction(_ fraction: CGFloat, total: CGFloat, dividerWidth: CGFloat) -> CGFloat {
        guard total > 0 else { return preferredFractionRange.clamp(fraction) }

        let lower = max(preferredFractionRange.lowerBound, minimumPaneWidth / total)
        let upper = min(preferredFractionRange.upperBound, (total - dividerWidth - minimumPaneWidth) / total)
        guard lower <= upper else { return 0.5 }
        return min(upper, max(lower, fraction))
    }

    static func terminalWidth(total: CGFloat, fraction: CGFloat, dividerWidth: CGFloat) -> CGFloat {
        let resolvedFraction = clampedFraction(fraction, total: total, dividerWidth: dividerWidth)
        return max(0, total * (1 - resolvedFraction) - dividerWidth)
    }

    static func resizedFraction(from start: CGFloat, translation: CGFloat,
                                total: CGFloat, dividerWidth: CGFloat) -> CGFloat {
        guard total > 0 else { return preferredFractionRange.clamp(start) }
        return clampedFraction(start - translation / total, total: total, dividerWidth: dividerWidth)
    }
}

private extension ClosedRange where Bound == CGFloat {
    func clamp(_ value: CGFloat) -> CGFloat {
        Swift.min(upperBound, Swift.max(lowerBound, value))
    }
}
