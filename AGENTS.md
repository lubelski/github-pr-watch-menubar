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
| `LanesWindowView.swift` | The main window's lanes |
| `MenuBarPopoverView.swift` | The menu bar popover |
| `ViewEditorView.swift` | The filter builder for views |
| `SettingsView.swift` | Settings |
| `OnboardingView.swift` | One-screen setup |
| `UserNotifier.swift` | Banners |

Shared pieces live in their own files: `PRRowView.swift`, `StatusStyle.swift`, `ConnectionStatusView.swift`, `MenuBarLabel.swift`, `Avatar.swift`, `MainWindowView.swift`, `AppServices.swift`. Don't put shared code in a feature file. Logic and wording belong in Core, where they can be tested.

## Rules

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

To render a new view, add a `render(...)` call. Look at every PNG before you call the work done.
