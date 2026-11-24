import AppKit
import Combine
import OSLog

@MainActor
final class Library: NSObject, ObservableObject {
    @Published private(set) var configuration = Configuration()
    @Published var error: String?
    @Published var progress: Double?
    @Published private(set) var importing = false
    @Published var editing = false { didSet { synchronize() } }
    @Published var paused = false { didSet { synchronize() } }
    @Published var power: PowerMode {
        didSet { UserDefaults.standard.set(power.rawValue, forKey: "power"); synchronize() }
    }
    @Published var freeze: Bool {
        didSet { UserDefaults.standard.set(freeze, forKey: "freeze"); synchronize() }
    }

    private let root: URL
    private let assets: Assets
    private let decoder = ImageDecoder()
    private let logger = Logger(subsystem: "app.picget.desktop", category: "library")
    private var windows: [UUID: Presentation] = [:]
    private var saveTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?
    private var timer: Timer?
    private var screenAwake = true
    private var machineAwake = true
    private var sessionActive = true
    private var storageWritable = true
    private var appliedReducedCache: Bool?
    private var memoryPressure: (any DispatchSourceMemoryPressure)?

    private var reduced: Bool { power == .on || (power == .system && ProcessInfo.processInfo.isLowPowerModeEnabled) }
    private var folder: URL { root.appendingPathComponent("Configuration", isDirectory: true) }
    private var primary: URL { folder.appendingPathComponent("widgets.json") }
    private var backup: URL { folder.appendingPathComponent("widgets.backup.json") }
    private var assetDirectory: URL { root.appendingPathComponent("Assets", isDirectory: true) }

