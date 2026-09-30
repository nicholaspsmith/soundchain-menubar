# Changelog

Every push to `main` is a release. Before pushing, add a `## [X.Y.Z] - YYYY-MM-DD`
section at the top with `- ` entries (minor for features, patch for fixes); if an
`## [Unreleased]` section is waiting, turn it into that section. GitHub tags it
and publishes the section as the release notes. Versions follow
[Semantic Versioning](https://semver.org/). The full rule:
[StatusItemKit — Releases](https://github.com/nicholaspsmith/StatusItemKit#releases-every-push-is-one).

## [Unreleased]

### Added

- UAD-2 plugins pause themselves when no UAD DSP (Apollo, Satellite or UAD-2 card) is attached, or the moment it is unplugged: they leave the chain before they can fail on the missing DSP, their editors close, and their saved settings are kept. They load again when the device returns. Meanwhile the caterpillar turns red, the menu says "⚠ No UAD hardware: N paused", and each such row in Audio Chain says why. Native UADx plugins are not affected

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
