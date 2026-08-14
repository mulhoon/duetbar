# Duetbar

Menu bar control for the Apogee Duet 2 on macOS.

Apogee Control 2 still runs but isn't updated any more. Duetbar does the parts
you touch every day, from the menu bar, and keeps your output level visible.
That last bit matters if your Duet's screen has died, which is why I wrote it.

## What it does

- **Speakers and headphones**: level, mute, dim, sum to mono
- **Both inputs**: mic / +4 dBu / -10 dBV / instrument, gain, 48V, soft limit, phase invert
- **Sample rate** up to 192 kHz
- **Live meters** on both outputs and both inputs
- **Live readout** in the menu bar

Runs alongside Control 2 quite happily. Change something in one and the other
catches up.

## Shortcuts

| Action | Key |
| --- | --- |
| Mute | ⌃⌥⌘M |
| Dim | ⌃⌥⌘D |
| Volume up | ⌃⌥⌘↑ |
| Volume down | ⌃⌥⌘↓ |

These act on the speakers and work from any app. They don't need Accessibility
permission, and they're listed in the app so you don't have to remember them. If
another app has already claimed one, that row says so and the rest still work.

To change them, edit `HotKeySpec` in `Sources/HotKeys.swift`.

## Build

```sh
./build.sh
open Duetbar.app
```

Needs the Xcode command line tools, and macOS 13 or later. On macOS 26 it picks
up the Liquid Glass styling.

Apogee's software has to be installed, because Duetbar talks to the ApogeeGlue
background service that comes with it. You don't need to run Control 2 itself.

## How it works

macOS handles the Duet's audio with its own class compliant driver. Hardware
control is a separate thing that goes through `ApogeeGlue`, a background service
Apogee installs. Control 2 is a client of that service, and so is this. Nothing
is patched or replaced.

One warning if you're tempted to skip all that: the Duet advertises standard USB
Audio Class volume and gain controls with ranges that look exactly right. You can
set them and read the changed values back. The firmware ignores them completely.
There's a measurement in [docs/PROTOCOL.md](docs/PROTOCOL.md).

## Protocol

[docs/PROTOCOL.md](docs/PROTOCOL.md) has the wire format and the property IDs,
worked out by watching Control 2 talk to the service. Take it if you want to
build something else, or add another Apogee interface.

## Status

Works on my Duet 2 on Apple Silicon. Property IDs are model specific, so other
Apogee interfaces need their own set, though the protocol itself looks device
independent.

No signed build yet, so for now you build it yourself.

## Unofficial

Not affiliated with Apogee Electronics. Apogee and Duet are their trademarks.

## Licence

MIT
