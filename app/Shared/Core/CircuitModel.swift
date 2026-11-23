import CoreGraphics
import Foundation

/// Circuit JSON decoded once per compile and indexed for the renderers. Decoding is lenient:
/// unknown element types are counted (and logged) but never fail the decode.
struct CircuitModel: Sendable {
    enum Layer: String, Sendable { case top, bottom }

    struct Component: Sendable, Identifiable {
        var id: String { name }
        var name: String
        var ftype: String
        var mpn: String?
        var value: String?
        var footprint: String?
        var supplierPart: String?
        var pcbId: String?
        var center: CGPoint
        var size: CGSize
        var rotation: Double
        var layer: Layer
        var groupCenter: CGPoint
        var schCenter: CGPoint?
        var schSize: CGSize?
        var symbol: String?
        var height3D: Double
        var displayPart: String {
            if let mpn, !mpn.isEmpty { return mpn }
            var parts: [String] = []
            if let value { parts.append(value) }
            if let footprint { parts.append(footprint) }
            return parts.isEmpty ? ftype.replacingOccurrences(of: "simple_", with: "") : parts.joined(separator: " ")
        }
    }

    enum PadShape: Sendable {
        case rect(CGSize, rotation: Double, radius: CGFloat)
        case circle(CGFloat)
        case pill(CGSize, rotation: Double)
        case polygon([CGPoint])
    }

    struct Pad: Sendable {
        var center: CGPoint
        var shape: PadShape
        var layer: Layer
        var componentId: String?
        var portId: String?
    }

    struct PlatedHole: Sendable {
        var center: CGPoint
        var outer: PadShape
        var holeDiameter: CGFloat
        var componentId: String?
    }

    struct Via: Sendable { var center: CGPoint; var outer: CGFloat; var hole: CGFloat }
    struct Hole: Sendable { var center: CGPoint; var diameter: CGFloat }
    struct Segment: Sendable { var a: CGPoint; var b: CGPoint; var width: CGFloat; var layer: Layer }
    struct Polyline: Sendable { var points: [CGPoint]; var width: CGFloat; var layer: Layer; var componentId: String? }
    struct Text: Sendable { var text: String; var at: CGPoint; var size: CGFloat; var rotation: Double; var layer: Layer; var anchor: String }
    struct RectShape: Sendable { var center: CGPoint; var size: CGSize; var rotation: Double; var layer: Layer; var componentId: String? }
    struct Ratline: Sendable { var a: CGPoint; var b: CGPoint }
    struct SchPort: Sendable { var at: CGPoint; var label: String?; var side: String?; var componentId: String? }
    struct SchLabel: Sendable { var text: String; var at: CGPoint; var side: String }
    struct SchText: Sendable { var text: String; var at: CGPoint; var size: CGFloat; var anchor: String }

    var boardCenter = CGPoint.zero
    var boardSize = CGSize(width: 50, height: 40)
    var boardOutline: [CGPoint] = []
    var boardThickness = 1.6
    var components: [Component] = []
    var pads: [Pad] = []
    var platedHoles: [PlatedHole] = []
    var vias: [Via] = []
    var holes: [Hole] = []
    var traces: [Segment] = []
    var silkPaths: [Polyline] = []
    var silkTexts: [Text] = []
    var courtyards: [RectShape] = []
    var ratsnest: [Ratline] = []
    var schComponents: [Component] { components.filter { $0.schCenter != nil } }
    var schPorts: [SchPort] = []
    var schWires: [Segment] = []
    var schJunctions: [CGPoint] = []
    var schLabels: [SchLabel] = []
    var schTexts: [SchText] = []
    var portPositions: [String: CGPoint] = [:]
    var elementCount = 0
    var unknownTypes: Set<String> = []

    var isEmpty: Bool { components.isEmpty && pads.isEmpty }

    func component(named n: String) -> Component? { components.first { $0.name == n } }
    func component(pcbId: String) -> Component? { components.first { $0.pcbId == pcbId } }

    /// Board-space bounds of everything drawn on the PCB.
    var pcbBounds: CGRect {
        CGRect(x: boardCenter.x - boardSize.width / 2, y: boardCenter.y - boardSize.height / 2, width: boardSize.width, height: boardSize.height)
    }