    init(root: URL) {
        self.root = root
        assets = Assets(root: root)
        power = PowerMode(rawValue: UserDefaults.standard.string(forKey: "power") ?? "") ?? .system
        freeze = UserDefaults.standard.bool(forKey: "freeze")
        super.init()
        restore()
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspace.addObserver(self, selector: #selector(systemEvent(_:)), name: name, object: nil)
        }
        for name in [NSApplication.didChangeScreenParametersNotification,
                      Notification.Name.NSProcessInfoPowerStateDidChange,
                      NSWindow.didChangeBackingPropertiesNotification,
                      NSWindow.didChangeOcclusionStateNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(systemEvent(_:)), name: name, object: nil)
        }
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        pressure.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.decoder.clear() }
        }
        pressure.resume()
        memoryPressure = pressure
        synchronize()
    }

    @objc nonisolated private func systemEvent(_ note: Notification) {
        let name = note.name
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch name {
            case NSWorkspace.screensDidSleepNotification: screenAwake = false
            case NSWorkspace.screensDidWakeNotification: screenAwake = true
            case NSWorkspace.willSleepNotification: machineAwake = false
            case NSWorkspace.didWakeNotification: machineAwake = true
            case NSWorkspace.sessionDidResignActiveNotification: sessionActive = false
            case NSWorkspace.sessionDidBecomeActiveNotification: sessionActive = true
            default: break
            }
            synchronize()
        }
    }

    private func restore() {
        for url in [primary, backup] where FileManager.default.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                var saved = try JSONDecoder().decode(Configuration.self, from: data)
                guard saved.version == 1,
                      Set(saved.widgets.map(\.id)).count == saved.widgets.count,
                      saved.assets.allSatisfy({ key, asset in
                          key == asset.id && ["png", "jpg", "gif"].contains(asset.format) &&
                          (1...16384).contains(asset.width) && (1...16384).contains(asset.height) &&
                          (1...2000).contains(asset.ends.count) && asset.loops >= 0 &&
                          asset.ends.first.map { $0 > 0 } == true &&
                          zip(asset.ends, asset.ends.dropFirst()).allSatisfy { $0 < $1 }
                      }) else { throw PicgetError.configuration }
                for index in saved.widgets.indices { saved.widgets[index].validate() }
                configuration = saved
                if url == backup {
                    let recovered = folder.appendingPathComponent("widgets.corrupt-\(UUID()).json")
                    if FileManager.default.fileExists(atPath: primary.path) {
                        try FileManager.default.moveItem(at: primary, to: recovered)
                    }
                    error = "Picget restored your widgets from the backup."
                }
                return
            } catch {
                logger.error("Configuration read failed")
            }
        }
        if [primary, backup].contains(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            storageWritable = false
            error = "Picget could not restore settings. Existing files were preserved."
        }
    }

    private func saveSoon() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            self?.save()
        }
    }

    private func save() {
        guard storageWritable else { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let references = Set(configuration.widgets.map(\.asset))
            let removed = configuration.assets.filter { !references.contains($0.key) }
            var snapshot = configuration
            snapshot.assets = snapshot.assets.filter { references.contains($0.key) }
            let previous = try? Data(contentsOf: primary)
            let priorBackup = (try? Data(contentsOf: backup)).flatMap {
                try? JSONDecoder().decode(Configuration.self, from: $0)
            }
            if let previous { try previous.write(to: backup, options: .atomic) }
            try JSONEncoder().encode(snapshot).write(to: primary, options: .atomic)
            let backupAssets = previous.flatMap { try? JSONDecoder().decode(Configuration.self, from: $0) }
                ?? priorBackup
            let candidates = (priorBackup?.assets ?? [:]).merging(removed) { first, _ in first }
            for (id, asset) in candidates where !references.contains(id) && backupAssets?.assets[id] == nil {
                try? FileManager.default.removeItem(at: assetDirectory.appendingPathComponent(asset.filename))
            }
            configuration.assets = snapshot.assets
        } catch {
            logger.error("Configuration save failed")
            self.error = "Picget could not save your widgets."
        }
    }

    func change(_ id: UUID, _ mutate: (inout Widget) -> Void) {
        guard let index = configuration.widgets.firstIndex(where: { $0.id == id }) else { return }
        mutate(&configuration.widgets[index])
        configuration.widgets[index].modified = Date()
        configuration.widgets[index].validate()
        synchronize()
        saveSoon()
    }

    func duplicate(_ id: UUID) {
        guard var widget = configuration.widgets.first(where: { $0.id == id }) else { return }
        widget.id = UUID()
        widget.name += " Copy"
        widget.frame.origin.x += 24
        widget.frame.origin.y += 24
        widget.relativeOrigin = nil
        widget.created = Date()
        widget.modified = widget.created
        configuration.widgets.append(widget)
        synchronize()
        saveSoon()
    }

    func delete(_ id: UUID) {
        configuration.widgets.removeAll { $0.id == id }
        synchronize()
        saveSoon()
    }

    func showAll(_ show: Bool) {
        for index in configuration.widgets.indices {
            configuration.widgets[index].visible = show
            configuration.widgets[index].modified = Date()
        }
        synchronize()
        saveSoon()
    }

    func thumbnail(_ id: UUID, pixels: Int) async -> CGImage? {
        guard let asset = configuration.assets[id] else { return nil }
        return try? await decoder.decode(asset: asset, directory: assetDirectory, pixels: pixels, index: 0)
    }

    func cancelImport() { importTask?.cancel() }

    func add(_ url: URL, replacing id: UUID? = nil, remote: Bool = false) {
        guard importTask == nil else { error = PicgetError.busy.localizedDescription; return }
        guard storageWritable else { error = PicgetError.configuration.localizedDescription; return }
        importing = true
        progress = nil
        let existing = Array(configuration.assets.values)
        importTask = Task { [weak self] in
            guard let self else { return }
            defer { importTask = nil; importing = false; progress = nil }
            do {
                let asset: Asset
                if remote {
                    asset = try await assets.importRemote(url, existing: existing) { [weak self] value in
                        await self?.setProgress(value)
                    }
                } else {
                    asset = try await assets.importFile(url, existing: existing)
                }
                configuration.assets[asset.id] = asset
                if let id {
                    change(id) { $0.asset = asset.id; $0.remote = remote ? url : nil }
                    saveSoon()
                } else {
                    let filename = url.deletingPathExtension().lastPathComponent
                    var widget = Widget(asset: asset.id, name: filename.isEmpty ? "Image" : filename)
                    widget.remote = remote ? url : nil
                    widget.fps = UserDefaults.standard.object(forKey: "defaultFPS") as? Double ?? 20
                    configuration.widgets.append(widget)
                    synchronize()
                    saveSoon()
                }
            } catch is CancellationError {
                return
            } catch let failure as URLError where failure.code == .cancelled {
                return
            } catch {
                logger.error("Image import failed")
                self.error = (error as? PicgetError)?.localizedDescription ?? "Picget could not import the image. Check the file or connection and try again."
            }
        }
    }

    private func setProgress(_ value: Double) { progress = value }

    func move(_ id: UUID, to frame: CGRect, on target: NSScreen? = nil) {
        change(id) {
            $0.frame = frame
            guard let screen = target ?? Displays.screen(for: frame) else { return }
            let bounds = screen.visibleFrame
            $0.display = Displays.id(screen)
            $0.relativeOrigin = CGPoint(x: (frame.minX - bounds.minX) / max(1, bounds.width),
                                        y: (frame.minY - bounds.minY) / max(1, bounds.height))
        }
    }

    private func makeWindow(_ widget: Widget) -> Presentation {
        let canvas = WidgetCanvas(settings: widget)
        let window = DesktopWindow(canvas: canvas)
        let id = widget.id
        canvas.geometryChanged = { [weak self] frame in self?.move(id, to: frame) }
        canvas.dropped = { [weak self] url in self?.add(url, replacing: id) }
        return Presentation(window: window, canvas: canvas)
    }

    private func synchronize() {
        let activeIDs = Set(configuration.widgets.filter(\.visible).map(\.id))
        for id in Array(windows.keys) where !activeIDs.contains(id) {
            guard let state = windows.removeValue(forKey: id) else { continue }
            state.task?.cancel()
            state.window.close()
        }
        let lowPower = reduced
        if appliedReducedCache != lowPower {
            appliedReducedCache = lowPower
            Task { await decoder.reduceCache(lowPower) }
        }
        for widget in configuration.widgets where widget.visible {
            guard let asset = configuration.assets[widget.asset] else { continue }
            let state = windows[widget.id] ?? makeWindow(widget)
            windows[widget.id] = state
            state.canvas.settings = widget
            state.canvas.editing = editing
            state.window.ignoresMouseEvents = widget.clickThrough && !editing
            state.window.alphaValue = widget.opacity
            let frame = Displays.position(widget)
            if !state.canvas.isDragging, state.window.frame != frame { state.window.setFrame(frame, display: true) }
            state.window.orderForEditing(editing)
            state.canvas.layoutPicture()
            let pointScale = state.window.backingScaleFactor
            let horizontal = frame.width * pointScale / Double(asset.width)
            let vertical = frame.height * pointScale / Double(asset.height)
            let renderScale = widget.mode == .fit ? min(horizontal, vertical) : max(horizontal, vertical)
            let demand = Double(max(asset.width, asset.height)) * renderScale * (widget.mode == .crop ? widget.zoom : 1)
            let pixels = min(4096, max(64, Int(ceil(demand / 64)) * 64))
            let reset = state.asset != asset.id
            if reset || state.pixels != pixels {
                state.task?.cancel()
                state.task = nil
                state.generation &+= 1
                state.asset = asset.id
                state.pixels = pixels
                if reset {
                    state.started = nil
                    state.elapsed = 0
                    state.index = nil
                    state.failed = false
                    state.canvas.present(nil)
                    state.finished = false
                }
                request(state, asset: asset, index: state.index ?? 0)
            }
            let eligible = asset.animated && !paused && screenAwake && machineAwake && sessionActive &&
                widget.opacity > 0 && widget.playback != .paused && widget.playback != .firstFrame &&
                !(reduced && freeze) && !state.finished && !state.failed &&
                (widget.playback != .visible || state.window.occlusionState.contains(.visible))
            if eligible, state.started == nil {
                state.started = ProcessInfo.processInfo.systemUptime - state.elapsed
                state.deadline = ProcessInfo.processInfo.systemUptime
            } else if !eligible, let started = state.started {
                state.elapsed = ProcessInfo.processInfo.systemUptime - started
                state.started = nil
                if state.index != nil {
                    state.task?.cancel()
                    state.task = nil
                    state.generation &+= 1
                }
            }
            if widget.playback == .firstFrame && state.index != 0 && state.task == nil && !state.failed {
                request(state, asset: asset, index: 0)
            }
        }
        schedule()
    }

    private func request(_ state: Presentation, asset: Asset, index: Int) {
        guard state.task == nil else { return }
        let generation = state.generation
        let pixels = state.pixels
        let decoder = decoder
        let directory = assetDirectory
        state.task = Task { [weak self, weak state] in
            do {
                let image = try await decoder.decode(asset: asset, directory: directory, pixels: pixels, index: index)
                guard let state, state.generation == generation, !Task.isCancelled else { return }
                state.task = nil
                state.index = index
                state.canvas.present(image)
                if state.canvas.settings.playback == .firstFrame && index != 0 {
                    self?.request(state, asset: asset, index: 0)
                }
                self?.schedule()
            } catch {
                guard let state, state.generation == generation, !Task.isCancelled else { return }
                state.task = nil
                state.failed = true
                state.started = nil
                self?.error = "Picget could not display \(state.canvas.settings.name). Replace its image to recover."
                self?.schedule()
            }
        }
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard let next = windows.values.filter({ $0.started != nil && $0.task == nil }).map(\.deadline).min() else { return }
        let wake = Timer(timeInterval: max(0.001, next - ProcessInfo.processInfo.systemUptime), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        wake.tolerance = 0.002
        timer = wake
        RunLoop.main.add(wake, forMode: .common)
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        for state in windows.values {
            guard let start = state.started, state.task == nil, state.deadline <= now + 0.001,
                  let id = state.asset, let asset = configuration.assets[id],
                  let duration = asset.ends.last else { continue }
            let elapsed = max(0, now - start)
            let widget = state.canvas.settings
            guard let index = Playback.frame(at: elapsed, ends: asset.ends, loops: asset.loops) else {
                state.started = nil
                state.finished = true
                if state.index != asset.ends.count - 1 { request(state, asset: asset, index: asset.ends.count - 1) }
                continue
            }
            let limit = min(reduced ? 10 : 60, widget.playback == .capped ? widget.fps : 60)
            let frameEnd = start + floor(elapsed / duration) * duration + asset.ends[index]
            state.deadline = max(frameEnd, now + 1 / limit)
            if state.index != index { request(state, asset: asset, index: index) }
        }
        schedule()
    }

    func shutdown() {
        importTask?.cancel()
        saveTask?.cancel()
        save()
        timer?.invalidate()
        memoryPressure?.cancel()
        for state in windows.values { state.task?.cancel(); state.window.close() }
        windows.removeAll()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }
}

@MainActor
private final class Presentation {
    let window: DesktopWindow
    let canvas: WidgetCanvas
    var task: Task<Void, Never>?
    var generation: UInt64 = 0
    var asset: UUID?
    var pixels = 0
    var index: Int?
    var started: Double?
    var elapsed = 0.0
    var deadline = 0.0
    var finished = false
    var failed = false

    init(window: DesktopWindow, canvas: WidgetCanvas) {
        self.window = window
        self.canvas = canvas
    }
}
