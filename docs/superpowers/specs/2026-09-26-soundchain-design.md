# SoundChain — design

Date: 2026-09-26. Status: approved in brainstorming, awaiting spec review.
"SoundChain" is a working name.

## Purpose

A Menubarn menu-bar app that runs **one global chain of Audio Unit (AU)
effects** over all macOS system audio, to correct speakers or headphones
(EQ, room correction, loudness). The user picks installed AU effects, opens
each plugin's own editor window to set it up, and the processed audio plays
through the current output device.

### Decisions made

| Question | Decision |
|---|---|
| Purpose | Output correction: an always-on chain |
| Chains vs devices | One global chain; it follows whatever the default output is |
| Chain editing | A separate chain window; the menu stays minimal |
| Audio core | Core Audio process tap + private aggregate device, AUs rendered in-process in the IO callback |
| Plugin formats | AU only (AUv2 and AUv3). VST3 is out of scope for v1 |

### Non-goals (v1)

- VST3 hosting.
- Per-app or per-device chains, named presets.
- Out-of-process plugin hosting.
- Mascot, character icon, app icon, Menubarn site entry (a later polish step).
- Recording or metering.

## Platform

- macOS **14.2+** (Core Audio process taps: `CATapDescription`,
  `AudioHardwareCreateProcessTap`).
- Swift 5.9+, SwiftPM, built on `../StatusItemKit`, bundled and signed by
  StatusItemKit's `scripts/make-app.sh`, symlinked into `~/Applications`,
  `LSUIElement`. Start at Login via StatusItemKit's `LoginItem` (SMAppService).
- `Info.plist` carries `NSAudioCaptureUsageDescription`.

## Components

Repo `~/Code/soundchain-menubar`, laid out like the other Menubarn apps.

### SoundChainCore (library, no audio I/O, no AppKit, unit-tested)

- **ChainModel** — ordered `[ChainSlot]`. A slot has: stable `id` (UUID),
  component identity (AU type, subtype, manufacturer), display name,
  manufacturer name, `bypassed: Bool`, `state: Data?` (the plugin's
  `fullState` as a binary plist). Operations: add (appends), remove, move,
  set-bypass, set-state, plus `masterBypass: Bool`.
- **ChainStore** — JSON persistence to
  `~/Library/Application Support/SoundChain/chain.json`. Writes are atomic
  (temp file, then rename). An unreadable or corrupt file is renamed to
  `chain.json.corrupt-<timestamp>` and an empty chain is used.
- **PluginCatalog** — given a list of component descriptors (name,
  manufacturer, identity, loadable flag), groups by manufacturer, sorts, and
  filters by a case-insensitive search over name and manufacturer. Unloadable
  plugins are included and flagged, not hidden.
- **CrashGuard** — tracks clean vs unclean exits via a marker in
  UserDefaults (set at launch, cleared at clean quit). After two consecutive
  unclean exits it reports that the app must start with master bypass on.
- **ChannelMap** — pure function mapping the stereo processed buffer onto an
  output of N channels: N ≥ 2 → channels 1–2, rest zeroed; N = 1 → (L+R)/2.

### SoundChain (executable)

- **TapEngine** — creates a global stereo process tap that excludes the app's
  own process, with `muteBehavior = .mutedWhenTapped`. Wraps the tap and the
  current default output device in a **private** aggregate device (so both
  vanish if the process dies), with the output device as clock source. Installs
  the IO proc. Buffer size requested: 512 frames. Listens for: default output
  device changes, nominal sample rate and buffer size changes on the output,
  and the device's is-alive state. Any of these tears down and rebuilds the
  aggregate; plugin instances are kept.
- **RenderChain** — an immutable snapshot: the ordered loaded AUs of the
  non-bypassed, available slots, their `renderBlock`s, and pre-allocated
  buffer lists. Published to the IO proc through a single atomic pointer.
- **PluginHost** — instantiates an `AUAudioUnit` from a component description
  (default options, i.e. in-process for v2, system default for v3), sets bus
  formats, calls `allocateRenderResources`, restores `fullState`, and captures
  `fullState` on request.
