# Agent guidance

Rules for coding agents working in this repository. `README.md` covers what the app does and how it's built.

## How to work

Work in your own git worktree under `./.wt/`, numbered like `./.wt/wt-01/`, on a branch for the task:

```sh
git worktree add .wt/wt-01 -b my-task
```

`/.wt/` is in `.gitignore`. Commit as you go. Push your branch to `origin` (`lubelski/github-pr-watch-menubar`) and open a PR. The lead session reviews and merges.

## Who owns which file

Feature work happens in parallel, so each UI feature has its own file in `Sources/GitHubPRWatchUI`:

| File | Feature |
|---|---|
| `LanesWindowView.swift`, `LaneColumnView.swift` | The main window's lanes |
| `MenuBarPopoverView.swift` | The menu bar popover |
| `ViewEditorView.swift` | The filter builder for views |
| `SettingsView.swift` | Settings |
| `OnboardingView.swift` | One-screen setup |
| `UserNotifier.swift` | Banners |

Shared pieces live in their own files: `PRRowView.swift`, `StatusStyle.swift`, `ConnectionStatusView.swift`, `MenuBarLabel.swift`, `Avatar.swift`, `MainWindowView.swift`, `AppServices.swift`. Don't put shared code in a feature file. Logic and wording belong in Core, where they can be tested.

## Rules

- **Lanes are GitHub's facts.** A PR's lane comes from what GitHub reports and is the same for every viewer. Don't add lanes or wording that guess who should act; ownership belongs in views. The decision table is in `PRStatus.swift`, with one test per row.

- **Read-only.** Never add code that writes to GitHub: no merging, re-running, approving, commenting.
- **Placeholder data only.** Fixtures, tests, sample data and screenshots use placeholder people and repos, such as Riley Chen (`rchen`), `jlin-agent`, `apark`, `acme/web`, `acme/api`. Never real names, emails, companies, or tokens. Fixtures copied from live responses must be scrubbed first.
- **Never print, log, or commit a token.**
- **Ask before launching the app.** Will works on the same Mac. Anything that opens a window, takes focus, or shows a notification-permission or Keychain prompt needs his OK first, with a time estimate. Use a windowless render instead.
- **Run only the bundle**, never `swift run`. `swift build` stamps the binary with the wrong SDK version. See `scripts/bundle.sh`.

## Checks

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
./scripts/bundle.sh
./scripts/render.sh
```

## Icons

The app icon, the menu bar icon, and the onboarding header all draw the one pull request mark in `Sources/GitHubPRWatchCore/PullRequestMark.swift`. Change it there, not in a view.

- App icon
  - `Resources/AppIcon.icon` is generated. Change `AppIconDrawing.swift`, then run `./scripts/render-icon.sh` and commit `Resources/AppIcon.icon` and `docs/icon*.png`.
  - `scripts/render-icon.sh <1-3>` draws one of the other candidate designs.
  - `scripts/bundle.sh` compiles it with `actool`, which needs full Xcode. Check the bundle has `Contents/Resources/Assets.car` and `AppIcon.icns`.
- Menu bar icon
  - Drawn by `Sources/GitHubPRWatchUI/MenuBarIcon.swift` as one template image. Keep it to AppKit and `PullRequestMark`, so the render script can compile it alone.
  - Run `./scripts/render-menubar-icon.sh`. It draws every state on light and dark menu bars into `docs/menubar-icon.png` and `docs/menubar-icon-1x.png`. Commit both, and look at the 1× pixels.
  - The badge sits beside the mark, never over it: the mark's top right is the right track's bend.
- A PR that changes either icon shows the renders, attached with `--attach` (see Pull requests).

## Pull requests

A PR that changes anything visible includes rendered images in its body. Put them on the PR with `gh`'s `--attach <file>` flag, which works on `gh pr create`, `gh pr edit` and `gh pr comment`. Alt text follows the path after `#`, as in `--attach './docs/icon.png#The app icon'`. Repeat the flag for several files.

## Making screenshots without taking focus

`./scripts/render.sh [folder]` builds the `GitHubPRWatchRender` tool, stamps it with the real SDK version, and runs it. It writes PNGs of onboarding (signed out and signed in), the lanes, the popover, Settings, and the menu bar glyph, in light and dark, to `build/renders/`.

How it works, in `Sources/GitHubPRWatchRender/main.swift`:

1. `NSApp.setActivationPolicy(.prohibited)`, so the process never shows up or takes focus.
2. Each view goes in an `NSHostingView` inside an `NSWindow` that is never ordered front, and is drawn with `cacheDisplay(in:to:)`.
3. The store is built with `PRStoreDependencies.inMemory(api: StaticGitHubAPI())` and a `RecordingNotifier`, so no real account, Keychain item, file, or network is touched.

Pitfalls:

- **Async state:** wait with `await Task.sleep`, not `RunLoop.run`. Top-level code runs on the main actor.
- **Background:** the root view needs `.background(Color(nsColor: .windowBackgroundColor))`, or parts render transparent.
- **Activation policy:** `DockPresence` changes the policy when the main window appears, but leaves `.prohibited` alone. Keep that guard.

- **Whole windows:** the main window and Settings render with `renderWindow(...)` (`Sources/GitHubPRWatchRender/WindowRenders.swift`), which draws the window's frame view, so the centered title, the toolbar items and their grouping show. The Liquid Glass material itself does not: it needs a window on screen. Judge the glass in the running app.

To render a new view, add a `render(...)` call. Look at every PNG before you call the work done.
