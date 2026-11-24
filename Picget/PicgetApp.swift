import AppKit
import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers

private typealias ViewState<Value> = SwiftUI.State<Value>
@main
@MainActor
enum PicgetApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var library: Library?
    private var status: NSStatusItem?
    private var window: NSWindow?
    private let navigation = Navigation()
    private let launched = ProcessInfo.processInfo.systemUptime
    private let idleBenchmark = CommandLine.arguments.contains("--benchmark-idle")
    private var benchmarkDirectory: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            NSApplication.shared.presentError(CocoaError(.fileNoSuchFile))
            NSApplication.shared.terminate(nil)
            return
        }
        let root: URL
        if idleBenchmark {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("Picget-benchmark-\(UUID())")
            benchmarkDirectory = root
        } else {
            root = support.appendingPathComponent("Picget", isDirectory: true)
        }
        let library = Library(root: root)
        self.library = library
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let url = Bundle.main.url(forResource: "Picget", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            icon.size = NSSize(width: 18, height: 18)
            status?.button?.image = icon
        } else {
            status?.button?.image = NSImage(systemSymbolName: "photo.on.rectangle", accessibilityDescription: "Picget")
        }
        status?.button?.setAccessibilityLabel("Picget")
        let menu = NSMenu()
        for (title, selector) in [
            ("Add Widget…", #selector(add)), ("Manage Widgets", #selector(manage)),
            ("Toggle Edit Widgets", #selector(edit)), ("Show All Widgets", #selector(showAll)),
            ("Hide All Widgets", #selector(hideAll)), ("Pause or Resume All GIFs", #selector(pause)),
            ("Toggle Low Power Mode", #selector(togglePower)), ("Settings…", #selector(settings)),
            ("About Picget", #selector(about)), ("Quit Picget", #selector(quit))
        ] {
            let item = menu.addItem(withTitle: title, action: selector, keyEquivalent: "")
            item.target = self
        }
        status?.menu = menu
        let appMenu = NSMenu()
        for (title, selector, shortcut) in [
            ("About Picget", #selector(about), ""),
            ("Settings…", #selector(settings), ","),
            ("Quit Picget", #selector(quit), "q")
        ] {
            appMenu.addItem(withTitle: title, action: selector, keyEquivalent: shortcut).target = self
        }
        let menuBar = NSMenu()
        let appItem = NSMenuItem()
        menuBar.addItem(appItem)
        appItem.submenu = appMenu
        NSApplication.shared.mainMenu = menuBar
        setStandard(UserDefaults.standard.object(forKey: "standard") as? Bool ?? true)
        if idleBenchmark {
            measureIdle()
        } else if UserDefaults.standard.object(forKey: "openAtLaunch") as? Bool ?? true {
            manage()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        manage()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        library?.shutdown()
        if let benchmarkDirectory { try? FileManager.default.removeItem(at: benchmarkDirectory) }
    }

    private func measureIdle() {
        let startup = (ProcessInfo.processInfo.systemUptime - launched) * 1000
        Task {
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            let start = ProcessInfo.processInfo.systemUptime
            let initialCPU = Self.cpuSeconds()
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            let interval = ProcessInfo.processInfo.systemUptime - start
            let percent = (Self.cpuSeconds() - initialCPU) * 100 / interval
            var usage = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
                }
            }
            print(String(format: "startup_callback_ms=%.2f idle_cpu_percent=%.4f", startup, percent))
            if result == 0 { print("physical_footprint_bytes=\(usage.ri_phys_footprint)") }
            NSApplication.shared.terminate(nil)
        }
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return user + system
    }

    private func setStandard(_ standard: Bool) {
        let app = NSApplication.shared
        let policy: NSApplication.ActivationPolicy = standard ? .regular : .accessory
        guard app.activationPolicy() != policy else { return }
        if !app.setActivationPolicy(policy), app.activationPolicy() != policy {
            library?.error = "Picget could not change application mode."
        }
    }

    private func open(_ page: Page) {
        guard let library else { return }
        navigation.page = page
        if window == nil {
            let created = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 860, height: 590),
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                   backing: .buffered, defer: false)
            created.title = "Picget"
            created.minSize = CGSize(width: 690, height: 450)
            created.isReleasedWhenClosed = false
            created.contentView = NSHostingView(rootView: Management(setStandard: { [weak self] in
                self?.setStandard($0)
            }).environmentObject(library).environmentObject(navigation))
            created.center()
            window = created
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func add() { open(.widgets); navigation.importing = true }
    @objc private func manage() { open(.widgets) }
    @objc private func edit() { library?.editing.toggle() }
    @objc private func showAll() { library?.showAll(true) }
    @objc private func hideAll() { library?.showAll(false) }
    @objc private func pause() { library?.paused.toggle() }
    @objc private func togglePower() { if let library { library.power = library.power == .on ? .off : .on } }
    @objc private func settings() { open(.settings) }
    @objc private func about() { open(.about) }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
}

enum Page: String, CaseIterable { case widgets = "Widgets", settings = "Settings", about = "About" }

@MainActor
final class Navigation: ObservableObject {
    @Published var page = Page.widgets
    @Published var importing = false
}

struct Management: View {
    @AppStorage("interfaceLanguage") private var language = InterfaceLanguage.english
    private func tr(_ key: String) -> String { language.text(key) }

    @EnvironmentObject private var library: Library
    @EnvironmentObject private var navigation: Navigation
    @AppStorage("appearance") private var appearance = "System"
    @ViewState<UUID?> private var selection: UUID?
    @ViewState<UUID?> private var replacing: UUID?
    @ViewState<UUID?> private var deletion: UUID?
    let setStandard: (Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            switch navigation.page {
            case .widgets: widgets
            case .settings: Preferences(setStandard: setStandard)
            case .about:
                VStack(spacing: 12) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 80, height: 80)
                    Text("Picget").font(.largeTitle)
                    Text(tr("Your desktop. Your pictures.")).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .preferredColorScheme(appearance == "Dark" ? .dark : appearance == "Light" ? .light : nil)
        .sheet(isPresented: $navigation.importing, onDismiss: { replacing = nil }) {
            ImportImage(replacing: replacing)
        }
        .alert("Picget", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
            Button(tr("OK")) { library.error = nil }
        } message: { Text(tr(library.error ?? "")) }
        .confirmationDialog(tr("Delete this widget?"), isPresented: Binding(
            get: { deletion != nil }, set: { if !$0 { deletion = nil } }
        ), presenting: deletion) { id in
            Button(tr("Delete Widget"), role: .destructive) { library.delete(id); deletion = nil }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            if navigation.page == .widgets {
                Text(tr("Widgets")).font(.title3.weight(.semibold))
                Spacer()
                Toggle(tr("Edit Desktop"), isOn: $library.editing).toggleStyle(.button)
                Button { replacing = nil; navigation.importing = true } label: {
                    Label(tr("Add Widget"), systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("n")
            } else {
                Button { navigation.page = .widgets } label: {
                    Label(tr("Widgets"), systemImage: "chevron.left")
                }
                Text(tr(navigation.page.rawValue)).font(.title3.weight(.semibold))
                Spacer()
            }

            Button {
                navigation.page = navigation.page == .settings ? .widgets : .settings
            } label: {
                Image(systemName: "gearshape")
                    .frame(minWidth: 18)
            }
            .accessibilityLabel(tr("Settings"))
            .help(tr("Settings"))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var widgets: some View {
        VStack(spacing: 0) {
            if library.importing {
                HStack {
                    if let progress = library.progress { ProgressView(value: progress) }
                    else { ProgressView().controlSize(.small) }
                    Spacer()
                    Button(tr("Cancel Import")) { library.cancelImport() }
                }.padding(10)
                Divider()
            }
            if library.configuration.widgets.isEmpty {
                ContentUnavailableView {
                    VStack(spacing: 8) {
                        Image(nsImage: NSApplication.shared.applicationIconImage)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 56, height: 56)
                            .accessibilityHidden(true)
                        Text(tr("No Widgets"))
                    }
                } description: {
                    Text(tr("Add a picture or drop an image file here."))
                }
            } else {
                HSplitView {
                    List(selection: $selection) {
                        ForEach(library.configuration.widgets) { widget in
                            HStack {
                                Thumbnail(asset: widget.asset, size: 32)
                                VStack(alignment: .leading) {
                                    Text(widget.name).lineLimit(1)
                                    Text(library.configuration.assets[widget.asset]?.format.uppercased() ?? tr("Missing image"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if widget.locked { Image(systemName: "lock").accessibilityLabel(tr("Position locked")) }
                                if widget.clickThrough { Image(systemName: "cursorarrow.slash").accessibilityLabel(tr("Click-through")) }
                                Button {
                                    library.change(widget.id) { $0.visible.toggle() }
                                } label: {
                                    Image(systemName: widget.visible ? "eye" : "eye.slash")
                                }.buttonStyle(.borderless).accessibilityLabel(tr(widget.visible ? "Hide widget" : "Show widget"))
                            }.tag(widget.id)
                        }
                    }
                    .listStyle(.sidebar)
                    .frame(minWidth: 200, idealWidth: 225, maxWidth: 310)
                    if let widget = library.configuration.widgets.first(where: { $0.id == selection }) {
                        inspector(widget).frame(minWidth: 300)
                    } else {
                        ContentUnavailableView(tr("Select a Widget"), systemImage: "slider.horizontal.3")
                            .frame(minWidth: 300)
                    }
                }
            }
        }
        .onChange(of: library.configuration.widgets.map(\.id), initial: true) { _, ids in
            if selection.map(ids.contains) != true { selection = ids.first }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, url.isFileURL else { return false }
            library.add(url)
            return true
        }
    }

    private func field<T>(_ widget: Widget, _ path: WritableKeyPath<Widget, T>) -> Binding<T> {
        Binding(get: { library.configuration.widgets.first(where: { $0.id == widget.id })?[keyPath: path] ?? widget[keyPath: path] },
                set: { value in library.change(widget.id) { $0[keyPath: path] = value } })
    }

    private func radiusControl(_ widget: Widget) -> some View {
        let size = Displays.position(widget).size
        let maximum = Widget.maximumRadius(in: size)
        let radius = field(widget, \.radius)
        let displayed = Binding(
            get: { min(radius.wrappedValue, maximum) },
            set: { value in
                guard value.isFinite else { return }
                radius.wrappedValue = min(maximum, max(0, value))
            }
        )
        return HStack(spacing: 8) {
            Slider(value: displayed, in: 0...maximum) { Text(tr("Corner radius")) }
            TextField(tr("Corner radius"), value: displayed, format: .number.precision(.fractionLength(0...2)))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 66)
            Text("pt").foregroundStyle(.secondary)
        }
        .disabled(maximum == 0)
    }

    private func inspectorPreview(_ widget: Widget) -> some View {
        Thumbnail(asset: widget.asset, size: 208)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    private func dimension(_ widget: Widget, alongWidth: Bool) -> Binding<Double> {
        Binding(get: {
            let current = library.configuration.widgets.first { $0.id == widget.id } ?? widget
            let size = Displays.position(current).size
            return alongWidth ? size.width : size.height
        }, set: { value in
            guard let current = library.configuration.widgets.first(where: { $0.id == widget.id }),
                  library.editing || !current.locked else { return }
            var frame = Displays.position(current)
            let screen = Displays.screen(for: frame)
            let limit = screen?.visibleFrame.size ?? CGSize(width: 8192, height: 8192)
            frame.size = Widget.resized(frame.size, to: value, alongWidth: alongWidth,
                                        locked: current.aspectLocked, limit: limit)
            library.move(widget.id, to: frame, on: screen)
        })
    }

    private func inspector(_ widget: Widget) -> some View {
        Form {
            inspectorPreview(widget)
            Section(tr("Position")) {
                TextField(tr("Width (pt)"), value: dimension(widget, alongWidth: true), format: .number)
                    .disabled(widget.locked && !library.editing)
                TextField(tr("Height (pt)"), value: dimension(widget, alongWidth: false), format: .number)
                    .disabled(widget.locked && !library.editing)
                Toggle(tr("Lock aspect ratio"), isOn: field(widget, \.aspectLocked))
                if let screen = Displays.screen(for: Displays.position(widget)) {
                    PositionPad(frame: Displays.position(widget), screen: screen,
                                enabled: library.editing || !widget.locked) { frame in
                        library.move(widget.id, to: frame, on: screen)
                    }.id(widget.id)
                }
                Button(tr("Reset Position")) {
                    library.change(widget.id) {
                        $0.frame.origin = CGPoint(x: 80, y: 80); $0.display = nil; $0.relativeOrigin = nil
                    }
                }
            }
            Section(tr("Appearance")) {
                Slider(value: field(widget, \.opacity), in: 0...1) { Text(tr("Opacity")) }
                radiusControl(widget)
                DisclosureGroup(tr("Content mode")) {
                    Picker(tr("Content mode"), selection: field(widget, \.mode)) {
                        ForEach(ContentMode.allCases, id: \.self) { Text(tr($0.rawValue.capitalized)) }
                    }
                    if widget.mode == .crop {
                        Slider(value: field(widget, \.zoom), in: 1...4) { Text(tr("Zoom")) }
                        Slider(value: field(widget, \.cropX), in: -1...1) { Text(tr("Horizontal crop")) }
                        Slider(value: field(widget, \.cropY), in: -1...1) { Text(tr("Vertical crop")) }
                    }
                }
                Button(tr("Reset Appearance")) {
                    library.change(widget.id) {
                        $0.opacity = 1; $0.radius = 0; $0.mode = .fit
                        $0.zoom = 1; $0.cropX = 0; $0.cropY = 0
                    }
                }
            }
            Section(tr("Image")) {
                TextField(tr("Name"), text: field(widget, \.name))
                Text("\(Int(widget.frame.width)) × \(Int(widget.frame.height)) pt")
                HStack {
                    Button(tr("Replace Image…")) { replacing = widget.id; navigation.importing = true }
                    if let remote = widget.remote {
                        Button(tr("Refresh Image")) { library.add(remote, replacing: widget.id, remote: true) }
                    }
                }
            }
            Section(tr("Interaction")) {
                Toggle(tr("Lock position"), isOn: field(widget, \.locked))
                Toggle(tr("Click-through"), isOn: field(widget, \.clickThrough))

            }
            if library.configuration.assets[widget.asset]?.animated == true {
                DisclosureGroup(tr("GIF Playback")) {
                    Picker(tr("Timing"), selection: field(widget, \.playback)) {
                        Text(tr("Original Timing")).tag(PlaybackMode.original)
                        Text(tr("Custom FPS Limit")).tag(PlaybackMode.capped)
                        Text(tr("Play When Visible")).tag(PlaybackMode.visible)
                        Text(tr("Paused")).tag(PlaybackMode.paused)
                        Text(tr("Static First Frame")).tag(PlaybackMode.firstFrame)
                    }
                    if widget.playback == .capped {
                        Slider(value: field(widget, \.fps), in: 1...60, step: 1) {
                            Text("\(tr("Maximum")) \(Int(widget.fps)) FPS")
                        }
                    }
                }
            }
            Section {
                Button(tr("Duplicate Widget")) { library.duplicate(widget.id) }
                Button(tr("Delete Widget…"), role: .destructive) { deletion = widget.id }
            }
        }.formStyle(.grouped)
    }
}

struct ImportImage: View {
    @AppStorage("interfaceLanguage") private var language = InterfaceLanguage.english
    private func tr(_ key: String) -> String { language.text(key) }

    @EnvironmentObject private var library: Library
    @Environment(\.dismiss) private var dismiss
    @ViewState<String> private var text = ""
    @ViewState<URL?> private var file: URL?
    @ViewState<Bool> private var choosing = false
    let replacing: UUID?

    var body: some View {
        let remote = try? Assets.remoteURL(text)
        VStack(alignment: .leading, spacing: 16) {
            Text(tr(replacing == nil ? "Add Widget" : "Replace Image")).font(.title2.bold())
            Button(file?.lastPathComponent ?? tr("Choose File…")) { choosing = true }
                .fileImporter(isPresented: $choosing, allowedContentTypes: [.png, .jpeg, .gif]) { result in
                    switch result {
                    case .success(let url): file = url
                    case .failure(let error): library.error = error.localizedDescription
                    }
                }
            Text(tr("Drop a PNG, JPEG, or GIF here"))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first, url.isFileURL else { return false }
                    file = url
                    return true
                }
            TextField(tr("HTTPS image URL"), text: $text)
                .onChange(of: text) { _, _ in file = nil }
            if file == nil && !text.isEmpty && remote == nil {
                Text(tr("Enter a valid HTTPS URL.")).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(tr("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(tr(replacing == nil ? "Create Widget" : "Replace Image")) {
                    guard let url = file ?? remote else { return }
                    library.add(url, replacing: replacing, remote: file == nil)
                    dismiss()
                }.keyboardShortcut(.defaultAction).disabled((file ?? remote) == nil || library.importing)
            }
        }.padding(24).frame(width: 420)
    }
}

struct Preferences: View {
    @AppStorage("interfaceLanguage") private var language = InterfaceLanguage.english
    private func tr(_ key: String) -> String { language.text(key) }

    @EnvironmentObject private var library: Library
    @AppStorage("standard") private var standard = true
    @AppStorage("openAtLaunch") private var openAtLaunch = true
    @AppStorage("appearance") private var appearance = "System"
    @AppStorage("defaultFPS") private var defaultFPS = 20.0
    @ViewState<SMAppService.Status> private var login = SMAppService.mainApp.status
    let setStandard: (Bool) -> Void

    var body: some View {
        Form {
            Section(tr("General")) {
                Picker(tr("Language"), selection: $language) {
                    Text("English").tag(InterfaceLanguage.english)
                    Text("ภาษาไทย").tag(InterfaceLanguage.thai)
                }
                Picker(tr("Application mode"), selection: $standard) {
                    Text(tr("Standard Application")).tag(true)
                    Text(tr("Menu Bar")).tag(false)
                }.onChange(of: standard) { _, value in setStandard(value) }
                Toggle(tr("Open management window at startup"), isOn: $openAtLaunch)
                Toggle(tr("Launch at Login"), isOn: Binding(get: { login == .enabled || login == .requiresApproval },
                    set: { enable in
                        do {
                            if enable { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch { library.error = "Picget could not update Launch at Login." }
                        login = SMAppService.mainApp.status
                    }))
                if login == .requiresApproval {
                    Button(tr("Open Login Items Settings")) { SMAppService.openSystemSettingsLoginItems() }
                }
            }
            Section(tr("Performance")) {
                Picker(tr("Low Power Mode"), selection: $library.power) {
                    Text(tr("Off")).tag(PowerMode.off)
                    Text(tr("On")).tag(PowerMode.on)
                    Text(tr("Follow macOS")).tag(PowerMode.system)
                }
                Toggle(tr("Freeze GIFs in Low Power Mode"), isOn: $library.freeze)
                Slider(value: $defaultFPS, in: 1...60, step: 1) { Text("\(tr("Default GIF limit")) \(Int(defaultFPS)) FPS") }
                Toggle(tr("Pause all GIFs"), isOn: $library.paused)
            }
            Section(tr("Appearance")) {
                Picker(tr("Appearance"), selection: $appearance) {
                    ForEach(["System", "Light", "Dark"], id: \.self) { Text(tr($0)).tag($0) }
                }
            }
        }.formStyle(.grouped)
    }
}


private struct Thumbnail: View {
    @EnvironmentObject private var library: Library
    @ViewState<CGImage?> private var image: CGImage?
    let asset: UUID
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .task(id: asset) {
            image = nil
            let result = await library.thumbnail(asset, pixels: size > 128 ? 512 : 128)
            if !Task.isCancelled { image = result }
        }
        .accessibilityHidden(true)
    }
}

private struct PositionPad: View {
    @AppStorage("interfaceLanguage") private var language = InterfaceLanguage.english
    private func tr(_ key: String) -> String { language.text(key) }

    let frame: CGRect
    let screen: NSScreen
    let enabled: Bool
    let move: (CGRect) -> Void

    @ViewState<CGPoint?> private var preview: CGPoint?

    var body: some View {
        GeometryReader { proxy in
            let bounds = screen.visibleFrame
            let scale = min(proxy.size.width / max(1, bounds.width),
                            proxy.size.height / max(1, bounds.height))
            let width = bounds.width * scale
            let height = bounds.height * scale
            let marker = CGSize(width: frame.width * scale, height: frame.height * scale)
            let origin = preview ?? CGPoint(x: (frame.minX - bounds.minX) * scale,
                                            y: (bounds.maxY - frame.maxY) * scale)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(0.35))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor))
                    .frame(width: marker.width, height: marker.height)
                    .offset(x: origin.x, y: origin.y)
            }
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard enabled else { return }
                    preview = Self.clamp(value.location, marker: marker, in: CGSize(width: width, height: height))
                }
                .onEnded { value in
                    defer { preview = nil }
                    guard enabled, scale > 0 else { return }
                    let point = Self.clamp(value.location, marker: marker, in: CGSize(width: width, height: height))
                    var target = frame
                    target.origin = CGPoint(x: bounds.minX + point.x / scale,
                                            y: bounds.maxY - frame.height - point.y / scale)
                    move(target)
                })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 110)
        .opacity(enabled ? 1 : 0.5)
        Text(tr(enabled ? "Drag in the preview to move this widget." : "Unlock position or turn on Edit Desktop."))
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private static func clamp(_ point: CGPoint, marker: CGSize, in bounds: CGSize) -> CGPoint {
        CGPoint(x: min(max(0, bounds.width - marker.width), max(0, point.x - marker.width / 2)),
                y: min(max(0, bounds.height - marker.height), max(0, point.y - marker.height / 2)))
    }
}


enum InterfaceLanguage: String {
    case english = "en"
    case thai = "th"

    func text(_ key: String) -> String {
        self == .thai ? Self.translations[key, default: key] : key
    }

    private static let translations = [
        "Widgets": "วิดเจ็ต",
        "Settings": "การตั้งค่า",
        "About": "เกี่ยวกับ",
        "Your desktop. Your pictures.": "เดสก์ท็อปของคุณ รูปภาพของคุณ",
        "Language": "ภาษา",
        "General": "ทั่วไป",
        "Application mode": "โหมดแอป",
        "Standard Application": "แอปมาตรฐาน",
        "Menu Bar": "แถบเมนู",
        "Open management window at startup": "เปิดหน้าต่างจัดการเมื่อเริ่มแอป",
        "Launch at Login": "เปิดเมื่อเข้าสู่ระบบ",
        "Open Login Items Settings": "เปิดการตั้งค่ารายการเข้าสู่ระบบ",
        "Picget could not update Launch at Login.": "Picget เปลี่ยนการตั้งค่าเปิดเมื่อเข้าสู่ระบบไม่ได้",
        "Performance": "ประสิทธิภาพ",
        "Low Power Mode": "โหมดประหยัดพลังงาน",
        "Off": "ปิด",
        "On": "เปิด",
        "Follow macOS": "ตามการตั้งค่า macOS",
        "Freeze GIFs in Low Power Mode": "หยุด GIF ในโหมดประหยัดพลังงาน",
        "Default GIF limit": "อัตราเฟรมสูงสุดเริ่มต้นของ GIF",
        "Pause all GIFs": "หยุด GIF ทั้งหมดชั่วคราว",
        "Appearance": "รูปลักษณ์",
        "System": "ตามระบบ",
        "Light": "สว่าง",
        "Dark": "มืด",
        "OK": "ตกลง",
        "Delete this widget?": "ลบวิดเจ็ตนี้ไหม",
        "Delete Widget": "ลบวิดเจ็ต",
        "Delete Widget…": "ลบวิดเจ็ต…",
        "Edit Desktop": "แก้ไขเดสก์ท็อป",
        "Add Widget": "เพิ่มวิดเจ็ต",
        "Cancel Import": "ยกเลิกการนำเข้า",
        "No Widgets": "ยังไม่มีวิดเจ็ต",
        "Add a picture or drop an image file here.": "เพิ่มรูปภาพหรือลากไฟล์รูปมาวางที่นี่",
        "Missing image": "ไม่พบรูปภาพ",
        "Position locked": "ล็อกตำแหน่งแล้ว",
        "Click-through": "ให้คลิกทะลุ",
        "Hide widget": "ซ่อนวิดเจ็ต",
        "Show widget": "แสดงวิดเจ็ต",
        "Select a Widget": "เลือกวิดเจ็ต",
        "Image": "รูปภาพ",
        "Name": "ชื่อ",
        "Replace Image…": "เปลี่ยนรูปภาพ…",
        "Replace Image": "เปลี่ยนรูปภาพ",
        "Refresh Image": "โหลดรูปภาพใหม่",
        "Opacity": "ความทึบ",
        "Corner radius": "รัศมีมุมโค้ง",
        "Content mode": "รูปแบบการจัดภาพ",
        "Width (pt)": "ความกว้าง (pt)",
        "Height (pt)": "ความสูง (pt)",
        "Stretch": "ยืดเต็มกรอบ",
        "Fit": "พอดีกรอบ",
        "Fill": "เต็มกรอบ",
        "Crop": "ครอบตัด",
        "Zoom": "ซูม",
        "Horizontal crop": "ครอบตัดแนวนอน",
        "Vertical crop": "ครอบตัดแนวตั้ง",
        "Reset Appearance": "รีเซ็ตรูปลักษณ์",
        "Position": "ตำแหน่ง",
        "Reset Position": "รีเซ็ตตำแหน่ง",
        "Interaction": "การโต้ตอบ",
        "Lock position": "ล็อกตำแหน่ง",
        "Lock aspect ratio": "ล็อกสัดส่วน",
        "GIF Playback": "การเล่น GIF",
        "Timing": "จังหวะการเล่น",
        "Original Timing": "ตามต้นฉบับ",
        "Custom FPS Limit": "กำหนด FPS สูงสุด",
        "Play When Visible": "เล่นเมื่อมองเห็น",
        "Paused": "หยุดชั่วคราว",
        "Static First Frame": "แสดงเฟรมแรก",
        "Maximum": "สูงสุด",
        "Duplicate Widget": "ทำสำเนาวิดเจ็ต",
        "Choose File…": "เลือกไฟล์…",
        "Drop a PNG, JPEG, or GIF here": "ลากไฟล์ PNG, JPEG หรือ GIF มาวางที่นี่",
        "HTTPS image URL": "URL รูปภาพแบบ HTTPS",
        "Enter a valid HTTPS URL.": "ป้อน URL แบบ HTTPS ที่ถูกต้อง",
        "Cancel": "ยกเลิก",
        "Create Widget": "สร้างวิดเจ็ต",
        "Drag in the preview to move this widget.": "ลากในภาพตัวอย่างเพื่อย้ายวิดเจ็ต",
        "Unlock position or turn on Edit Desktop.": "ปลดล็อกตำแหน่งหรือเปิดโหมดแก้ไขเดสก์ท็อป",
    ]
}
