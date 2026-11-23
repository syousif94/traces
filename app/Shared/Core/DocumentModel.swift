import Foundation
import Observation
import SwiftUI

enum ViewMode: String, CaseIterable, Identifiable {
    case schematic = "Schematic", pcb = "PCB", threeD = "3D", code = "Code"
    var id: String { rawValue }
    var short: String { self == .schematic ? "Sch" : rawValue }
}

enum CanvasTool: String, CaseIterable, Identifiable {
    case select, place, route, via, measure
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .select: "cursorarrow"
        case .place: "cpu"
        case .route: "point.topleft.down.to.point.bottomright.curvepath"
        case .via: "smallcircle.circle"
        case .measure: "ruler"
        }
    }
    var label: String {
        switch self {
        case .select: "Select"
        case .place: "Place part"
        case .route: "Route trace"
        case .via: "Place via"
        case .measure: "Measure"
        }
    }
}

enum PCBLayer: String, CaseIterable, Identifiable {
    case topCopper = "Top copper", bottomCopper = "Bottom copper", pads = "Pads", vias = "Vias", silk = "Silkscreen"
    case courtyard = "Courtyard", ratsnest = "Ratsnest", drc = "DRC markers"
    var id: String { rawValue }
    var color: Color {
        switch self {
        case .topCopper: Theme.copperTop
        case .bottomCopper: Theme.copperBottom
        case .pads: Theme.pad
        case .vias: Theme.pad
        case .silk: Theme.silk
        case .courtyard: Theme.courtyard
        case .ratsnest: Theme.warning
        case .drc: Theme.danger
        }
    }
}

/// Generic parts for the Place tool (real ones come from `PartsCatalog`).
enum PlaceablePart: String, CaseIterable, Identifiable {
    case resistor, capacitor, led, chip
    var id: String { rawValue }
}

func fmt(_ v: Double, _ digits: Int = 2) -> String {
    let r = (v * 1000).rounded() / 1000
    if r == r.rounded() { return String(Int(r)) }
    return String(format: "%.\(digits)f", r).replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
}

struct DesignVariable: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var value: String
    var unit: String
}

struct UndoEntry {
    var label: String
    var files: [String: String?]  // path → content before (nil = did not exist)
}

@Observable @MainActor
final class DocumentModel {
    let project: Project
    let url: URL
    let name: String
    private let securityScoped: Bool

    // Files and editor
    var files: [FileEntry] = []
    var openTabs: [String] = []
    var openFile: String = ""
    var uncommitted: Set<String> = []
    var editorRevision = 0  // bumps when files change underneath the editor
    var revealLine: Int?

    // Compile
    var circuit = CircuitModel()
    var circuitJSON = Data()
    var compileErrors: [EngineMessage] = []
    var compileMs: Int?
    var compiling = false
    var engineReady = false
    private var compileGeneration = 0
    private var compileTask: Task<Void, Never>?

    // DRC
    var violations: [Violation] = []
    var drcRunning = false
    var drcErrors: Int { violations.filter(\.isError).count }
    var drcWarnings: Int { violations.count - drcErrors }

    // Canvas state
    var viewMode: ViewMode = .pcb
    var tool: CanvasTool = .select
    var selection: String?
    var layerVisible: [PCBLayer: Bool] = Dictionary(uniqueKeysWithValues: PCBLayer.allCases.map { ($0, true) })
    var layerOpacity: [PCBLayer: Double] = Dictionary(uniqueKeysWithValues: PCBLayer.allCases.map { ($0, 1.0) })
    var placePart: PartToPlace = .generic(.resistor)
    /// Modules waiting to be written with the next placement: path → source.
    var pendingModules: [String: String] = [:]
    var measureA: CGPoint?
    var measureB: CGPoint?
    var routeFrom: (component: String, port: String, at: CGPoint)?
    var snapStep: Double = 0.5

