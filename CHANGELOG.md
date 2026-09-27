# Changelog

Every push to `main` is a release. Before pushing, add a `## [X.Y.Z] - YYYY-MM-DD`
section at the top with `- ` entries (minor for features, patch for fixes); if an
`## [Unreleased]` section is waiting, turn it into that section. GitHub tags it
and publishes the section as the release notes. Versions follow
[Semantic Versioning](https://semver.org/). The full rule:
[StatusItemKit — Releases](https://github.com/nicholaspsmith/StatusItemKit#releases-every-push-is-one).

## [Unreleased]

- One chain of Audio Unit effects over all system audio, following the current output device
- Chain window: searchable Add picker with pinned favourites, drag to reorder, per-effect bypass, plugin icons
- Each plugin's own editor in a floating panel; settings saved automatically
- Plugins that crash SoundChain are disabled and listed last
- Menu-bar caterpillar that shows running effects and state
