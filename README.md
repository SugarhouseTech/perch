# Perch

Keep any Mac window in view. Perch floats a live copy of a window above
everything else, like picture-in-picture for any app: a chart, a chat or a
build log stays on screen while you work somewhere else.

![A Preview window perched over a TextEdit document](docs/images/pinned.png)

## Install

Perch needs macOS 14 or later.

**Download** it from [sugarhouse.tech/products/perch](https://sugarhouse.tech/products/perch/).
It's free for 14 days, then $6 once. The download is signed, notarised and
keeps itself up to date.

**Or build it** yourself, free, with the Xcode 26 command line tools
(Swift 6.2):

```sh
git clone https://github.com/SugarhouseTech/perch.git
cd perch
make install
```

Open Perch from `/Applications`. A setup window asks for Accessibility and
Screen Recording.

## Use

- **Perch a window**: press `control` `command` `P`, click the robin in its
  title bar, or pick it from the menu bar icon. Do the same to unperch.
- **Keep part of it**: `option`-drag across a perched window. `option`-click
  to show the whole window again.
- **Go to the real window**: click the perched copy.

When you switch to a perched window's app, the copy steps aside, then comes
back when you leave.

The [guide](docs/guide.md) covers the rest: clicking and scrolling perched
windows, cropping, every setting, troubleshooting, and building from source.

## Privacy

Perch records only the windows you perch, and only while they are on screen.
It saves nothing and sends nothing. The download checks sugarhouse.tech once
a day for updates, and contacts Lemon Squeezy once when you enter a key. A copy
built from source never connects to the internet.

## Credits

Perch began as [WindowPin](https://github.com/PerpetualBeta/WindowPin) by
Jonathan Hollin of [Jorvik Software](https://jorviksoftware.cc/), who
generously released it into the public domain. Jonathan built the heart of
Perch: live window copies, cropping, and scrolling them on macOS 27. Perch
keeps WindowPin's full history. Thank you, Jonathan.

## License

Public domain under [the Unlicense](LICENSE), like the original.