    // Git
    var branch = "main"
    var pendingChange: AgentChange?
    var history: [CommitInfo] = []
    private var touchCommitTask: Task<Void, Never>?
    private var touchBurst: [String] = []

    // Undo (touch edits, accepted agent edits, variables; the code editor has its own)
    var undoStack: [UndoEntry] = []
    var redoStack: [UndoEntry] = []

    // Misc
    var variables: [DesignVariable] = []
    var banner: Banner?
    var showAgentPanel = true
    var showDRC = false
    var exportRequested = 0
    /// Bumped to fit the board to the view.
    var fitRequested = 0
    var agent: AgentSession!
    private(set) var host: AppEngineHost!
    private var watcher: FolderWatcher?
    private var lastOwnWrite = Date.distantPast

    struct Banner: Identifiable, Equatable {
        let id = UUID()
        var text: String
        var isError: Bool
    }

    init(url: URL, securityScoped: Bool = false) throws {
        self.url = url
        self.securityScoped = securityScoped
        project = try Project.open(path: url.path)
        name = project.name()
        host = AppEngineHost(document: self)
        agent = AgentSession(document: self)
        refreshFiles()
        openFile = project.entryPath()
        openTabs = [openFile]
        refreshGit()
        loadVariables()
        watcher = FolderWatcher(url: url) { [weak self] in Task { @MainActor in self?.externalChange() } }
        Task {
            await EngineBridge.shared.waitUntilReady()
            engineReady = true
            await compileNow()
        }
    }

    func close() {
        watcher?.stop()
        compileTask?.cancel()
        flushTouchCommit()
        if securityScoped { url.stopAccessingSecurityScopedResource() }
    }

    var showsAgentView: Bool { pendingChange != nil }

    // MARK: Files

    func refreshFiles() {
        files = project.listFiles()
        uncommitted = Set(project.uncommittedPaths())
    }

    func open(_ path: String, line: Int? = nil) {
        if !openTabs.contains(path) { openTabs.append(path) }
        openFile = path
        revealLine = line
    }

    func closeTab(_ path: String) {
        openTabs.removeAll { $0 == path }
        if openFile == path { openFile = openTabs.last ?? project.entryPath() }
        if openTabs.isEmpty { openTabs = [openFile] }
    }

    func text(of path: String, agentView: Bool? = nil) -> String {
        (try? project.readFile(path: path, agentView: agentView ?? showsAgentView)) ?? ""
    }

    func isAgentModified(_ path: String) -> Bool { files.first { $0.path == path }?.agentModified ?? false }

    /// The user's code edit (debounced by the editor).
    func saveFromEditor(path: String, text: String) {
        guard text != (try? project.readFile(path: path, agentView: false)) else { return }
        do {
            lastOwnWrite = Date()
            try project.writeFile(path: path, content: text)
            refreshFiles()
            if path == "vars.ts" { loadVariables() }
            scheduleCompile()
        } catch { show(error) }
    }

    private func externalChange() {
        // Our own writes also trip the watcher; ignore those.
        guard Date().timeIntervalSince(lastOwnWrite) > 1.5 else { return }
        refreshFiles()
        refreshGit()
        loadVariables()
        editorRevision += 1
        scheduleCompile()
    }

    // MARK: Compile

