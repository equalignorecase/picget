# Known limitations

- System-level validation remains open for macOS 14, Finder click routing, Show Desktop, Mission Control, Stage Manager, Spaces, full-screen apps, wallpaper changes, display reconnect, sleep and login.
- AppKit occlusion state is best-effort for desktop panels. Play When Visible uses that state, while machine sleep, display sleep and session inactivity suspend all GIF playback.
- GIF compositing uses ImageIO. A representative disposal fixture passed on the development SDK runtime. A broader compatibility matrix, macOS 14 coverage, and expensive backward seeks remain open.
- File budgets are 100 MiB local and 25 MiB remote. Images are limited to 16,384 pixels per side and 64 megapixels. GIFs are limited to 4 megapixels and 2,000 frames. Rendering is capped at a 4,096-pixel long edge.
- Local preview before import, formal UI automation, and controlled HTTPS integration tests remain open. Widget list and inspector previews use static first frames.
- JSON currently has a schema version with recovery and validation. A migration adapter will be needed when a second schema exists.
- Only one import runs at a time. There is no speculative GIF prefetch. Launch at Login depends on the installed app bundle and macOS approval.
- The packaged executable was signed and checked as ARM64 with a macOS 14 minimum. Launch Services in the managed development sandbox returned `kLSNoExecutableErr`; direct bundle execution aborted inside AppKit registration. The interactive desktop session did launch the app. It verified management, local PNG import, thumbnails, and interaction controls. Desktop window ordering and the other system behaviors above still need verification.

Widget windows use macOS Space placement. Picget saves screen and geometry. After relaunch or window recreation, macOS assigns the new window to a Space based on the current desktop context.
