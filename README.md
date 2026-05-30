# RizlDizlScaryBitz

The open, auditable guts of [RizlDizl](https://rizldizl.app) — a macOS keyboard
lighting app. This package is **everything that touches your machine**: global key
capture, the macOS permission handling, USB hotplug detection, and the device I/O
that drives your keyboard's LEDs.

It lives in the open on purpose.

## "Wait, this reads my keystrokes?"

Yes — and that's exactly why this part is open source. RizlDizl reacts to your
typing (a ripple under each key, letters lighting up, etc.), so it has to *see*
keystrokes. That makes it look, from the outside, exactly like the thing you
should be afraid of: a keylogger.

So here's the deal, in plain terms, and you can verify every word below in the code:

- Keystrokes are read **only** to map a key to a position on your keyboard
  (and, for the letter effects, which A–Z letter it was).
- They are **never written to disk, never buffered, and never sent anywhere.**
  There is no network code in this package at all.
- The entire capture surface is one file: [`KeyboardMonitor.swift`](Sources/RizlDizlScaryBitz/KeyboardMonitor.swift).
  Read it. It hands `(row, column, optional letter)` to a callback and forgets it.

If that's not good enough, don't install the app. That's the right instinct, and
no hard feelings.

## What's in here

| Piece | What it does |
|-------|--------------|
| `KeyboardMonitor` | Global key capture (CGEvent tap + NSEvent monitor), permission checks. Emits `(row, col, glyph)`. |
| `USBWatcher` | Notices Razer keyboards plugging/unplugging. |
| `RazerDevice` | Sends RGB frames to the keyboard over USB. |
| `CRazerBridge` | The C transport underneath `RazerDevice`. |

The **effects** (the actual lighting animations) are *not* here — those live in the
closed app. This package is the plumbing; the effects are the product.

## Usage

```swift
import RizlDizlScaryBitz

let monitor = KeyboardMonitor()
monitor.onKeyPress = { row, col, glyph in
    // do something pretty
}
monitor.start()
```

## License

**MIT** — see [LICENSE](LICENSE). The USB transport is an original implementation
of the Razer lighting protocol written against Apple's IOKit; it contains no
third-party driver code. Use it for whatever you like.

— a solo dev who made this for himself and is sharing it.
