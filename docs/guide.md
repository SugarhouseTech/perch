# Perch guide

The [README](../README.md) covers installing Perch and the basics. This is
everything else.

## Perching and unperching

Each of these perches the window you're using, and unperches it if it is
already perched:

- Press `control` `command` `P`. Change or clear the shortcut in Settings.
- Click the robin at the right of the window's title bar. A perched window
  shows a perched robin in an orange ring; click it to unperch.
- Click the menu bar icon and choose the window at the top.

The menu lists every perched window. Choose one to unperch it, or choose
**Unperch All**. Perch unperches closed windows by itself.

## Cropping

Keep just part of a window in view, such as a score on a web page or the
last lines of a log.

| To | Do |
|---|---|
| Crop | `option`-drag across the perched window |
| Crop again | `option`-drag inside the crop |
| Show the whole window | `option`-click it |
| Move it | Drag it |
| Show more or less around it | Drag an edge or corner |

A crop is a fixed area of the window. If the content scrolls, reflows or the
window is resized, what you wanted can move out of it. Switching tabs changes
what it shows, so to watch one tab, drag it into its own window first. A
minimised window stops updating.

## Clicking and scrolling a perched window

Typing always goes to the app you're using; to type into a perched window,
click it to switch to it.

### macOS 27 and later

| Action | Result |
|---|---|
| Click | Takes you to the real window |
| Scroll | Scrolls the real window, if **Scroll a perched window without switching to it** is on |
| `option`-drag | Crops |

Scrolling needs the app to support macOS accessibility. Most Mac apps do.
Electron and Chromium apps often don't, and won't scroll.

### macOS 14 to 26

With **Click and scroll a perched window without switching to it** on (the
default), clicks, drags and scrolling go straight to the real window, so
buttons, links and text selection work in place. `command`-click takes you
to the real window. With it off, any click takes you there.

## Settings

Open **Settings…** from the menu bar icon, or open Perch again while it is
running.

- **Perching**: the shortcut; the perch and unperch buttons; and whether an
  unperched window is brought to the front (**Leave it there**) or left
  where it was (**Hide it**).
- **Perched Windows**: clicking and scrolling without switching, and
  whether perched windows show on every desktop.
- **General**: open at login, and a background behind the menu bar icon for
  busy wallpapers.
- **Menu Bar** (macOS 14 and 15): hide the menu bar icon. On macOS 26 and
  later, use System Settings → Menu Bar. Open Perch again to reach Settings
  with the icon hidden.
- **Permissions**: what's granted, with a button for what isn't.
- **Apps**: change how Perch treats an app.
  - **Ignore this app**: no buttons, and its windows can't be perched.
  - **Button position**: for apps whose title bars Perch can't read, set
    where the button goes. Discord and Obsidian are set up already.
  - **Show the button only when window is perched**.

A perched window redraws only when it changes, up to 30 times a second. To
lower that, for example to save battery while perching a video:

```sh
defaults write tech.sugarhouse.Perch captureRate -float 10
```

## Permissions

Both are in System Settings → Privacy & Security. The setup window asks for
them on first run, and the menu bar icon shows a red dot while one is
missing.

- **Accessibility**: the shortcut, the title bar buttons, scrolling, and
  bringing windows forward.
- **Screen Recording**: showing what's in a perched window. macOS sometimes
  needs Perch restarted before this takes effect; the setup window has a
  button for it.

## Troubleshooting

**The shortcut or buttons stopped working after a rebuild.** macOS ties the
Accessibility grant to one exact build. Remove Perch from the Accessibility
list and add it again, or sign your builds (see below).

**A perched window is blank.** Grant Screen Recording, then restart Perch.

**The menu bar icon is missing.** Run Perch from `/Applications`; menu bar
managers such as Bartender only see apps there. Or open Perch again to reach
Settings.

**A perched window is stuck on screen.** Choose **Unperch All**, or quit
Perch.

## Building

```sh
make test      # unit tests
make app       # .build/local/Perch.app, signed ad hoc
make run       # build and open it
make install   # copy it to /Applications (INSTALL_DIR to change)
```

A copy built from source has no updater and no trial: pull and run
`make install` again.

So permissions survive rebuilds, sign with your own Developer ID in a
`local.mk` beside the Makefile (git ignores it):

```make
LOCAL_SIGN_ID   := Developer ID Application: Your Name (TEAMID)
LOCAL_BUNDLE_ID := com.example.Perch
```

The download is the same code built with `PERCH_DIRECT=1`, which adds
Sparkle for updates and the trial and licence.

To work on the code, start with [AGENTS.md](../AGENTS.md).
