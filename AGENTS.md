# Working on Perch

Perch is a macOS menu bar app that keeps a live copy of another app's
window floating above everything else. It is built with SwiftPM, and the
README covers what it does for users.

Perch is its own app, published by Sugarhouse Tech (`tech.sugarhouse.Perch`).
It began as a fork of WindowPin by Jorvik Software, released into the public
domain, and has gone its own way since; nothing here goes back upstream. The
README's Credits and the About window thank the original; keep that.

Users perch and unperch windows. Say perch, perched and unperch in anything
a user reads (menus, Settings, the setup window, the README). The code keeps
"pin" for the mechanism (`PinPolicy`, `PinnedWindowTracker`), which is fine.

## Build and test

- `make test` runs the unit tests, in well under a second.
- `make app` builds an ad hoc signed app in `.build/local`, `make run` opens
  it, and `make install` puts it in `/Applications`.
- Try real behaviour in the installed app, which is the one holding the
  Accessibility and Screen Recording grants. An ad hoc rebuild loses them;
  a Developer ID set in `local.mk` keeps them (see the README).
- The debug log is turned on with
  `defaults write tech.sugarhouse.Perch debugLogging -bool true` and written to
  `~/Library/Logs/Perch/perch.log`.
- `defaults write tech.sugarhouse.Perch windowSurvey -bool true` records each newly
  focused window's kind (role, size, level; no titles) to
  `~/Library/Logs/Perch/window-survey.tsv`, for deciding which windows
  should never get a pin button.

## Where logic lives, and how it is tested

The app spends its time between AppKit, the Accessibility API and
ScreenCaptureKit, none of which can run in a unit test. So every decision worth
testing is a pure function or a small value type, outside the classes that
talk to the system. The classes gather inputs, call the function and apply the
answer.

| Decides | Applies it |
|---|---|
| `OverlayGeometry`: what a pin shows, where its panel goes, crops | `WindowOverlay` |
| `StreamLifecycle`: when a pin's stream runs, retries | `WindowOverlay` |
| `PinPolicy`: unpinning closed windows, layering on app switch | `PinnedWindowTracker` |
| `BadgeSchedule`, `BadgeOffsets`, `TitleBarSlotFinder.merge`: pin button timing and placement | `PinBadges`, `TitleBarSlot` |
| `EventMapping`, `ScrollMath`: events and scrolling sent to a pinned window | `EventForwarder`, `AXScroller` |

`Sources/JorvikKit` is shared code from the original app (permissions, launch
at login, the menu bar icon).

- Write new tests with Swift Testing (`import Testing`, `@Suite`, `@Test`).
  They run in parallel by default, so no test may share mutable state. Use
  `arguments:` for tables of cases, and seeded random inputs
  (`SeededGenerator`) for model tests of anything that runs on its own.
- A test never touches real windows, Accessibility, screen capture,
  `UserDefaults.standard` (use a named suite and remove it), or the clock.
  Time is a parameter: pass `now` in.
- UI and system integration get a handful of manual checks, not the bulk of
  the suite.

## Threads

The package builds in Swift 6 language mode, with the features Swift 7 turns
on (see `Package.swift`), so the compiler checks which thread owns what.

- The app target runs on the main actor by default. The pure logic above is
  marked `nonisolated`, which is what lets tests and other queues call it.
  A new decision type gets `nonisolated` too.
- Only three things run off the main thread: the hotkey tap (`HotkeyTap`,
  state behind a lock), `AXScroller` (its own serial queue, because
  Accessibility calls block), and ScreenCaptureKit's frame callbacks in
  `WindowOverlay`. None of them touches main thread state directly.
- Observe notifications and run timers with `observeOnMain` and `Timer.onMain`
  (`Sources/MainThread.swift`), not the closure APIs.
- A main actor class's deinit can run on any thread, so cleanup goes in an
  explicit teardown (`WindowOverlay.hideOverlay()`), not in deinit.
- `nonisolated(unsafe)` and `@unchecked Sendable` each need a comment saying
  what makes them safe.

## Quiet by default

Perch runs all day. Nothing may poll while nothing is happening, and every
retry, recheck or restart needs a limit. When adding one, add a test that
bounds how often it can fire.

## Style

- Comments say why, in plain sentences, for a reader without this context.
- Commit messages describe the change for someone reading the history.