- **EditorWindows** — one floating `NSPanel` per open plugin, holding the
  view controller from `requestViewController`. If a plugin provides no UI,
  falls back to Apple's generic parameter view (`AUGenericViewController`).
  Only one panel per slot; reopening focuses it.
- **ChainWindow** — `NSTableView` of slots: drag handle to reorder, checkbox
  for bypass, "Open" button, unavailable slots shown in red with the reason.
  An "Add…" button shows a popover with a search field over PluginCatalog,
  grouped by manufacturer. A "–" button removes the selected slot (closing its
  editor).
- **Menu** — Bypass (toggle), Edit Chain…, a status line (output device name
  and state, or the current error), Start at Login, Quit.
- **Icon** — StatusItemKit `MeterIcon` dot: green when processing, grey when
  bypassed, red on error.

## Data flow

### Audio path (each IO cycle)

1. The aggregate's IO proc receives the tapped stereo system audio. The
   originals are muted by the tap.
2. It loads the current `RenderChain` pointer atomically.
3. Master bypass: copy input to output (via ChannelMap).
4. Otherwise render each slot in order, in place, using the pre-allocated
   buffers and a pull-input block that returns the previous stage's buffer.
5. NaN guard: if any output sample is non-finite, zero the whole buffer.
6. Write to the output channels via ChannelMap.

### Real-time rules

The IO proc never allocates, locks, logs, touches Objective-C or Swift
reference counting on non-preretained objects, or blocks. All chain edits
(add, remove, move, bypass, format change) build a new RenderChain on the main
thread, allocate render resources, then swap the pointer. Retired snapshots
are released on the main thread after a delay of several buffer periods,
never by the audio thread.

### Format

32-bit float, non-interleaved, stereo, at the aggregate's nominal sample
rate, max frames = the device buffer size (512 requested). A sample-rate or
buffer-size change re-prepares every plugin (`deallocate` then
`allocateRenderResources`) and swaps in a new snapshot.

### Settings persistence

- Chain structure changes (add, remove, move, bypass, master bypass) save
  immediately.
- A plugin's `fullState` is captured when its editor closes, every 5 s while
  any editor is open (saved only if the data changed), and at quit.

## Error handling

| Condition | Behaviour |
|---|---|
| System-audio capture permission not granted | Detected at launch via the TCC preflight SPI (as AudioCap does), loaded with `dlopen`; if unavailable, the check is skipped. Status line: "Grant System Audio Recording…", opening Privacy & Security. Icon red. |
| Tap or aggregate creation fails | Status line shows the OSStatus; retried on the next device-change event and from a "Retry" menu item. Icon red. |
| Plugin fails to instantiate (uninstalled, licensing, e.g. Waves -10875) | Slot kept with its state, marked unavailable in red with the error, skipped in rendering. |
| Plugin render returns an error | That slot is skipped for the rest of the snapshot's life (flag set from the audio thread via an atomic, read by the main thread), audio passes through, error shown in the chain window. |
| Non-finite samples | Buffer zeroed (see NaN guard). |
| App crash | Private tap and aggregate disappear; macOS plays unprocessed audio. |
| Two consecutive unclean exits | Launch with master bypass on and a status message naming the condition. |
| Mono output device | L and R summed into the single channel. |

## Testing

- **Unit tests (SoundChainCore):** ChainModel operations; ChainStore
  round-trip; corrupt file handling; PluginCatalog grouping, sorting and
  search including unloadable entries; CrashGuard transitions; ChannelMap for
  1, 2 and 6 output channels.
- **`--selftest` flag:** builds a RenderChain from Apple AUs (for example
  AUNBandEQ and AUDelay), renders a 1 kHz sine offline, and asserts the output
  differs from the input, contains only finite samples, and that master bypass
  reproduces the input bit-exactly. Exits non-zero on failure. No tap needed.
- **Manual end-to-end checklist:** grant permission; play music; add AUDelay
  and hear it; bypass on and off; reorder; switch output between built-in
  speakers and the Scarlett Solo; sleep and wake; `kill -9` the app and
  confirm unprocessed audio resumes; relaunch and confirm the chain and
  plugin settings are restored.
