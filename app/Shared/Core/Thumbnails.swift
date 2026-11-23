import CryptoKit
import Foundation
import SceneKit
import SwiftUI

/// 3D pictures of boards for the start page, rendered offscreen (SceneKit) from the compiled
/// circuit after each compile that changed it. Kept in Application Support/Thumbnails, keyed by
/// the project folder's path. Projects never opened here are compiled in the background once.
@MainActor
enum Thumbnails {
    static let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Traces/Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static func url(for project: URL) -> URL {
        // Boards in the app's Documents are keyed by their path inside it: the container's own
        // path changes when the app is reinstalled or updated.
        var key = project.standardizedFileURL.path
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.standardizedFileURL.path,
           key.hasPrefix(docs + "/") { key = "docs:" + key.dropFirst(docs.count + 1) }
        let h = SHA256.hash(data: Data(key.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent("\(project.lastPathComponent)-\(h).png")
    }

    static func exists(for project: URL) -> Bool { FileManager.default.fileExists(atPath: url(for: project).path) }

    static func image(for project: URL) -> Image? {
        #if os(macOS)
        NSImage(contentsOf: url(for: project)).map { Image(nsImage: $0) }
        #else
        UIImage(contentsOfFile: url(for: project).path).map { Image(uiImage: $0) }
        #endif
    }

    static func save(_ model: CircuitModel, for project: URL) {
        guard !model.isEmpty, model.boardSize.width > 0 else { return }
        let (scene, camera) = scene(for: model)
        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = scene
        renderer.pointOfView = camera
        renderer.autoenablesDefaultLighting = false
        let img = renderer.snapshot(atTime: 0, with: CGSize(width: 480, height: 360), antialiasingMode: .multisampling4X)
        #if os(macOS)
        guard let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        #else
        guard let png = img.pngData() else { return }
        #endif
        try? png.write(to: url(for: project), options: .atomic)
    }

    /// Board, copper, pads and component bodies in mm, board centre at the origin, +y up the board.
    static func scene(for m: CircuitModel) -> (SCNScene, SCNNode) {
        let scene = SCNScene()
        scene.background.contents = PlatformColor.clear
        let root = SCNNode()
        scene.rootNode.addChildNode(root)
        func material(_ hex: UInt32, metal: Bool = false) -> SCNMaterial {
            let mat = SCNMaterial()
            mat.lightingModel = .physicallyBased
            mat.diffuse.contents = PlatformColor(hex: hex)
            mat.roughness.contents = metal ? 0.35 : 0.7
            mat.metalness.contents = metal ? 0.7 : 0
            return mat
        }
        func box(_ w: CGFloat, _ h: CGFloat, _ d: CGFloat, _ mat: SCNMaterial, at p: SCNVector3, chamfer: CGFloat = 0) -> SCNNode {
            let b = SCNBox(width: w, height: h, length: d, chamferRadius: chamfer)
            b.materials = [mat]
            let n = SCNNode(geometry: b)
            n.position = p
            return n
        }
        let c = m.boardCenter
        let th = CGFloat(m.boardThickness)
        let top = th / 2
        func at(_ p: CGPoint, _ y: CGFloat) -> SCNVector3 { vec(p.x - c.x, y, -(p.y - c.y)) }
        root.addChildNode(box(m.boardSize.width, th, m.boardSize.height, material(0x2B3A33), at: vec(0, 0, 0), chamfer: 0.4))
        let copper = material(0xD08770, metal: true), copperB = material(0x81A1C1, metal: true), padMat = material(0xE5C07B, metal: true)
        for s in m.traces {
            let dx = s.b.x - s.a.x, dy = s.b.y - s.a.y
            let len = (dx * dx + dy * dy).squareRoot()
            guard len > 0.001 else { continue }
            let mid = CGPoint(x: (s.a.x + s.b.x) / 2, y: (s.a.y + s.b.y) / 2)
            let n = box(len, 0.035, s.width, s.layer == .top ? copper : copperB, at: at(mid, s.layer == .top ? top + 0.02 : -top - 0.02))
            n.eulerAngles = vec(0, atan2(dy, dx), 0)
            root.addChildNode(n)
        }
        for p in m.pads {
            let size: CGSize
            switch p.shape {
            case .rect(let s, _, _), .pill(let s, _): size = s
            case .circle(let r): size = CGSize(width: r * 2, height: r * 2)
            case .polygon: continue
            }
            root.addChildNode(box(size.width, 0.04, size.height, padMat, at: at(p.center, p.layer == .top ? top + 0.025 : -top - 0.025)))
        }
        for comp in m.components {
            let h = CGFloat(comp.height3D)
            let chip = comp.ftype == "simple_chip"
            let w = chip ? max(comp.size.width * 0.42, comp.size.width - 1.4) : comp.size.width * 0.55
            let d = chip ? max(comp.size.height * 0.42, comp.size.height - 1.4) : comp.size.height * 0.55
            let color: UInt32 = comp.ftype == "simple_led" ? (comp.value?.contains("blue") == true ? 0x81A1C1 : 0xA3BE8C) : chip ? 0x2E3440 : 0xD8C9A8
            let y = comp.layer == .top ? top + h / 2 : -top - h / 2
            let n = box(max(w, 0.3), max(h, 0.2), max(d, 0.3), material(color), at: at(comp.center, y), chamfer: 0.1)
            n.eulerAngles = vec(0, CGFloat(comp.rotation * .pi / 180), 0)
            root.addChildNode(n)
        }

        // Three-quarter view from the front right, framing the board.
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 30
        let span = max(m.boardSize.width, m.boardSize.height * 1.2, 10)
        let dist = span / 2 / tan(15 * .pi / 180) * 0.9
        camera.camera?.zNear = Double(dist) * 0.05
        camera.camera?.zFar = Double(dist) * 4
        camera.position = vec(dist * 0.42, dist * 0.68, dist * 0.6)
        camera.look(at: vec(0, 0, 0))
        scene.rootNode.addChildNode(camera)
        let light = SCNNode()
        light.light = SCNLight()
        light.light?.type = .directional
        light.light?.intensity = 1100
        light.eulerAngles = vec(-0.9, 0.5, 0)
        camera.addChildNode(light)
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 450
        scene.rootNode.addChildNode(ambient)
        return (scene, camera)
    }

    private static func vec(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> SCNVector3 {
        #if os(macOS)
        SCNVector3(x, y, z)
        #else
        SCNVector3(Float(x), Float(y), Float(z))
        #endif
    }

    /// Compile projects that have no picture yet (one at a time, after the engine is up).
    static func fillMissing(_ projects: [URL], onEach: @escaping @MainActor () -> Void) async {
        await EngineBridge.shared.waitUntilReady()
        for u in projects where !exists(for: u) {
            guard !Task.isCancelled, let project = try? Project.open(path: u.path) else { continue }
            guard let r = try? await EngineBridge.shared.compile(filesJSON: project.fileMapJson(agentView: false), entry: project.entryPath(), autoroute: true) else { continue }
            let data = r.circuitJSON
            let model = await Task.detached { CircuitModel.decode(data) }.value
            save(model, for: u)
            onEach()
        }
    }
}
