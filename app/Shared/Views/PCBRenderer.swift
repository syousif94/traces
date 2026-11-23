import SwiftUI

/// Board ↔ screen mapping. Board space is mm with +y up; screen is points with +y down.
struct ViewTransform: Equatable {
    var center: CGPoint = .zero
    var scale: CGFloat = 10  // points per mm
    var size: CGSize = .zero

    func toScreen(_ p: CGPoint) -> CGPoint {
        CGPoint(x: size.width / 2 + (p.x - center.x) * scale, y: size.height / 2 - (p.y - center.y) * scale)
    }
    func toBoard(_ p: CGPoint) -> CGPoint {
        CGPoint(x: center.x + (p.x - size.width / 2) / scale, y: center.y - (p.y - size.height / 2) / scale)
    }
    func len(_ mm: CGFloat) -> CGFloat { mm * scale }

    static func fit(_ rect: CGRect, in size: CGSize, padding: CGFloat = 40) -> ViewTransform {
        guard rect.width > 0, rect.height > 0, size.width > 0, size.height > 0 else { return ViewTransform(size: size) }
        let s = min((size.width - padding * 2) / rect.width, (size.height - padding * 2) / rect.height)
        return ViewTransform(center: CGPoint(x: rect.midX, y: rect.midY), scale: max(0.5, s), size: size)
    }

    /// Grid step in mm for the zoom: 0.1 / 0.5 / 1 / 5 / 10.
    var gridStep: CGFloat {
        for s: CGFloat in [0.1, 0.5, 1, 5, 10] where s * scale >= 14 { return s }
        return 10
    }
}

struct PCBOverlay {
    var selection: String?
    var highlight: Set<String> = []
    var ghost: (name: String, offset: CGPoint)?
    var measure: (CGPoint, CGPoint?)?
    var routeFrom: CGPoint?
    var drcMarkers: [(CGPoint, Bool)] = []
}

