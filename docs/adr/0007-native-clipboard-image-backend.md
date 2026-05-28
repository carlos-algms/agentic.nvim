# 0007. Native clipboard image backend

- Status: accepted
- Last updated: 2026-05-28
- Commits: 7473096, 364185d
- Related: -

## Context

Clipboard image paste used to depend on `img-clip.nvim`. On macOS, that path
used `pngpaste`.

`pngpaste` has a long-standing washed/desaturated colour bug for wide-gamut
macOS screenshots since Mojave. Files report sRGB, but pixels are already dull.
Preview can hide this through colour-managed rendering.

Evidence:

- `sips -g all` reported `sRGB IEC61966-2.1`, 8-bit RGBA for both `pngpaste`
  output and a native macOS screenshot saved to disk.
- The native screenshot rendered correctly in Firefox.
- The `pngpaste` output rendered washed/desaturated in Firefox and terminal
  image viewers.
- sRGB display profile and Firefox full colour-management mode did not fix the
  output.
- Evidence pointed to dull pixel values written by `pngpaste`, not bad tags.

Likely mechanism: macOS clipboard screenshots can carry display-native or P3
data. `pngpaste` writes PNG data without a correct gamut conversion to sRGB, so
wide-gamut screenshot pixels become numerically dull while still tagged sRGB.

`jcsalterego/pngpaste` is effectively unmaintained. `ibrikin/pngpaste` is
macOS-only with low adoption. Keeping `img-clip.nvim` leaves Agentic coupled to
platform-specific CLI behaviour it can own directly.

## Current decision

Agentic owns clipboard image paste through `agentic.ui.clipboard_image`.

The backend uses platform-native tools:

- macOS: `osascript` clipboard `PNGf`
- Windows: `powershell.exe`
- WSL: `powershell.exe` with `wslpath -w` for the PowerShell save argument
- Linux Wayland: `wl-paste`
- Linux X11: `xclip`

`agentic.ui.clipboard` owns temporary file lifecycle. The backend owns platform
probing and save.

Drag-and-drop remains terminal behaviour. Agentic does not copy local files into
a remote filesystem for SSH sessions.

## Consequences

- Clipboard image paste has no Neovim plugin dependency.
- Platform probing and save behaviour live in one module.
- Linux still depends on desktop clipboard tools and session access.
- SSH/headless sessions need an explicit file-transfer workflow before attaching
  images.
- WSL conversion applies only to the Windows command argument, while Neovim
  keeps using the Linux path.

## Rejected / superseded alternatives

| Option                         | Reason rejected                                     |
| ------------------------------ | --------------------------------------------------- |
| Keep `img-clip.nvim`           | Keeps plugin dependency and `pngpaste` macOS path.  |
| Depend on `pngpaste` directly  | macOS-only, washed-colour bug, stale project.       |
| Use `ibrikin/pngpaste`         | macOS-only, low adoption, still another dependency. |
| Auto-copy local files over SSH | Requires transport, trust, and remote path policy.  |

## Changelog

| Date       | Commit  | Change                                 |
| ---------- | ------- | -------------------------------------- |
| 2026-05-28 | 7473096 | Initial native clipboard backend.      |
| 2026-05-28 | 364185d | Refine WSL and SSH clipboard handling. |

## Sources

- [jcsalterego/pngpaste#16: color looks not well in Mac Mojave](https://github.com/jcsalterego/pngpaste/issues/16)
- [jcsalterego/pngpaste](https://github.com/jcsalterego/pngpaste)
- [ibrikin/pngpaste](https://github.com/ibrikin/pngpaste)
- [HakonHarnes/img-clip.nvim](https://github.com/HakonHarnes/img-clip.nvim)
- [Simon Willison TIL: impaste](https://til.simonwillison.net/macos/impaste)
