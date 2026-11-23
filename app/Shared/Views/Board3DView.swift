import RealityKit
import SwiftUI

/// 3D board: extruded board, pads and copper as thin slabs, component bodies as boxes with a height
/// fallback (no bundled GLB models yet). Orbit with drag/pinch.
struct Board3DView: View {
    @Bindable var doc: DocumentModel

    var body: some View {
        RealityView { content in
            content.add(Self.makeBoard(doc.circuit))
        } update: { content in
            content.entities.removeAll()
            content.add(Self.makeBoard(doc.circuit))
        }
        .realityViewCameraControls(.orbit)
        .background(Palette.threeD.canvas)
        .accessibilityLabel("3D board view")
    }

    @MainActor
    static func makeBoard(_ m: CircuitModel) -> Entity {
        let root = Entity()
        let s: Float = 0.01  // 1 mm → 1 cm so the default camera frames it
        let th = Float(m.boardThickness) * s
        func mat(_ hex: UInt32, rough: Float = 0.6, metal: Bool = false) -> SimpleMaterial {
            var mm = SimpleMaterial()
            mm.color = .init(tint: platformColor(hex))
            mm.roughness = .float(rough)
            mm.metallic = .float(metal ? 0.8 : 0)
            return mm
        }
        let board = ModelEntity(mesh: .generateBox(width: Float(m.boardSize.width) * s, height: th, depth: Float(m.boardSize.height) * s, cornerRadius: 0.4 * s),
                                materials: [mat(0x2B3A33, rough: 0.8)])
        board.position = [Float(m.boardCenter.x) * s, 0, -Float(m.boardCenter.y) * s]
        root.addChild(board)
        let top = th / 2
        for p in m.pads {
            guard case .rect(let size, _, _) = p.shape else { continue }
            let e = ModelEntity(mesh: .generateBox(width: Float(size.width) * s, height: 0.04 * s, depth: Float(size.height) * s), materials: [mat(0xE5C07B, rough: 0.3, metal: true)])
            e.position = [Float(p.center.x) * s, p.layer == .top ? top + 0.02 * s : -top - 0.02 * s, -Float(p.center.y) * s]
            root.addChild(e)
        }
        for seg in m.traces {
            let dx = Float(seg.b.x - seg.a.x), dy = Float(seg.b.y - seg.a.y)
            let len = (dx * dx + dy * dy).squareRoot()
            guard len > 0.001 else { continue }
            let e = ModelEntity(mesh: .generateBox(width: len * s, height: 0.035 * s, depth: Float(seg.width) * s),
                                materials: [mat(seg.layer == .top ? 0xD08770 : 0x81A1C1, rough: 0.4, metal: true)])
            e.position = [Float(seg.a.x + seg.b.x) / 2 * s, seg.layer == .top ? top + 0.018 * s : -top - 0.018 * s, -Float(seg.a.y + seg.b.y) / 2 * s]
            e.orientation = simd_quatf(angle: atan2(dy, dx), axis: [0, 1, 0])
            root.addChild(e)
        }
        for c in m.components {
            let h = Float(c.height3D)
            let w = Float(c.ftype == "simple_chip" ? max(c.size.width * 0.42, c.size.width - 1.4) : c.size.width * 0.55)
            let d = Float(c.ftype == "simple_chip" ? max(c.size.height * 0.42, c.size.height - 1.4) : c.size.height * 0.55)
            let color: UInt32 = c.ftype == "simple_led" ? (c.value?.contains("blue") == true ? 0x81A1C1 : 0xA3BE8C) : c.ftype == "simple_chip" ? 0x2E3440 : 0xD8C9A8
            let e = ModelEntity(mesh: .generateBox(width: w * s, height: h * s, depth: d * s, cornerRadius: 0.1 * s), materials: [mat(color, rough: 0.5)])
            let y = c.layer == .top ? top + h * s / 2 : -top - h * s / 2
            e.position = [Float(c.center.x) * s, y, -Float(c.center.y) * s]
            root.addChild(e)
        }
        return root
    }

    static func platformColor(_ hex: UInt32) -> PlatformColor { PlatformColor(hex: hex) }
}

#if os(macOS)
typealias PlatformColor = NSColor
#else
typealias PlatformColor = UIColor
#endif
