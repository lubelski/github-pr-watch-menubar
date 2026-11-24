// Renders of the view editor sheet. Called from main.swift.
import AppKit
import GitHubPRWatchCore
import GitHubPRWatchUI
import SwiftUI

@MainActor
func renderViewEditor() async throws {
    let config = AppConfig(authMethod: .githubCLI, viewer: SampleData.viewer, watchedRepos: ["acme/web", "acme/api"], onboardingComplete: true)
    var prs = SampleData.pullRequests()
    // A few more authors and labels, so the Watchlist preview and suggestions have content.
    prs.append(PullRequest(
        id: "PR_extra1", repo: "acme/web", number: 4812, title: "Copy tweaks on pricing page", author: "srivera",
        labels: ["copy"], reviewDecision: .reviewRequired, mergeStateStatus: .blocked, headSHA: "m1",
        updatedAt: Date().addingTimeInterval(-1500),
        checks: CheckSummary(headSHA: "m1", rollup: nil, checks: [CheckRun(name: "build", status: .completed, conclusion: .success, startedAt: Date().addingTimeInterval(-3000), completedAt: Date().addingTimeInterval(-2000))])
    ))
    prs.append(PullRequest(
        id: "PR_extra2", repo: "acme/api", number: 1301, title: "Spike: streaming exports", isDraft: true, author: "nhaddad",
        mergeStateStatus: .unknown, headSHA: "n1", updatedAt: Date().addingTimeInterval(-600)
    ))
    let store = PRStore(dependencies: .inMemory(
        api: StaticGitHubAPI(prs: prs, teams: SampleData.teams), config: config, views: SampleData.views
    ))
    await store.refresh()

    let noTeams = PRStore(dependencies: .inMemory(api: StaticGitHubAPI(prs: prs, teams: nil), config: config, views: SampleData.views))
    await noTeams.refresh()

    // Editing the Watchlist with several logins.
    var watchlist = ViewDraft(BuiltInViews.watchlist(["tbrandt", "nhaddad"]))
    if case .row(var row) = watchlist.items[0].content {
        row.addTokens(TokenInput.split("srivera, apark jlin-agent"))
        watchlist.update(row)
    }
    watchlist.pinnedToMenubar = false

    // "(authored by me or assigned to me) and not a draft", plus label and CI rows.
    let nestedRule = FilterRule(match: .all, [
        .group(FilterRule(match: .any, [.predicate(.author(.me)), .predicate(.assignee(.me))])),
        .predicate(.isDraft(false)),
        .predicate(.not(.label(["do-not-watch"]))),
        .predicate(.ci([.failed, .running])),
    ])
    let nested = ViewDraft(SavedView(id: BuiltInViews.mineID, name: "Mine", symbol: "tray", rule: nestedRule, notify: BuiltInViews.mine.notify, pinnedToMenubar: true))

    // A blank view with nothing filled in, after pressing Save.
    var invalid = ViewTemplate.blank.draft()
    invalid.addRow(field: .ci)
    invalid.addGroup()

    let review = ViewTemplate.needsMyReview.draft(existingNames: store.views.map(\.name))

    let editorSize = CGSize(width: 680, height: 1000)
    for dark in [false, true] {
        try render("view-editor-watchlist", ViewEditorForm(store: store, draft: watchlist, isNew: false), size: editorSize, dark: dark)
    }
    try render(
        "view-editor-nested-field-menu",
        HStack(alignment: .top, spacing: 0) {
            ViewEditorForm(store: store, draft: nested, isNew: false).frame(width: 680)
            FieldMenuMock(checked: .ci).padding(.top, 190).padding(.leading, -8)
        },
        size: CGSize(width: 880, height: 1000), dark: true
    )
    try render("view-editor-templates", ViewEditorView(store: store, mode: .create(nil)), size: CGSize(width: 680, height: 520), dark: true)
    try render("view-editor-validation", ViewEditorForm(store: store, draft: invalid, isNew: true, revealIssues: true), size: CGSize(width: 680, height: 820), dark: true)
    try render("view-editor-manage", ViewEditorView(store: store, mode: .manage), size: CGSize(width: 680, height: 460), dark: true)
    try render("view-editor-teams-missing-scope", ViewEditorForm(store: noTeams, draft: review, isNew: true), size: CGSize(width: 680, height: 700), dark: true)
    try render("view-editor-teams-available", ViewEditorForm(store: store, draft: review, isNew: true), size: CGSize(width: 680, height: 700), dark: false)
}

/// What the field pop-up lists, drawn as a static menu because an open NSMenu can't be
/// captured offscreen.
struct FieldMenuMock: View {
    let checked: RuleField

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(RuleField.allCases) { field in
                item(field.title, checked: field == checked, highlighted: field == .mergeState)
            }
            Divider().padding(.vertical, 4)
            item("Any of the following…", checked: false, highlighted: false)
            item("All of the following…", checked: false, highlighted: false)
        }
        .padding(5)
        .frame(width: 200)
        .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
        .shadow(radius: 8, y: 3)
        .overlay(alignment: .bottom) {
            Text("Field menu (static mock)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .offset(y: 18)
        }
    }

    private func item(_ title: String, checked: Bool, highlighted: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark").opacity(checked ? 1 : 0).font(.caption.weight(.semibold))
            Text(title)
            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .foregroundStyle(highlighted ? Color.white : Color.primary)
        .background(RoundedRectangle(cornerRadius: 4).fill(highlighted ? Color.accentColor : Color.clear))
    }
}