enum PCBRenderer {
    static func draw(_ ctx: inout GraphicsContext, model m: CircuitModel, t: ViewTransform, layers: [PCBLayer: Bool], opacity: [PCBLayer: Double] = [:],
                     overlay o: PCBOverlay, showGrid: Bool = true) {
        let vis = { (l: PCBLayer) in layers[l] ?? true }
        let op = { (l: PCBLayer) in opacity[l] ?? 1 }
        let ghostComp = o.ghost.flatMap { g in m.component(named: g.name).map { ($0, g.offset) } }
        // Elements of the dragged component are drawn shifted (the ghost) using cached geometry.
        func shift(_ p: CGPoint, _ comp: String?) -> CGPoint {
            guard let (gc, off) = ghostComp, let comp, comp == gc.pcbId else { return p }
            return CGPoint(x: p.x + off.x, y: p.y + off.y)
        }

        if showGrid { drawGrid(&ctx, t: t) }

        // Board
        let bRect = CGRect(x: m.boardCenter.x - m.boardSize.width / 2, y: m.boardCenter.y + m.boardSize.height / 2, width: m.boardSize.width, height: m.boardSize.height)
        let boardPath: Path
        if m.boardOutline.count > 2 {
            var p = Path()
            p.addLines(m.boardOutline.map(t.toScreen))
            p.closeSubpath()
            boardPath = p
        } else {
            let tl = t.toScreen(CGPoint(x: bRect.minX, y: bRect.minY))
            boardPath = Path(roundedRect: CGRect(x: tl.x, y: tl.y, width: t.len(bRect.width), height: t.len(bRect.height)), cornerRadius: t.len(1.2), style: .continuous)
        }
        ctx.fill(boardPath, with: .color(Theme.board))
        ctx.stroke(boardPath, with: .color(Theme.boardEdge.opacity(0.9)), lineWidth: max(1, t.len(0.15)))

        // Copper: bottom first, then top.
        for layer in [CircuitModel.Layer.bottom, .top] {
            let pl: PCBLayer = layer == .top ? .topCopper : .bottomCopper
            guard vis(pl) else { continue }
            let color = (layer == .top ? Theme.copperTop : Theme.copperBottom).opacity((layer == .bottom ? 0.85 : 1) * op(pl))
            for s in m.traces where s.layer == layer {
                var p = Path()
                p.move(to: t.toScreen(s.a)); p.addLine(to: t.toScreen(s.b))
                ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: max(1, t.len(s.width)), lineCap: .round, lineJoin: .round))
            }
        }
        // Component bodies (chips) under pads.
        for c in m.components where c.ftype == "simple_chip" {
            var center = c.center
            if let (gc, off) = ghostComp, gc.name == c.name { center = CGPoint(x: center.x + off.x, y: center.y + off.y) }
            let w = max(c.size.width * 0.42, c.size.width - 1.4), h = max(c.size.height * 0.42, c.size.height - 1.4)
            let r = screenRect(center: center, size: CGSize(width: w, height: h), t: t)
            let body = Path(roundedRect: r, cornerRadius: t.len(0.3), style: .continuous)
            ctx.fill(body, with: .color(Color(hex: 0x3B4252).opacity(c.layer == .bottom ? 0.4 : 0.95)))
            ctx.stroke(body, with: .color(Color(hex: 0x4C566A)), lineWidth: 1)
        }
        if vis(.pads) {
            for layer in [CircuitModel.Layer.bottom, .top] {
                let col = (layer == .top ? Theme.pad : Theme.copperBottom).opacity((layer == .bottom ? 0.7 : 1) * op(.pads))
                for pad in m.pads where pad.layer == layer {
                    let path = padPath(pad.shape, at: shift(pad.center, pad.componentId), t: t, shiftBy: shiftOffset(pad.componentId, ghostComp))
                    ctx.fill(path, with: .color(col))
                }
            }
            for h in m.platedHoles {
                let c = shift(h.center, h.componentId)
                ctx.fill(padPath(h.outer, at: c, t: t), with: .color(Theme.pad.opacity(op(.pads))))
                let d = t.len(h.holeDiameter)
                let sc = t.toScreen(c)
                ctx.fill(Path(ellipseIn: CGRect(x: sc.x - d / 2, y: sc.y - d / 2, width: d, height: d)), with: .color(Theme.hole))
            }
        }
        if vis(.vias) {
            for v in m.vias {
                let sc = t.toScreen(v.center)
                let d = max(3, t.len(v.outer)), hd = max(1.5, t.len(v.hole))
                ctx.fill(Path(ellipseIn: CGRect(x: sc.x - d / 2, y: sc.y - d / 2, width: d, height: d)), with: .color(Theme.pad.opacity(op(.vias))))
                ctx.fill(Path(ellipseIn: CGRect(x: sc.x - hd / 2, y: sc.y - hd / 2, width: hd, height: hd)), with: .color(Theme.hole))
            }
        }
        for h in m.holes {
            let sc = t.toScreen(h.center), d = t.len(h.diameter)
            let r = CGRect(x: sc.x - d / 2, y: sc.y - d / 2, width: d, height: d)
            ctx.fill(Path(ellipseIn: r), with: .color(Theme.hole))
            ctx.stroke(Path(ellipseIn: r.insetBy(dx: -1.5, dy: -1.5)), with: .color(Theme.pad), lineWidth: 1.5)
        }
        if vis(.silk) {
            let silk = Theme.silk.opacity(0.85 * op(.silk))
            for s in m.silkPaths where s.layer == .top && s.points.count > 1 {
                let off = shiftOffset(s.componentId, ghostComp)
                var p = Path()
                p.addLines(s.points.map { t.toScreen(CGPoint(x: $0.x + off.x, y: $0.y + off.y)) })
                ctx.stroke(p, with: .color(silk), style: StrokeStyle(lineWidth: max(0.75, t.len(s.width)), lineCap: .round, lineJoin: .round))
            }
            for tx in m.silkTexts where tx.layer == .top {
                let size = t.len(tx.size)
                guard size >= 4 else { continue }
                var c2 = ctx
                let sc = t.toScreen(tx.at)
                c2.translateBy(x: sc.x, y: sc.y)
                c2.rotate(by: .degrees(-tx.rotation))
                c2.draw(Text(tx.text).font(.system(size: size, weight: .medium, design: .monospaced)).foregroundStyle(silk), at: .zero, anchor: anchor(tx.anchor))
            }
        }
        if vis(.courtyard) {
            for cy in m.courtyards where cy.layer == .top {
                guard let comp = m.component(pcbId: cy.componentId ?? ""), comp.name == o.selection || o.highlight.contains(comp.name) else { continue }
                _ = comp
            }
        }
        // Ratsnest
        if vis(.ratsnest) {
            for r in m.ratsnest {
                var p = Path()
                p.move(to: t.toScreen(r.a)); p.addLine(to: t.toScreen(r.b))
                ctx.stroke(p, with: .color(Theme.warning.opacity(0.9 * op(.ratsnest))), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        // Selection and highlights: dashed accent outline (like the mockups).
        for c in m.components where c.name == o.selection || o.highlight.contains(c.name) {
            var center = c.center
            if let (gc, off) = ghostComp, gc.name == c.name { center = CGPoint(x: center.x + off.x, y: center.y + off.y) }
            let r = screenRect(center: center, size: CGSize(width: c.size.width + 0.8, height: c.size.height + 0.8), t: t)
            let path = Path(roundedRect: r, cornerRadius: 4, style: .continuous)
            ctx.stroke(path, with: .color(Palette.pcb.accent), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        }
        // DRC markers
        if vis(.drc) {
            for (p, isErr) in o.drcMarkers {
                let sc = t.toScreen(p)
                let r = CGRect(x: sc.x - 7, y: sc.y - 7, width: 14, height: 14)
                ctx.stroke(Path(ellipseIn: r), with: .color((isErr ? Theme.danger : Theme.warning).opacity(op(.drc))), lineWidth: 2)
            }
        }
        // Measure
        if let (a, b) = o.measure {
            let sa = t.toScreen(a)
            ctx.fill(Path(ellipseIn: CGRect(x: sa.x - 4, y: sa.y - 4, width: 8, height: 8)), with: .color(Palette.pcb.accent))
            if let b {
                let sb = t.toScreen(b)
                var p = Path(); p.move(to: sa); p.addLine(to: sb)
                ctx.stroke(p, with: .color(Palette.pcb.accent), style: StrokeStyle(lineWidth: 1.5, dash: [6, 3]))
                ctx.fill(Path(ellipseIn: CGRect(x: sb.x - 4, y: sb.y - 4, width: 8, height: 8)), with: .color(Palette.pcb.accent))
            }
        }
        if let r = o.routeFrom {
            let s = t.toScreen(r)
            ctx.stroke(Path(ellipseIn: CGRect(x: s.x - 9, y: s.y - 9, width: 18, height: 18)), with: .color(Palette.pcb.accent), lineWidth: 2)
        }
    }

    static func shiftOffset(_ comp: String?, _ ghost: (CircuitModel.Component, CGPoint)?) -> CGPoint {
        guard let (gc, off) = ghost, let comp, comp == gc.pcbId else { return .zero }
        return off
    }

    static func anchor(_ a: String) -> UnitPoint {
        switch a {
        case "center_left", "left": .leading
        case "center_right", "right": .trailing
        case "top_left": .topLeading
        case "top_right": .topTrailing
        case "bottom_left": .bottomLeading
        case "bottom_right": .bottomTrailing
        default: .center
        }
    }

    static func screenRect(center: CGPoint, size: CGSize, t: ViewTransform) -> CGRect {
        let c = t.toScreen(center)
        let w = t.len(size.width), h = t.len(size.height)
        return CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
    }

    static func padPath(_ shape: CircuitModel.PadShape, at c: CGPoint, t: ViewTransform, shiftBy: CGPoint = .zero) -> Path {
        switch shape {
        case .circle(let r):
            let sc = t.toScreen(c), d = t.len(r * 2)
            return Path(ellipseIn: CGRect(x: sc.x - d / 2, y: sc.y - d / 2, width: d, height: d))
        case .rect(let size, let rot, let radius):
            let r = screenRect(center: c, size: size, t: t)
            var p = Path(roundedRect: r, cornerRadius: t.len(radius))
            if rot != 0 {
                let sc = t.toScreen(c)
                p = p.applying(CGAffineTransform(translationX: -sc.x, y: -sc.y).concatenating(CGAffineTransform(rotationAngle: -rot * .pi / 180)).concatenating(CGAffineTransform(translationX: sc.x, y: sc.y)))
            }
            return p
        case .pill(let size, let rot):
            let r = screenRect(center: c, size: size, t: t)
            var p = Path(roundedRect: r, cornerRadius: min(r.width, r.height) / 2)
            if rot != 0 {
                let sc = t.toScreen(c)
                p = p.applying(CGAffineTransform(translationX: -sc.x, y: -sc.y).concatenating(CGAffineTransform(rotationAngle: -rot * .pi / 180)).concatenating(CGAffineTransform(translationX: sc.x, y: sc.y)))
            }
            return p
        case .polygon(let pts):
            var p = Path()
            p.addLines(pts.map { t.toScreen(CGPoint(x: $0.x + shiftBy.x, y: $0.y + shiftBy.y)) })
            p.closeSubpath()
            return p
        }
    }

    static func drawGrid(_ ctx: inout GraphicsContext, t: ViewTransform) {
        let step = t.gridStep
        let tl = t.toBoard(.zero), br = t.toBoard(CGPoint(x: t.size.width, y: t.size.height))
        let x0 = (min(tl.x, br.x) / step).rounded(.down) * step, x1 = max(tl.x, br.x)
        let y0 = (min(tl.y, br.y) / step).rounded(.down) * step, y1 = max(tl.y, br.y)
        guard (x1 - x0) / step < 400, (y1 - y0) / step < 400 else { return }
        var dots = Path()
        var x = x0
        while x <= x1 {
            var y = y0
            while y <= y1 {
                let s = t.toScreen(CGPoint(x: x, y: y))
                dots.addRect(CGRect(x: s.x - 0.75, y: s.y - 0.75, width: 1.5, height: 1.5))
                y += step
            }
            x += step
        }
        ctx.fill(dots, with: .color(Palette.pcb.grid))
    }
}

/// Off-screen renders for the agent (render_snapshot) and sharing.
enum Snapshot {
    @MainActor
    static func png(model: CircuitModel, view: String, highlight: [String], layers: [PCBLayer: Bool], size: CGSize = CGSize(width: 1200, height: 860)) -> Data? {
        guard !model.isEmpty else { return nil }
        let content: AnyView
        if view == "schematic" {
            let t = ViewTransform.fit(model.schBounds, in: size, padding: 40)
            content = AnyView(Canvas { ctx, _ in
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Palette.schematic.canvas))
                SchematicRenderer.draw(&ctx, model: model, t: t, selection: nil, highlight: Set(highlight))
            }.frame(width: size.width, height: size.height).environment(\.colorScheme, .light))
        } else {
            let t = ViewTransform.fit(model.pcbBounds, in: size, padding: 40)
            content = AnyView(Canvas { ctx, _ in
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Palette.pcb.canvas))
                PCBRenderer.draw(&ctx, model: model, t: t, layers: layers, overlay: PCBOverlay(highlight: Set(highlight)), showGrid: false)
                // Label every component so the model can refer to designators.
                for c in model.components {
                    let p = t.toScreen(CGPoint(x: c.center.x, y: c.center.y + c.size.height / 2 + 0.6))
                    ctx.draw(Text(c.name).font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(Color(hex: 0xEBCB8B)), at: p)
                }
            }.frame(width: size.width, height: size.height).environment(\.colorScheme, .dark))
        }
        let r = ImageRenderer(content: content)
        r.scale = 1
        guard let cg = r.cgImage else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