    var schBounds: CGRect {
        var r = CGRect.null
        for c in schComponents {
            guard let p = c.schCenter, let s = c.schSize else { continue }
            r = r.union(CGRect(x: p.x - s.width / 2, y: p.y - s.height / 2, width: s.width, height: s.height))
        }
        for w in schWires { r = r.union(CGRect(origin: w.a, size: .zero)).union(CGRect(origin: w.b, size: .zero)) }
        for l in schLabels { r = r.union(CGRect(x: l.at.x - 0.5, y: l.at.y - 0.3, width: 1, height: 0.6)) }
        return r.isNull ? CGRect(x: -5, y: -5, width: 10, height: 10) : r.insetBy(dx: -1, dy: -1)
    }

    /// Topmost component whose footprint contains `p` (board mm), preferring the given layer.
    func hitTest(_ p: CGPoint, layer: Layer = .top, slop: CGFloat = 0.4) -> Component? {
        let hits = components.filter { c in
            let w = c.size.width + slop * 2, h = c.size.height + slop * 2
            return abs(p.x - c.center.x) <= w / 2 && abs(p.y - c.center.y) <= h / 2
        }
        return hits.sorted { a, b in
            if a.layer != b.layer { return a.layer == layer }
            return a.size.width * a.size.height < b.size.width * b.size.height
        }.first
    }

    func schHitTest(_ p: CGPoint) -> Component? {
        schComponents.first { c in
            guard let cc = c.schCenter, let s = c.schSize else { return false }
            return abs(p.x - cc.x) <= s.width / 2 + 0.2 && abs(p.y - cc.y) <= s.height / 2 + 0.2
        }
    }

    // MARK: Decode

