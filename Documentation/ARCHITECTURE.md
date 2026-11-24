# Architecture

- **PicgetApp and AppDelegate** own AppKit lifecycle, the status item and the SwiftUI management window. Activation policy changes leave the desktop panels in place.
- **Library** is the main-actor coordinator. It owns widget configuration, visible panels, interaction callbacks, playback deadlines, and system observers.
- **Assets** serializes local imports and consumes remote streams with size and timeout limits. It stages imports before validating the ImageIO type and dimensions, hashes the encoded asset, and moves accepted files into local UUID-named storage.
- **ImageDecoder** is an actor with bounded decoded caches. Its serial execution prevents concurrent duplicate cache misses. Each window has at most one active decode request and rejects results from an obsolete generation.
- **DesktopWindow and WidgetCanvas** present images through transparent AppKit panels and Core Animation. Movement and resizing reuse the current decoded image. Mouse-up records geometry and triggers resolution selection. Appearance updates recalculate layer geometry.
- **Displays** chooses monitors by stable Core Graphics UUID and recovers unavailable geometry using the current screen bounds. Temporary fallback placement leaves preferred screen geometry available for reconnect.

Playback uses cumulative source frame durations and process uptime. A single one-shot timer schedules the earliest active deadline. Slow decoding can skip intermediate presentation indices while the source timeline advances. ImageIO provides the requested composited frame. A deterministic fixture exercises transparency, restore-to-background and restore-to-previous with out-of-order indices. No scheduler timer remains when every widget is static, hidden, paused or finished.

Configuration version 1 is saved atomically with one previous snapshot. Asset cleanup protects references in both snapshots. Changes are debounced and quit flushes pending configuration. Startup can recover the backup and preserve a corrupt primary for inspection.

Panels use the public desktop level plus one on the tested OS. The measured desktop, desktop-icon and normal level constants were −2147483623, −2147483603 and 0. Actual on-screen behavior depends on macOS desktop management. [Core Graphics window levels](https://developer.apple.com/documentation/coregraphics/cgwindowlevelforkey(_:))
