# Performance

## Budgets

The reusable decoded cache is 24 MiB each for static and animated images, or 8 MiB each in Low Power Mode. The budgets exclude displayed layers, in-flight decoding, encoded assets and WindowServer. The release defaults to one serial decode, one import and a maximum of 10 GIF FPS in Low Power Mode.

Target physical footprints are 30 MiB idle, 45 MiB for one 512 × 512 static widget, 70 MiB for five small static widgets, 70 MiB for one 512 × 512 GIF at 20 FPS, and 120 MiB for three small GIFs. Steady-state CPU targets are below 0.5% for five small static widgets and below 5% for a representative 512 × 512 GIF at 20 FPS.

## Environment and checks

Development host reported ARM64, macOS 27.2.1 (26B131), Swift 6.4.2, and Command Line Tools. Activity Monitor reported 8 GB of RAM. Sandboxed hardware queries did not expose the model or chip variant. Full Xcode, XCTest and Instruments were unavailable. Five native checks ran through a standalone harness, covering configuration round-trip, HTTPS URL validation, playback timing, PNG/JPEG downsampling, and GIF frame output. It checked four transparent frames, two disposal behaviors, variable durations, content deduplication and decoding after deleting the imported source.

## Reproduction

Build Release and launch outside the debugger. For each case, record hardware, OS, displays, backing scale, widget dimensions, image dimensions and GIF timing. Repeat after warm-up. Capture physical footprint with `footprint -p PID` and CPU samples with Activity Monitor or `ps -p PID -o %cpu,rss`. Use Instruments Time Profiler, System Trace, Allocations, Leaks and energy templates for decode latency, wakeups, startup and allocation trends. Inspect WindowServer separately. Test idle, 1 and 5 static widgets, 10 shared and 10 unique images, GIF at 10/20/30 FPS, 3 concurrent GIFs, mixed workloads and Low Power Mode. Repeat creation, deletion and replacement, import a large source, and leave a mixed workload running for at least 60 minutes.

A full workload matrix and long-run Instruments profile remain pending. Cache budgets are implementation limits and do not establish total memory use.

The development sandbox denied process inspection and physical footprint collection. Its Launch Services registration aborted in AppKit initialization for the packaged executable. A benchmark launched using the unbundled executable did not return a sample. The interactive desktop session launched the app and verified local PNG import and management controls. Activity Monitor did not provide a usable Picget process sample. There are no measured runtime figures to compare with the targets.

For a reproducible idle sample in a logged-in macOS session, run:

```sh
build/Picget.app/Contents/MacOS/Picget --benchmark-idle
```

It uses temporary configuration, skips the management window, warms up for three seconds, and samples process CPU over five seconds. It prints early application startup callback time and physical footprint where available.