    func scheduleCompile(delay: Duration = .milliseconds(300)) {
        compileTask?.cancel()
        compileTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.compileNow()
        }
    }

    @discardableResult
    func compileNow() async -> Bool {
        compileGeneration += 1
        let gen = compileGeneration
        compiling = true
        defer { if gen == compileGeneration { compiling = false } }
        do {
            let r = try await EngineBridge.shared.compile(filesJSON: project.fileMapJson(agentView: showsAgentView), entry: project.entryPath())
            guard gen == compileGeneration else { return true }  // a newer compile superseded this one
            await apply(r)
            return !r.errors.contains { $0.type == "compile_error" }
        } catch {
            guard gen == compileGeneration else { return true }
            compileErrors = [EngineMessage(["type": "compile_error", "message": error.localizedDescription])]
            return false
        }
    }

    private func apply(_ r: EngineBridge.CompileResult) async {
        compileErrors = r.errors
        compileMs = r.ms
        let fatal = r.errors.contains { $0.type == "compile_error" }
        if !fatal || circuit.isEmpty {
            let data = r.circuitJSON
            let model = await Task.detached { CircuitModel.decode(data) }.value
            circuitJSON = data
            circuit = model
            project.setCircuitJson(json: String(decoding: data, as: UTF8.self))
            if let s = selection, model.component(named: s) == nil { selection = nil }
            scheduleThumbnail()
            await runDRC()
        }
    }

    private var thumbnailTask: Task<Void, Never>?

    /// Redraw the start page's picture of this board a moment after it settles.
    private func scheduleThumbnail() {
        thumbnailTask?.cancel()
        thumbnailTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self else { return }
            Thumbnails.save(self.circuit, for: self.url)
        }
    }

    var routedCounts: (routed: Int, unrouted: Int) {
        let unrouted = circuit.ratsnest.count
        let total = (try? JSONSerialization.jsonObject(with: circuitJSON) as? [[String: Any]])?.filter { $0["type"] as? String == "source_trace" }.count ?? 0
        return (max(0, total - unrouted), unrouted)
    }

    // MARK: DRC

    func runDRC() async {
        guard !circuitJSON.isEmpty else { return }
        drcRunning = true
        defer { drcRunning = false }
        violations = (try? await EngineBridge.shared.drc(circuitJSON: circuitJSON)) ?? violations
    }

    func violationPosition(_ v: Violation) -> CGPoint? {
        if let x = v.x, let y = v.y { return CGPoint(x: x, y: y) }
        for id in v.elementIds {
            if let p = circuit.portPositions[id] { return p }
            if let c = circuit.component(pcbId: id) { return c.center }
        }
        return nil
    }

    // MARK: Agent-facing engine calls (EngineHost)

    func compileForAgent(filesJSON: String) async -> String {
        compileGeneration += 1
        let gen = compileGeneration
        compiling = true
        defer { if gen == compileGeneration { compiling = false } }
        do {
            let r = try await EngineBridge.shared.compile(filesJSON: filesJSON, entry: project.entryPath())
            refreshFiles()
            refreshPending()
            editorRevision += 1
            if gen == compileGeneration { await apply(r) }
            return r.raw
        } catch {
            return "{\"circuitJson\":[],\"errors\":[{\"type\":\"compile_error\",\"message\":\(jsonString(error.localizedDescription))}]}"
        }
    }

    func drcForAgent(circuitJSON json: String) async -> String {
        let v = (try? await EngineBridge.shared.drc(circuitJSON: Data(json.utf8))) ?? []
        violations = v
        let arr: [[String: Any]] = v.map { ["type": $0.type, "severity": $0.severity, "message": $0.message, "elementIds": $0.elementIds, "x": $0.x as Any, "y": $0.y as Any] }
        return String(decoding: (try? JSONSerialization.data(withJSONObject: ["violations": arr])) ?? Data(), as: UTF8.self)
    }

    func exportForAgent(formats: [String]) async -> String {
        do {
            let url = try await buildFabZip(formats: formats, allowWarnings: true)
            return String(decoding: try JSONSerialization.data(withJSONObject: ["zip": url.path]), as: UTF8.self)
        } catch {
            return "{\"error\":\(jsonString(error.localizedDescription))}"
        }
    }

    func renderSnapshot(view: String, highlight: [String]) -> Data? {
        Snapshot.png(model: circuit, view: view, highlight: highlight, layers: layerVisible)
    }

    // MARK: Selection & placement

    func select(_ name: String?, reveal: Bool = false) {
        selection = name
        if reveal, let name { revealInSource(name) }
    }

    func revealInSource(_ name: String) {
        let pattern = "name=\"\(name)\""
        for f in files where f.path.hasSuffix(".tsx") {
            let t = text(of: f.path)
            if let r = t.range(of: pattern) {
                let line = t[..<r.lowerBound].filter { $0 == "\n" }.count + 1
                open(f.path, line: line)
                return
            }
        }
    }

    /// Touch placement: write through the core, recompile, revert if the compile fails.
    func move(_ name: String, to p: CGPoint, rotation: Double? = nil) async {
        guard !showsAgentView else {
            show("Accept or discard the agent's change before moving parts.", isError: true)
            return
        }
        let before = snapshotFiles(["manual-edits.json"] + files.map(\.path).filter { $0.hasSuffix(".tsx") })
        do {
            lastOwnWrite = Date()
            _ = try project.setPlacement(component: name, x: Double(p.x), y: Double(p.y), rotation: rotation)
        } catch {
            show(error)
            return
        }
        refreshFiles()
        editorRevision += 1
        let ok = await compileNow()
        if !ok {
            restore(before)
            editorRevision += 1
            await compileNow()
            show("Move reverted: \(compileErrors.first?.message ?? "compile failed")", isError: true)
            return
        }
        pushUndo(UndoEntry(label: "Move \(name)", files: before))
        noteTouchEdit(name)
    }

    func nudgeRotation(_ name: String, by deg: Double) async {
        guard let c = circuit.component(named: name) else { return }
        await move(name, to: c.center, rotation: (c.rotation + deg).truncatingRemainder(dividingBy: 360))
    }

    /// Touch edits auto-commit on main after 10 s idle, one commit per gesture burst.
    private func noteTouchEdit(_ what: String) {
        if !touchBurst.contains(what) { touchBurst.append(what) }
        touchCommitTask?.cancel()
        touchCommitTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.flushTouchCommit()
        }
    }

    func flushTouchCommit() {
        touchCommitTask?.cancel()
        guard !touchBurst.isEmpty else { return }
        let msg = "Move " + touchBurst.joined(separator: ", ")
        touchBurst = []
        _ = try? project.commitAll(message: msg)
        refreshGit()
        refreshFiles()
    }

    // MARK: Edits from canvas tools

    private func insertIntoBoard(_ jsx: String, importing module: (name: String, path: String, source: String?)? = nil) async -> Bool {
        let entry = project.entryPath()
        var src = text(of: entry, agentView: false)
        guard let r = src.range(of: "</board>", options: .backwards) else {
            show("Couldn't find </board> in \(entry).", isError: true)
            return false
        }
        let before = snapshotFiles([entry] + (module.map { [$0.path] } ?? []))
        src.insert(contentsOf: "  " + jsx + "\n  ", at: r.lowerBound)
        src = src.replacingOccurrences(of: "\n  \n  </board>", with: "\n  </board>")
        lastOwnWrite = Date()
        do {
            if let module {
                if let source = module.source { try project.writeFile(path: module.path, content: source) }
                let spec = "./" + module.path.replacingOccurrences(of: #"\.tsx?$"#, with: "", options: .regularExpression)
                if !src.contains("from \"\(spec)\"") { src = "import { \(module.name) } from \"\(spec)\"\n" + src }
            }
            try project.writeFile(path: entry, content: src)
        } catch { show(error); return false }
        refreshFiles()
        editorRevision += 1
        if await compileNow() {
            pushUndo(UndoEntry(label: "Edit \(entry)", files: before))
            return true
        }
        restore(before)
        editorRevision += 1
        await compileNow()
        show("Reverted: \(compileErrors.first?.message ?? "compile failed")", isError: true)
        return false
    }

    func placePart(at p: CGPoint) async {
        guard !showsAgentView else { show("Accept or discard the agent's change first.", isError: true); return }
        let part = placePart
        let used = Set(circuit.components.map(\.name))
        var n = 1
        while used.contains("\(part.prefix)\(n)") { n += 1 }
        let name = "\(part.prefix)\(n)"
        let module = part.module.map { (name: part.tag, path: $0, source: pendingModules[$0]) }
        if await insertIntoBoard(part.jsx(name: name, x: snap(p.x), y: snap(p.y)), importing: module) {
            if let path = part.module { pendingModules[path] = nil }
            selection = name
            noteTouchEdit("place \(name)")
        }
    }

    /// Arm the Place tool with a part from the library (its module is written on first placement).
    func choose(_ part: PartToPlace, module: PartsCatalog.ImportedModule?) {
        if let module, (try? project.readFile(path: module.path, agentView: false)) == nil {
            pendingModules[module.path] = module.source
        }
        placePart = part
        tool = .place
        if viewMode != .pcb { viewMode = .pcb }
    }

    /// Place the armed part in the middle of the board (for when there's nowhere to tap).
    func placeAtCentre() async {
        await placePart(at: circuit.boardCenter)
    }

    func placeVia(at p: CGPoint) async {
        guard !showsAgentView else { show("Accept or discard the agent's change first.", isError: true); return }
        if await insertIntoBoard("<via pcbX={\(fmt(snap(p.x)))} pcbY={\(fmt(snap(p.y)))} fromLayer=\"top\" toLayer=\"bottom\" holeDiameter=\"0.3mm\" outerDiameter=\"0.6mm\" />") {
            noteTouchEdit("via")
        }
    }

    /// Route tool: tap pad, then pad → a <trace> in the board; the autorouter draws the path.
    func routeTap(at p: CGPoint) async {
        guard let (comp, port, at) = portNear(p) else { routeFrom = nil; return }
        guard let from = routeFrom else { routeFrom = (comp, port, at); return }
        routeFrom = nil
        guard from.component != comp || from.port != port else { return }
        if await insertIntoBoard("<trace from=\".\(from.component) > .\(from.port)\" to=\".\(comp) > .\(port)\" />") {
            noteTouchEdit("trace \(from.component)-\(comp)")
        }
    }

    func portNear(_ p: CGPoint) -> (String, String, CGPoint)? {
        guard let json = try? JSONSerialization.jsonObject(with: circuitJSON) as? [[String: Any]] else { return nil }
        var best: (String, String, CGPoint, CGFloat)?
        let sources = Dictionary(json.filter { $0["type"] as? String == "source_port" }.compactMap { e in (e["source_port_id"] as? String).map { ($0, e) } }, uniquingKeysWith: { a, _ in a })
        let comps = Dictionary(json.filter { $0["type"] as? String == "source_component" }.compactMap { e in (e["source_component_id"] as? String).map { ($0, e["name"] as? String ?? "") } }, uniquingKeysWith: { a, _ in a })
        for e in json where e["type"] as? String == "pcb_port" {
            guard let x = (e["x"] as? NSNumber)?.doubleValue, let y = (e["y"] as? NSNumber)?.doubleValue,
                  let sp = (e["source_port_id"] as? String).flatMap({ sources[$0] }),
                  let cname = (sp["source_component_id"] as? String).flatMap({ comps[$0] }) else { continue }
            let pname = (sp["name"] as? String) ?? "pin\(sp["pin_number"] ?? 1)"
            let d = hypot(CGFloat(x) - p.x, CGFloat(y) - p.y)
            if d < 1.2, d < (best?.3 ?? .infinity) { best = (cname, pname, CGPoint(x: x, y: y), d) }
        }
        return best.map { ($0.0, $0.1, $0.2) }
    }

    func snap(_ v: CGFloat) -> Double { (Double(v) / snapStep).rounded() * snapStep }

    // MARK: Variables (vars.ts)

    func loadVariables() {
        let src = (try? project.readFile(path: "vars.ts", agentView: false)) ?? ""
        let re = try! NSRegularExpression(pattern: #"export\s+const\s+(\w+)\s*=\s*(-?[\d.]+)"#)
        variables = re.matches(in: src, range: NSRange(src.startIndex..., in: src)).compactMap { m in
            guard let n = Range(m.range(at: 1), in: src), let v = Range(m.range(at: 2), in: src) else { return nil }
            return DesignVariable(name: String(src[n]), value: String(src[v]), unit: "mm")
        }
    }

    func setVariable(_ name: String, to value: String) async {
        guard Double(value) != nil else { show("\(name) must be a number", isError: true); return }
        var src = text(of: "vars.ts", agentView: false)
        let re = try! NSRegularExpression(pattern: #"(export\s+const\s+\#(name)\s*=\s*)(-?[\d.]+)"#)
        src = re.stringByReplacingMatches(in: src, range: NSRange(src.startIndex..., in: src), withTemplate: "$1\(value)")
        let before = snapshotFiles(["vars.ts"])
        lastOwnWrite = Date()
        try? project.writeFile(path: "vars.ts", content: src)
        loadVariables()
        editorRevision += 1
        if await compileNow() {
            pushUndo(UndoEntry(label: "Set \(name)", files: before))
            noteTouchEdit("set \(name)")
        } else {
            restore(before)
            loadVariables()
            await compileNow()
            show("Reverted \(name): \(compileErrors.first?.message ?? "compile failed")", isError: true)
        }
    }

    /// Evaluate a number-field expression with project variables (`boardW / 2 - 3`).
    func evaluate(_ expr: String) -> Double? {
        var e = expr.trimmingCharacters(in: .whitespaces)
        for v in variables.sorted(by: { $0.name.count > $1.name.count }) { e = e.replacingOccurrences(of: v.name, with: v.value) }
        guard e.range(of: #"^[\d.\s+\-*/()]+$"#, options: .regularExpression) != nil else { return nil }
        let ex = NSExpression(format: e.replacingOccurrences(of: "/", with: "*1.0/"))
        return (ex.expressionValue(with: nil, context: nil) as? NSNumber)?.doubleValue
    }

    // MARK: Undo

    private func snapshotFiles(_ paths: [String]) -> [String: String?] {
        var out: [String: String?] = [:]
        for p in Set(paths) { out[p] = try? project.readFile(path: p, agentView: false) }
        return out
    }

    private func restore(_ snap: [String: String?]) {
        lastOwnWrite = Date()
        for (p, c) in snap {
            if let c { try? project.writeFile(path: p, content: c) } else { try? project.deleteFile(path: p) }
        }
        refreshFiles()
        loadVariables()
    }

    private func pushUndo(_ e: UndoEntry) {
        undoStack.append(e)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack = []
    }

    func undo() async {
        guard let e = undoStack.popLast() else { return }
        let now = snapshotFiles(Array(e.files.keys))
        restore(e.files)
        redoStack.append(UndoEntry(label: e.label, files: now))
        editorRevision += 1
        noteTouchEdit("undo \(e.label)")
        await compileNow()
    }

    func redo() async {
        guard let e = redoStack.popLast() else { return }
        let now = snapshotFiles(Array(e.files.keys))
        restore(e.files)
        undoStack.append(UndoEntry(label: e.label, files: now))
        editorRevision += 1
        noteTouchEdit("redo \(e.label)")
        await compileNow()
    }

    // MARK: Git

    func refreshGit() {
        branch = project.currentBranch()
        pendingChange = project.pendingChange()
        history = (try? project.history(limit: 60)) ?? []
    }

    func refreshPending() {
        pendingChange = project.pendingChange()
        branch = project.currentBranch()
    }

    func acceptAgentChange(summary: String, request: String) async {
        flushTouchCommit()
        let paths = pendingChange?.files.map(\.path) ?? []
        let before = snapshotFiles(paths)
        let title = request.split(separator: "\n").first.map { "Agent: " + $0.prefix(68) } ?? "Agent change"
        let msg = summary.isEmpty ? String(title) : "\(title)\n\n\(summary)"
        do {
            lastOwnWrite = Date()
            _ = try project.acceptChange(message: msg)
            pushUndo(UndoEntry(label: "Accept agent change", files: before))
        } catch { show(error) }
        refreshGit()
        refreshFiles()
        editorRevision += 1
        await compileNow()
    }

    func discardAgentChange() async {
        try? project.discardChange()
        refreshGit()
        refreshFiles()
        editorRevision += 1
        await compileNow()
    }

    func restore(commit: CommitInfo, path: String?) async {
        flushTouchCommit()
        lastOwnWrite = Date()
        do {
            if let path {
                try project.restoreFile(id: commit.id, path: path)
                _ = try project.commitAll(message: "Restore \(path) from \(commit.short)")
            } else {
                _ = try project.restoreAll(id: commit.id)
            }
        } catch { show(error) }
        refreshGit()
        refreshFiles()
        loadVariables()
        editorRevision += 1
        await compileNow()
    }

    func branch(from commit: CommitInfo, name: String) {
        do {
            try project.createBranch(name: name, id: commit.id)
            show("Created branch \(name) at \(commit.short)", isError: false)
        } catch { show(error) }
    }

    // MARK: Export

    enum ExportError: LocalizedError {
        case drcErrors(Int), notCompiled
        var errorDescription: String? {
            switch self {
            case .drcErrors(let n): "Export is blocked: DRC has \(n) error\(n == 1 ? "" : "s"). Fix them (or ask the agent) and try again."
            case .notCompiled: "Nothing compiled yet."
            }
        }
    }

    /// One ZIP per board revision: `<project>-<short commit>.zip` with Gerbers, drill, BOM and PnP.
    func buildFabZip(formats: [String] = ["gerber", "drill", "bom", "pnp"], allowWarnings: Bool) async throws -> URL {
        guard !circuitJSON.isEmpty else { throw ExportError.notCompiled }
        await runDRC()
        if drcErrors > 0 { throw ExportError.drcErrors(drcErrors) }
        let files = try await EngineBridge.shared.export(circuitJSON: circuitJSON, formats: formats)
        let short = history.first?.short ?? "nogit"
        let dirty = uncommitted.isEmpty ? "" : "-dirty"
        let zipName = "\(name)-\(short)\(dirty).zip"
        let entries = files.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("traceworks-export", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent(zipName)
        try ZipWriter.zip(entries).write(to: out)
        return out
    }

    // MARK: Banner

    func show(_ error: Error) { show(error.localizedDescription, isError: true) }

    func show(_ text: String, isError: Bool) {
        let b = Banner(text: text, isError: isError)
        banner = b
        Task {
            try? await Task.sleep(for: .seconds(isError ? 6 : 3))
            if banner == b { banner = nil }
        }
    }
}

func jsonString(_ s: String) -> String {
    String(decoding: (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8), as: UTF8.self).dropFirst().dropLast().description
}

/// Watches the project folder for edits from the CLI, iCloud or another editor.
final class FolderWatcher: @unchecked Sendable {
    private var source: DispatchSourceFileSystemObject?
    private var timer: DispatchSourceTimer?
    private var lastStamp: Date = .distantPast
    private let url: URL
    private let onChange: @Sendable () -> Void

    init(url: URL, onChange: @escaping @Sendable () -> Void) {
        self.url = url
        self.onChange = onChange
        lastStamp = stamp()
        // A directory vnode only reports entry changes; poll modification dates too (cheap: a few files).
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let s = self.stamp()
            if s > self.lastStamp {
                self.lastStamp = s
                self.onChange()
            }
        }
        t.resume()
        timer = t
    }

    private func stamp() -> Date {
        var newest = Date.distantPast
        let fm = FileManager.default
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return newest }
        for case let f as URL in e {
            if f.path.contains("/node_modules") { e.skipDescendants(); continue }
            let ext = f.pathExtension
            guard ["tsx", "ts", "json"].contains(ext) else { continue }
            if let d = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, d > newest { newest = d }
        }
        return newest
    }

    func stop() { timer?.cancel(); source?.cancel() }
}