    static func decode(_ data: Data) -> CircuitModel {
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return CircuitModel() }
        return CircuitModel(elements: arr)
    }

    init() {}

    init(elements arr: [[String: Any]]) {
        elementCount = arr.count
        func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue ?? (v as? String).flatMap { Double($0.replacingOccurrences(of: "mm", with: "")) } }
        func pt(_ v: Any?) -> CGPoint? {
            guard let d = v as? [String: Any], let x = num(d["x"]), let y = num(d["y"]) else { return nil }
            return CGPoint(x: x, y: y)
        }
        func xy(_ e: [String: Any]) -> CGPoint { CGPoint(x: num(e["x"]) ?? 0, y: num(e["y"]) ?? 0) }
        func layer(_ v: Any?) -> Layer { (v as? String) == "bottom" ? .bottom : .top }
        func str(_ v: Any?) -> String? { v as? String }

        var byType: [String: [[String: Any]]] = [:]
        for e in arr { byType[str(e["type"]) ?? "", default: []].append(e) }

        let sources = Dictionary((byType["source_component"] ?? []).compactMap { e in str(e["source_component_id"]).map { ($0, e) } }, uniquingKeysWith: { a, _ in a })
        let groups = Dictionary((byType["pcb_group"] ?? []).compactMap { e in str(e["pcb_group_id"]).map { ($0, e) } }, uniquingKeysWith: { a, _ in a })
        let schBySource = Dictionary((byType["schematic_component"] ?? []).compactMap { e in str(e["source_component_id"]).map { ($0, e) } }, uniquingKeysWith: { a, _ in a })
        let cadBySource = Dictionary((byType["cad_component"] ?? []).compactMap { e in str(e["source_component_id"]).map { ($0, e) } }, uniquingKeysWith: { a, _ in a })

        if let b = byType["pcb_board"]?.first {
            boardCenter = pt(b["center"]) ?? .zero
            boardSize = CGSize(width: num(b["width"]) ?? 50, height: num(b["height"]) ?? 40)
            boardThickness = num(b["thickness"]) ?? 1.6
            if let outline = b["outline"] as? [[String: Any]] { boardOutline = outline.map { xy($0) } }
        }

        for p in byType["pcb_component"] ?? [] {
            guard let sid = str(p["source_component_id"]), let s = sources[sid], let name = str(s["name"]) else { continue }
            var gc = CGPoint.zero
            if let gid = str(p["pcb_group_id"]), let g = groups[gid] { gc = pt(g["anchor_position"]) ?? pt(g["center"]) ?? .zero }
            let sch = schBySource[sid]
            let cad = cadBySource[sid]
            let ftype = str(s["ftype"]) ?? ""
            let value = str(s["display_value"]) ?? str(s["display_resistance"]) ?? str(s["display_capacitance"]) ?? str(s["display_inductance"]) ?? str(s["color"]).map { "LED \($0)" }
            var supplier: String?
            if let sp = s["supplier_part_numbers"] as? [String: [String]], let j = sp["jlcpcb"]?.first { supplier = j }
            let size = CGSize(width: num(p["width"]) ?? 1, height: num(p["height"]) ?? 1)
            let h3: Double = switch ftype {
            case "simple_chip": max(1.2, min(3.2, Double(min(size.width, size.height)) * 0.35))
            case "simple_capacitor", "simple_resistor": 0.5
            case "simple_led": 0.8
            default: 1.0
            }
            components.append(Component(
                name: name, ftype: ftype, mpn: str(s["manufacturer_part_number"]), value: value,
                footprint: str(cad?["footprinter_string"]), supplierPart: supplier, pcbId: str(p["pcb_component_id"]),
                center: pt(p["center"]) ?? .zero, size: size, rotation: num(p["rotation"]) ?? 0, layer: layer(p["layer"]),
                groupCenter: gc, schCenter: pt(sch?["center"]),
                schSize: (sch?["size"] as? [String: Any]).map { CGSize(width: num($0["width"]) ?? 1, height: num($0["height"]) ?? 1) },
                symbol: str(sch?["symbol_name"]), height3D: h3))
        }
        components.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        for p in byType["pcb_smtpad"] ?? [] {
            let c = xy(p)
            let shape: PadShape
            switch str(p["shape"]) {
            case "circle": shape = .circle(CGFloat(num(p["radius"]) ?? 0.3))
            case "pill", "rotated_pill":
                shape = .pill(CGSize(width: num(p["width"]) ?? 0.6, height: num(p["height"]) ?? 0.6), rotation: num(p["ccw_rotation"]) ?? 0)
            case "polygon":
                shape = .polygon(((p["points"] as? [[String: Any]]) ?? []).map { xy($0) })
            default:
                shape = .rect(CGSize(width: num(p["width"]) ?? 0.6, height: num(p["height"]) ?? 0.6), rotation: num(p["ccw_rotation"]) ?? 0,
                              radius: CGFloat(num(p["rect_border_radius"]) ?? num(p["corner_radius"]) ?? 0))
            }
            pads.append(Pad(center: shape.isPolygon ? .zero : c, shape: shape, layer: layer(p["layer"]), componentId: str(p["pcb_component_id"]), portId: str(p["pcb_port_id"])))
        }
        for h in byType["pcb_plated_hole"] ?? [] {
            let hole = CGFloat(num(h["hole_diameter"]) ?? num(h["hole_width"]) ?? 0.8)
            let outer: PadShape
            switch str(h["shape"]) {
            case "circle": outer = .circle(CGFloat(num(h["outer_diameter"]) ?? Double(hole) * 1.6) / 2)
            case "pill", "oval":
                outer = .pill(CGSize(width: num(h["outer_width"]) ?? 1.5, height: num(h["outer_height"]) ?? 1), rotation: num(h["ccw_rotation"]) ?? 0)
            default:
                outer = .rect(CGSize(width: num(h["rect_pad_width"]) ?? 1.5, height: num(h["rect_pad_height"]) ?? 1.5), rotation: 0,
                              radius: CGFloat(num(h["rect_border_radius"]) ?? 0))
            }
            platedHoles.append(PlatedHole(center: xy(h), outer: outer, holeDiameter: hole, componentId: str(h["pcb_component_id"])))
        }
        for v in byType["pcb_via"] ?? [] {
            vias.append(Via(center: xy(v), outer: CGFloat(num(v["outer_diameter"]) ?? 0.6), hole: CGFloat(num(v["hole_diameter"]) ?? 0.3)))
        }
        for h in byType["pcb_hole"] ?? [] {
            holes.append(Hole(center: xy(h), diameter: CGFloat(num(h["hole_diameter"]) ?? num(h["hole_width"]) ?? 1)))
        }
        for t in byType["pcb_trace"] ?? [] {
            let route = (t["route"] as? [[String: Any]]) ?? []
            var prev: (CGPoint, Layer, CGFloat)?
            for r in route {
                guard str(r["route_type"]) == "wire" else { prev = nil; continue }
                let p = xy(r), l = layer(r["layer"]), w = CGFloat(num(r["width"]) ?? 0.15)
                if let (pp, pl, _) = prev, pl == l { traces.append(Segment(a: pp, b: p, width: w, layer: l)) }
                prev = (p, l, w)
            }
        }
        for s in byType["pcb_silkscreen_path"] ?? [] {
            let pts = ((s["route"] as? [[String: Any]]) ?? []).map { xy($0) }
            silkPaths.append(Polyline(points: pts, width: CGFloat(num(s["stroke_width"]) ?? 0.1), layer: layer(s["layer"]), componentId: str(s["pcb_component_id"])))
        }
        for s in byType["pcb_silkscreen_line"] ?? [] {
            let a = CGPoint(x: num(s["x1"]) ?? 0, y: num(s["y1"]) ?? 0), b = CGPoint(x: num(s["x2"]) ?? 0, y: num(s["y2"]) ?? 0)
            silkPaths.append(Polyline(points: [a, b], width: CGFloat(num(s["stroke_width"]) ?? 0.1), layer: layer(s["layer"]), componentId: str(s["pcb_component_id"])))
        }
        for s in byType["pcb_silkscreen_text"] ?? [] {
            guard let t = str(s["text"]), !t.isEmpty else { continue }
            silkTexts.append(Text(text: t, at: pt(s["anchor_position"]) ?? .zero, size: CGFloat(num(s["font_size"]) ?? 0.8),
                                  rotation: num(s["ccw_rotation"]) ?? 0, layer: layer(s["layer"]), anchor: str(s["anchor_alignment"]) ?? "center"))
        }
        for c in byType["pcb_courtyard_rect"] ?? [] {
            courtyards.append(RectShape(center: pt(c["center"]) ?? .zero, size: CGSize(width: num(c["width"]) ?? 0, height: num(c["height"]) ?? 0),
                                        rotation: num(c["ccw_rotation"]) ?? 0, layer: layer(c["layer"]), componentId: str(c["pcb_component_id"])))
        }
        for p in byType["pcb_port"] ?? [] {
            if let id = str(p["pcb_port_id"]) { portPositions[id] = xy(p) }
        }
        for e in byType["pcb_trace_missing_error"] ?? [] {
            let ids = (e["pcb_port_ids"] as? [String]) ?? []
            let pts = ids.compactMap { portPositions[$0] }
            for i in 1..<max(1, pts.count) { ratsnest.append(Ratline(a: pts[i - 1], b: pts[i])) }
        }

        // Schematic
        let schCompIdToName: [String: String] = Dictionary((byType["schematic_component"] ?? []).compactMap { e in
            guard let id = str(e["schematic_component_id"]), let sid = str(e["source_component_id"]), let n = str(sources[sid]?["name"]) else { return nil }
            return (id, n)
        }, uniquingKeysWith: { a, _ in a })
        for p in byType["schematic_port"] ?? [] {
            schPorts.append(SchPort(at: pt(p["center"]) ?? .zero, label: str(p["display_pin_label"]), side: str(p["side_of_component"]),
                                    componentId: str(p["schematic_component_id"]).flatMap { schCompIdToName[$0] }))
        }
        for t in byType["schematic_trace"] ?? [] {
            for e in (t["edges"] as? [[String: Any]]) ?? [] {
                if let a = pt(e["from"]), let b = pt(e["to"]) { schWires.append(Segment(a: a, b: b, width: 0.02, layer: .top)) }
            }
            for j in (t["junctions"] as? [[String: Any]]) ?? [] { schJunctions.append(xy(j)) }
        }
        for l in byType["schematic_net_label"] ?? [] {
            schLabels.append(SchLabel(text: str(l["text"]) ?? "", at: pt(l["anchor_position"]) ?? pt(l["center"]) ?? .zero, side: str(l["anchor_side"]) ?? "left"))
        }
        for t in byType["schematic_text"] ?? [] {
            guard let s = str(t["text"]), !s.isEmpty else { continue }
            schTexts.append(SchText(text: s, at: pt(t["position"]) ?? .zero, size: CGFloat(num(t["font_size"]) ?? 0.18), anchor: str(t["anchor"]) ?? "left"))
        }

        let known: Set<String> = ["pcb_board", "pcb_component", "pcb_smtpad", "pcb_plated_hole", "pcb_via", "pcb_hole", "pcb_trace", "pcb_silkscreen_path",
                                  "pcb_silkscreen_line", "pcb_silkscreen_text", "pcb_courtyard_rect", "pcb_port", "pcb_group", "schematic_component",
                                  "schematic_port", "schematic_trace", "schematic_net_label", "schematic_text", "source_component", "source_port",
                                  "source_trace", "source_net", "source_group", "cad_component"]
        for t in byType.keys where !known.contains(t) && !t.hasSuffix("_error") && !t.hasSuffix("_warning") { unknownTypes.insert(t) }
    }
}

extension CircuitModel.PadShape {
    var isPolygon: Bool { if case .polygon = self { true } else { false } }
}
