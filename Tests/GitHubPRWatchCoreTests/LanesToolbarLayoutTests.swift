import Foundation
import Testing
@testable import GitHubPRWatchCore

@Suite struct LanesToolbarLayoutTests {
    @Test func tabsShowWhenThereIsRoom() {
        #expect(LanesToolbarLayout.showsTabs(tabsWidth: 300, windowWidth: 1100, reserved: 470))
        #expect(LanesToolbarLayout.showsTabs(tabsWidth: 300, windowWidth: 770, reserved: 470))
    }

    @Test func tabsCollapseToAMenuWhenNarrow() {
        #expect(!LanesToolbarLayout.showsTabs(tabsWidth: 300, windowWidth: 769, reserved: 470))
        #expect(!LanesToolbarLayout.showsTabs(tabsWidth: 560, windowWidth: 900))
        #expect(LanesToolbarLayout.showsTabs(tabsWidth: 500, windowWidth: 900))
    }

    @Test func unmeasuredTabsAreAssumedToFit() {
        #expect(LanesToolbarLayout.showsTabs(tabsWidth: 0, windowWidth: 400))
        #expect(LanesToolbarLayout.showsTabs(tabsWidth: 900, windowWidth: 0))
    }

    @Test func lastUpdatedWording() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(LanesToolbarLayout.lastUpdatedText(isRefreshing: true, lastUpdated: now, now: now) == "Updating…")
        #expect(LanesToolbarLayout.lastUpdatedText(isRefreshing: false, lastUpdated: nil, now: now) == "Not updated yet")
        #expect(LanesToolbarLayout.lastUpdatedText(isRefreshing: false, lastUpdated: now.addingTimeInterval(-20), now: now) == "Updated just now")
        #expect(LanesToolbarLayout.lastUpdatedText(isRefreshing: false, lastUpdated: now.addingTimeInterval(-240), now: now) == "Updated 4m ago")
    }
}

@Suite struct SettingsSectionTests {
    @Test func sidebarOrder() {
        #expect(SettingsTab.allCases == [.account, .repos, .notifications, .views, .advanced, .experiments, .debugging])
    }

    @Test func everySectionHasATitleAndItsOwnSymbol() {
        let symbols = SettingsTab.allCases.map(\.symbol)
        #expect(Set(symbols).count == symbols.count)
        #expect(SettingsTab.allCases.allSatisfy { !$0.title.isEmpty && !$0.symbol.isEmpty })
    }

    @Test func storedValuesStayReadable() {
        // The popover and earlier versions stored these raw values under this key.
        #expect(SettingsTab.storageKey == "settings.selectedTab")
        #expect(SettingsTab(rawValue: "notifications") == .notifications)
        #expect(SettingsTab(rawValue: "views") == .views)
    }
}
