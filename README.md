# SoundChain

<p align="center"><img src="docs/mascot.png" width="160" alt="SoundChain mascot, from the Menubarn widget library"></p>

<p align="center">Part of the <a href="https://widgets.nicksmith.software">Menubarn</a> widget library.</p>

A standalone macOS menu-bar app that runs **one chain of Audio Unit effects over
all of your Mac's audio**: EQ, room correction, limiting, anything installed as an
AU effect. Pick effects, open their own editors, and the processed sound plays
through whatever output is current.

Built on [StatusItemKit](https://github.com/nicholaspsmith/StatusItemKit). Part of
the [Menubarn](https://widgets.nicksmith.software) widget library.

**Version 1.0.2** · [Changelog](https://github.com/nicholaspsmith/soundchain-menubar/releases)

<p align="center"><img src="docs/menubar-icon-large.png" width="360" alt="SoundChain's menu-bar caterpillar, large"></p>

## Requirements

- macOS 14.2 or later (Core Audio process taps).
- Audio Unit effects (AUv2 or AUv3). VST3 is not supported.

## Install

    ./install.sh

Builds `build/SoundChain.app` (via StatusItemKit's `make-app.sh`) and symlinks it
into `~/Applications`. On first launch, allow **System Audio Recording** when asked.
Start at Login is in the menu, or run `SoundChain --login on`.

## Use

- **Audio Chain…** (⌃C) opens the chain. **Add…** searches installed effects;
  Pro-Q, Pro-L 2 and Nectar 3 are pinned at the top. Drag rows to reorder, untick
  one to bypass it, **Open** shows its own editor, **–** removes it (and selects the
  next row, so you can keep pressing).
- **Bypass** turns all processing off; audio passes through untouched.
- Settings save to `~/Library/Application Support/SoundChain/chain.json`, including
  each plugin's own state (captured when its editor closes, every 5 s while one is
  open, and at quit).

### The caterpillar

The menu-bar icon is a caterpillar in headphones. Each running effect puts a
highlight on one of its five segments, counting back from the head. Green means
processing, grey means bypassed, red means something needs attention (the menu
says what).

SoundChain follows whatever output macOS picks, including a virtual one such as
BlackHole, Zoom's, or a driver an uninstalled app left behind. Those have no
speakers, so when the current output is virtual the caterpillar turns red and the
menu says **⚠ Virtual output: may be silent** under the device name. macOS can
pick one on its own when headphones disconnect; choose a real output in Control
Center, or remove the stale driver from `/Library/Audio/Plug-Ins/HAL`.

## Pinned effects

Click the pin beside any effect in **Add…** (or right-click ▸ Pin) to keep it in the
**Pinned** group at the top; click again to unpin. Pro-Q, Pro-L 2 and Nectar 3 start
pinned. Pins match name prefixes, so "Pro-Q" also covers a later Pro-Q 4.

## How it works

A global Core Audio process tap captures every app's output except SoundChain's
own and mutes the originals. The tap and the current default output device are
joined in a private aggregate device; its IO callback runs the effects in order
and writes to the output. Chain edits build a new immutable render snapshot on
the main thread and swap it in atomically, so the audio thread never waits. The
aggregate uses tap auto-start, so while nothing is playing there is no audio work
at all.

## When things go wrong

- **SoundChain crashes:** the private tap and aggregate vanish with it, so macOS
  plays your audio unprocessed.
- **A plugin crashes it:** loading a plugin, restoring its saved settings and
  building its editor are each bracketed by an on-disk marker, and nothing new goes
  live while a plugin is loading. After a crash, a plugin caught mid-load or
  mid-editor is disabled: never loaded again, and listed last in **Add…**, greyed
  out (right-click ▸ **Re-enable** to give it another chance). One caught
  mid-restore keeps running with its saved settings reset. The menu says which.
- **Unexplained crashes:** two in a row start the next launch bypassed.
- **A plugin fails to open** (missing, unlicensed) or reports a render error: it
  stays in the chain in red and is skipped, with its settings kept. **Retry** in the
  menu, or unticking and re-ticking a slot, tries it again.

## Troubleshooting

- `SoundChain --selftest` renders a sine through Apple's AUs offline and checks the
  chain, the runner and disabled-plugin handling.
- `SoundChain --taptest 20` runs the real tap with no effects for 20 seconds. Run
  it from the bundle so macOS attributes the permission to SoundChain:
  `open -W --stdout /tmp/tap.log build/SoundChain.app --args --taptest 20`.
  The callback count stays 0 until some app plays audio (tap auto-start).
- Diagnose with `log show --predicate 'process == "SoundChain"' --last 10m`.

## Known limits

- Older (AUv2) plugins run inside SoundChain's process, so a plugin that crashes
  takes SoundChain with it (audio falls back to unprocessed).
- On an output device that also has inputs (a Scarlett, say) macOS logs one
  Microphone permission request at start. It is refused silently and audio works.

## Why not a SwiftBar plugin?

A shell plugin cannot host Audio Units, run a real-time audio callback, or show a
plugin's editor window. This needs a native process.
