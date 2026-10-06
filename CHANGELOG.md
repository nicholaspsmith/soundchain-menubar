# Changelog

Every push to `main` is a release. Before pushing, add a `## [X.Y.Z] - YYYY-MM-DD`
section at the top with `- ` entries (minor for features, patch for fixes); if an
`## [Unreleased]` section is waiting, turn it into that section. GitHub tags it
and publishes the section as the release notes. Versions follow
[Semantic Versioning](https://semver.org/). The full rule:
[StatusItemKit — Releases](https://github.com/nicholaspsmith/StatusItemKit#releases-every-push-is-one).

## [1.7.0] - 2026-10-06

- Audio Chain… has a **Duplicate** button (⌘D): it adds a copy of the selected effect, with all its current settings, to the end of the chain
- ⌘C copies the selected effect and its settings; ⌘V pastes it directly below the selected row (or at the end) and selects it. Each paste is its own independent copy, and a copied effect can still be pasted after closing the window
- Fix: granting System Audio Recording in System Settings now starts audio within a second, without pressing Retry
- Fix: when starting audio fails and SoundChain can't tell whether it has permission, the menu now offers Grant System Audio Recording…
- Fix: a chain file that exists but can't be read is no longer treated as missing and overwritten by the next save
- Fix: removing an effect while its editor is still opening no longer leaves a stray editor window behind
- Fix: audio restarts on its own if the output's buffer size changes, instead of possibly going silent
- Fix: hardening against a misbehaving plugin asking for more audio than it should, and against needless audio restarts after some device notifications

## [1.6.1] - 2026-10-06

- Ticking a checkbox in the menu no longer closes it: switch effects, Bypass or Start at Login on and off with the menu still open, and the "effects running" line updates as you go

## [1.6.0] - 2026-10-06

- feat: the menu lists every effect in the chain, ticked when it's on; click one to switch it on or off

## [1.5.1] - 2026-10-05

- New app icon: Carol as she looks in the menu bar

## [1.5.0] - 2026-10-05

### Changed

- The menu ends with a **Settings** submenu, the same one every Menumon app now has: Start at Login and the version moved there. Audio Chain…, Reconnect and Bypass stay at the top

## [1.4.0] - 2026-10-02

### Added

- When the current output is Bluetooth headphones, the menu offers "Reconnect <name>", for when they go silent while macOS still shows them as the output. It first saves the last 5 minutes of Bluetooth and audio logs (`bluetoothd`, `coreaudiod`, `audioaccessoryd`) to `~/Library/Logs/SoundChain`, then disconnects and reconnects them. The first use asks for Bluetooth access

## [1.3.0] - 2026-10-02

- feat: once a minute Carol runs on the spot for a second (scissoring feet, a bob rippling from tail to head), in turn with the other animated Menumon mascots

## [1.2.0] - 2026-09-30

### Added

- UAD-2 plugins pause themselves when no UAD DSP (Apollo, Satellite or UAD-2 card) is attached, or the moment it is unplugged: they leave the chain before they can fail on the missing DSP, their editors close, and their saved settings are kept. They load again when the device returns. Meanwhile the caterpillar turns red, the menu says "⚠ No UAD hardware: N paused", and each such row in Audio Chain says why. Native UADx plugins are not affected

### Fixed

- Audio came out quieter with SoundChain running, even bypassed, on an output whose stereo pair is not channels 1 and 2 (an Apollo plays stereo on 5 and 6). The stereo-mixdown tap read that pair about 14 dB low, and the result went to channels 1 and 2. SoundChain now taps the output stream channel for channel, processes the device's preferred stereo pair (Audio MIDI Setup ▸ Configure Speakers) and writes it back there, passing every other channel through untouched. Bypass is unity gain again. Audio an app sends to some other device is no longer pulled into the chain

### Changed

- Removing, bypassing or failing a slot now takes it out of the running chain at once, even while another plugin is still loading (newly loaded plugins still wait for the queue to drain)

## [1.1.1] - 2026-09-28

### Changed

- `install.sh` now asks whether to turn on Start at Login (skipped when it is already on, or when there is no terminal to ask in), then launches SoundChain, quitting any running copy first so the new build takes over

## [1.1.0] - 2026-09-27

### Added

- A warning when the output SoundChain is following is a virtual device (BlackHole, Zoom's, a leftover driver), which usually means you hear nothing: the caterpillar turns red and the menu says "⚠ Virtual output: may be silent" under the device name

## [1.0.2] - 2026-09-27

### Changed

- The menu-bar caterpillar now comes from StatusItemKit's shared character set, alongside the other Menubarn mascots. It looks the same.

## [1.0.1] - 2026-09-26

### Fixed

- ⌘A, ⌘C, ⌘V, ⌘X and ⌘Z now work in the Add picker's search field
- Audio Chain… moved to ⌃C, so it no longer competes with Select All

## [1.0.0] - 2026-09-26

### First release

- One chain of Audio Unit effects over all of your Mac's audio, following whatever output is current
- Audio Chain window: a searchable Add picker where you pin favourites to the top, drag to reorder, untick to bypass one effect, and plugin icons
- Each plugin's own editor in a floating panel; its settings are saved automatically
- Plugins that crash SoundChain are disabled and listed last, and can be re-enabled; a crash while restoring settings just resets them
- Bypass, Retry and Start at Login in the menu, with the output device, running effects and format at the top
- A menu-bar caterpillar in headphones: one highlighted segment per running effect, green, grey when bypassed, red when something needs attention
