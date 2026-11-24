# GitHub PR Watch

A macOS menu bar app, with a full window, for people who shepherd a lot of GitHub pull requests.
Teammates and their coding agents open many PRs, CI takes 15 to 60 minutes, and auto-merge stalls.
GitHub PR Watch tells you the moment a PR needs you.

It is **read-only**. It shows PRs and sends native notifications. It never merges, re-runs, approves, or writes to GitHub. Clicking a PR opens it in the browser.

## How it works

- **Views are saved filters.** A view is a named rule tree: groups that match all, any, or none of their conditions, on author, assignee, review requested, repo, label, draft, CI state, and merge state. A user condition can name "me" or a list of logins. Four starter views: Mine, Needs my review, Agent PRs, Watchlist.
- **Each view has notification rules**: which events notify for PRs in that view.
- **Events are transitions** between two polls: CI finished (green and ready, green but blocked, failed with the failing checks, or green and still waiting), entered or dropped from the merge queue, approved, changes requested, review requested from you, and a new PR in the view. The first poll after sign-in only sets a baseline. The last snapshot is saved, so a relaunch doesn't notify again.
- **The main window shows four lanes**: Your move, CI running, In merge queue, Waiting on others. A view picker chooses which PRs fill them.
- **Each PR shows a symbol and a plain sentence**, never color alone, such as `2 checks failed: e2e-chrome, lint` or `CI passed · blocked by required-commit`. Whether a PR is "your move" depends on who you are: a green, approved PR is its author's (or assignee's) move, and a review request is the reviewer's.
- **The menu bar item** is a calm glyph until something is your move, then gains a filled badge; it dims while offline or signed out. For about 8 seconds after an event it also names it, such as `#1293 ready to merge`. The popover lists Your move first, newest change on top, and keeps Waiting collapsed behind a one-line summary (`2 in CI, 1 in queue`).
- **Banners are calm.** A PR with several events in one poll gets one banner, for the most important. A poll that changes many PRs posts at most three banners, the last summing up the rest (`4 more pull requests changed`). A drop from the merge queue waits one poll and notifies only if the PR is still open and still out of the queue, since GitHub can drop the entry briefly while a merge lands. Settings has the master switch, sound, the menu bar label, and a quiet-while-in-front option.

The app is an accessory (menu bar) app. While the main window is open it becomes a regular app with a Dock icon and a place in Command-Tab, and goes back to the menu bar when the window closes. The window opens at launch only until setup is finished.

## Signing in

Setup is one screen: sign in, pick starter views, optionally turn on notifications, pick repos, and press Start Watching. Notification permission is asked only when you press "Turn On…".

| Method | Where the token lives |
|---|---|
| **Your GitHub CLI login** (offered first when `gh` is installed) | Nowhere in this app. It runs `gh auth token` each time it needs one, so `gh auth refresh` and `gh auth switch` keep working. `gh` is found on `PATH`, then in `/opt/homebrew/bin`, `/usr/local/bin` and `~/.local/bin`. |
| **Sign in with GitHub** (OAuth device flow) | The Keychain, service `dev.lubelski.GitHubPRWatch`. Hidden until an OAuth client ID is set in `OAuthConfig.clientID`. |
| **A pasted token** | The Keychain, same service. |

The device flow is fully implemented but has no client ID yet. A GitHub App with read-only permissions (Pull requests, Checks, Commit statuses, Contents, Metadata) is preferable to an OAuth App, whose only way to read private repos is the `repo` scope, which also grants write access.

## Polling and the API budget

Each poll uses GitHub's GraphQL API in two steps, so big repos stay cheap:

1. A light query lists every open PR in each watched repo (50 per page): title, author, assignees, review requests (users and teams), latest reviews, labels, review decision, mergeability, merge state, auto-merge, merge queue entry with position and queue length, head commit, base branch, and times.
2. A heavier query fetches check detail (every check run and status context, with its status, conclusion, times, link, and whether it is required, plus the last merge-queue removal reason) only for PRs that might match a view, 15 PRs per query.

Polls run every 60 seconds. When less than a fifth of the hourly budget is left, polls spread out so the budget lasts until it resets. A rejected token (401), the primary rate limit, GitHub's secondary rate limit, and being offline are separate states with their own retry rules. A rejected token stops polling until you act.

A check whose name contains `required-commit` is treated as a guard: when it is the only failure, the PR shows as "CI passed · blocked" instead of "CI failed". The list of guard names is in `AppConfig.guardCheckPatterns`.

## Build

Requires Xcode (for SwiftUI macros). `xcode-select` doesn't need to point at it; the scripts set `DEVELOPER_DIR`.

```sh
./scripts/bundle.sh       # builds build/GitHub PR Watch.app
./scripts/render.sh       # draws the UI with placeholder data to build/renders/*.png
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Run the app from the bundle that `bundle.sh` builds, not with `swift run`. `swift build` records the wrong SDK version in the binary, and macOS then runs the app in a compatibility mode. The comments in `scripts/bundle.sh` explain.

Settings, views and the last snapshot live in `~/Library/Application Support/GitHub PR Watch/` as `config.json`, `views.json` and `snapshot.json`.

## Layout

- `Sources/GitHubPRWatchCore`: everything testable, no UI.
  - `Models.swift`: `PullRequest`, `CheckRun`, `Repo`, `Viewer`, and GitHub's enums.
  - `PRStatus.swift`: the classifier. Its doc comment has the decision table.
  - `Filter.swift`: the rule tree, `SavedView`, `EventKind`, and the starter views.
  - `Transitions.swift`: the transition detector and the saved snapshot.
  - `NotificationWording.swift`: banner text for each event.
  - `NotificationPlanner.swift`, `QueueDropDebouncer.swift`, `NotificationSettings.swift`: which banners a poll becomes.
  - `MenuBarSummary.swift`: the menu bar glyph's state and the popover's summaries.
  - `GitHubClient.swift`, `GitHubQueries.swift`: the GraphQL client and its documents.
  - `Auth.swift`, `DeviceFlow.swift`, `Secrets.swift`: the three sign-in paths and the Keychain.
  - `PRStore.swift`: the `@Observable` app model that the UI reads.
  - `SampleData.swift`: placeholder PRs and a static API for renders and tests.
- `Sources/GitHubPRWatchUI`: the SwiftUI views and `UserNotifier`. One file per feature.
- `Sources/GitHubPRWatch`: the `App` and its scenes, nothing else.
- `Sources/GitHubPRWatchRender`: the windowless render tool.
- `Tests/GitHubPRWatchCoreTests`: tests for Core.
