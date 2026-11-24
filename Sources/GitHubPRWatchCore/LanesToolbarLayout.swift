import Foundation

/// What the main window's toolbar says and how it fits.
///
/// The view picker is a row of tabs while the window has room for them and the controls on
/// the trailing side, and one menu otherwise. A toolbar offers its items no width to fit into,
/// so the window measures the tabs and asks here.
public enum LanesToolbarLayout {
    /// Room kept for everything else in the toolbar: the last-updated text, Refresh,
    /// New View, the filter field, and the toolbar's own margins and gaps.
    public static let reservedWidth: CGFloat = 380

    /// Whether the tabs fit in a window `windowWidth` wide. Before the tabs have been measured
    /// (`tabsWidth` is zero) they are assumed to fit, so the first frame does not flash a menu.
    public static func showsTabs(tabsWidth: CGFloat, windowWidth: CGFloat, reserved: CGFloat = reservedWidth) -> Bool {
        guard tabsWidth > 0, windowWidth > 0 else { return true }
        return tabsWidth + reserved <= windowWidth
    }

    /// `Updating…`, `Updated just now`, `Updated 4m ago`, or `Not updated yet`.
    public static func lastUpdatedText(isRefreshing: Bool, lastUpdated: Date?, now: Date) -> String {
        if isRefreshing { return "Updating…" }
        guard let lastUpdated else { return "Not updated yet" }
        let ago = Formatting.ago(lastUpdated, now: now)
        return ago == "now" ? "Updated just now" : "Updated \(ago)"
    }
}
