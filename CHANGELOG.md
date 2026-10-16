# Changelog

Every push to `main` is a release. Before pushing, add a `## [X.Y.Z] - YYYY-MM-DD`
section at the top with `- ` entries (minor for features, patch for fixes); if an
`## [Unreleased]` section is waiting, turn it into that section. GitHub tags it
and publishes the section as the release notes. Versions follow
[Semantic Versioning](https://semver.org/). The full rule:
[StatusItemKit — Releases](https://github.com/nicholaspsmith/StatusItemKit#releases-every-push-is-one).

## [1.17.0] - 2026-10-15

- The owl icon in the menu bar now supports custom pupil colors, allowing you to choose a color instead of the default green-to-red gradient.

## [1.16.0] - 2026-10-15

- **Bypass takes SoundChain out of the audio path.** It used to switch the effects off while every app's audio still went through SoundChain untouched; now the effects fade out and SoundChain removes its tap and aggregate device, so apps play straight to the output. Unticking Bypass builds them again and fades the effects back in. A quick on-off-on settles for 0.3 s before anything is built or removed, and launching bypassed (including after two crashes in a row) never builds a tap at all. The menu says "Audio goes straight to the output"
- While bypassed, Carol sleeps instead of walking: grey with her eye shut, breathing, her head nodding, Zs rising over her back, in Polly's dozing manner (StatusItemKit 0.32.0). She sleeps still under Reduce Motion, and the animation pauses while the displays sleep

## [1.15.2] - 2026-10-15

- Only one SoundChain taps the system's audio. A second copy (opened twice, or parity's launch check of a new build) stands by with a grey Carol and a menu saying another SoundChain is running, and takes over only if it is still open 10 seconds after the first one quits. Two copies tapping the same output, started and stopped within seconds, preceded macOS's audio service hanging on 2026-10-15
- SoundChain quits properly when it is sent SIGTERM or SIGINT (parity's launch check, `kill`), removing its own tap and aggregate device instead of leaving them for macOS to clean up; quitting now removes the tap first, before saving plugin settings
- When macOS's audio service (coreaudiod) stops answering, the menu says "macOS audio isn't responding" and offers **Copy Restart Command** (`sudo killall coreaudiod`), instead of a Retry that froze the menu for 30 seconds. SoundChain checks before each start, off the main thread, and reconnects by itself once the service is back

## [1.15.1] - 2026-10-15

- Fixed a visual glitch where the Carol menu bar icon was clipped at the top.

## [1.15.0] - 2026-10-15

- Carol walks to the music: the louder SoundChain's output (after the effects), the higher and faster she steps, from a shuffle in quiet passages to a full stride in a loud chorus. She settles and stands in silence, including between tracks, and starts within about a tenth of a second of sound (StatusItemKit 0.31.0)
- She keeps time with what you hear: her motion is delayed by the output's latency, which matters over Bluetooth headphones
- `--taptest` reports the loudest output, the output latency and how hard Carol would have walked, instead of the cycles with sound

## [1.14.0] - 2026-10-15

- Carol walks while sound is passing through SoundChain, bypassed or not: a hump rolls from her tail to her head, each segment stepping its feet forward as it lifts. She starts within a second of the sound and stops about a second and a half after it, so a gap between tracks does not stop her. Her once-a-minute run is skipped while she walks, and both are skipped under Reduce Motion (StatusItemKit 0.30.0)
- `--taptest` also reports how many cycles carried sound

## [1.13.0] - 2026-10-09

- **Keep Headphones to This Mac** moves out of Settings ▸ into the main menu, under the output rows
- Carol shows it: with it off, she wears her headphones round her neck (StatusItemKit 0.29.0)

## [1.12.0] - 2026-10-09

- Switching an effect on or off no longer clicks: the effect's signal is crossfaded in or out over 40 ms instead of cut in. The same goes for Bypass, for adding or removing an effect, and for the first moment after SoundChain starts
- Fix: Settings ▸ Keep Headphones to This Mac could report that the headphones wouldn't drop the phone when they were still about to; it now waits for their answer

## [1.11.0] - 2026-10-08

- Settings ▸ **Keep Headphones to This Mac** (Bose headphones, off by default): while they are the output, any other device connected to them, usually your phone, is disconnected from them, now and every 30 seconds. Bose headphones share their radio between two sources (multipoint), and a phone that is merely connected, playing nothing, turns the Mac's audio into continuous crackle. The menu says who was dropped, e.g. "Dropped Magooberstein from Osiris"
- Works with any Bose headset that takes commands from the Bose app (QuietComfort 35 II and later); other headphones are left alone and the menu says so. If the headphones' controls stop answering, the menu says to turn them off and on

## [1.10.0] - 2026-10-08

- No user-visible changes.

## [1.9.0] - 2026-10-07

- No user-visible changes.

## [1.8.0] - 2026-10-06

- Give effects names of your own: in Audio Chain…, click the name column next to an effect (it says "Add a name" until you do), type a name such as "Pitch Down", and press Return. Escape cancels, and an empty name goes back to the plugin's own
- **Rename** button in Audio Chain… (also Return or ⌘R on the selected effect)
- The menu lists each effect by its custom name when it has one (hover for the plugin and maker), and editor windows and error lines use it too, e.g. "Pitch Down — AUPitch"
- Duplicate and ⌘C/⌘V keep the custom name on the copy

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
