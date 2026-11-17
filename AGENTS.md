# Working on WindowPin

WindowPin is a macOS menu-bar app that keeps a live copy of another app's
window floating above everything else. It is built with SwiftPM.

## Build and test

- `make test` runs the unit tests. They take well under a second.
- `make app` builds an ad-hoc signed app in `.build/local`; `make install` puts
  it in `/Applications`, and `make run` starts the local build.
- Accessibility and Screen Recording are granted to the installed app, so try
  real behaviour there. The debug log is turned on with
  `defaults write <bundle id> debugLogging -bool true` and written to
  `~/Library/Logs/WindowPin/windowpin.log`.

## Where logic lives, and how it is tested

The app spends its time between AppKit, the Accessibility API and
ScreenCaptureKit, none of which can run in a unit test. So every decision worth
testing is a pure function or a small value type, outside the classes that
talk to the system: geometry, policies, schedules, state machines. The classes
gather inputs, call the function and apply the answer.

- Write new tests with Swift Testing (`import Testing`, `@Suite`, `@Test`).
  They run in parallel by default, so no test may share mutable state. Use
  `arguments:` for tables of cases, and seeded random inputs for model tests
  of anything that runs on its own.
- A test never touches real windows, Accessibility, screen capture,
  `UserDefaults.standard` (use a named suite and remove it), or the clock.
  Time is a parameter: pass `now` in.
- Coverage for UI and system integration is a handful of manual checks, not
  the bulk of the suite.

## Quiet by default

WindowPin runs all day. Nothing may poll while nothing is happening, and every
retry, recheck or restart needs a limit. When adding one, add a test that
bounds how often it can fire.

## Style

- Comments say why, in plain sentences, for a reader without this context.
- Commit messages describe the change for someone reading the history.
