# Changelog

Every push to `main` is a release. Before pushing, add a `## [X.Y.Z] - YYYY-MM-DD`
section at the top with `- ` entries (minor for features, patch for fixes); if an
`## [Unreleased]` section is waiting, turn it into that section. GitHub tags it
and publishes the section as the release notes. Versions follow
[Semantic Versioning](https://semver.org/). The full rule:
[StatusItemKit — Releases](https://github.com/nicholaspsmith/StatusItemKit#releases-every-push-is-one).

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
