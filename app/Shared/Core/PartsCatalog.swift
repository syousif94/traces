import Foundation

/// What the Place tool drops on the board next: a tscircuit element with its attributes, and
/// optionally a component module (a real part imported from JLCPCB/EasyEDA) the board imports.
struct PartToPlace: Sendable, Hashable {
    /// Short name for the tool and banners ("10k 0402", "ESP32-S3FN8").
    var label: String
    /// Reference designator prefix (R, C, D, U…).
    var prefix: String
    /// JSX tag: a built-in element (`resistor`) or an imported component (`ESP32_S3FN8`).
    var tag: String
    /// Attributes besides name and position.
    var attributes: String = ""
    /// The module to import the tag from (`imports/ESP32_S3FN8.tsx`), if any.
    var module: String?

    func jsx(name: String, x: Double, y: Double) -> String {
        let attrs = attributes.isEmpty ? "" : attributes + " "
        return "<\(tag) name=\"\(name)\" \(attrs)pcbX={\(fmt(x))} pcbY={\(fmt(y))} />"
    }

    static func generic(_ p: PlaceablePart) -> PartToPlace {
        switch p {
        case .resistor: PartToPlace(label: "Resistor", prefix: "R", tag: "resistor", attributes: "resistance=\"10k\" footprint=\"0402\"")
        case .capacitor: PartToPlace(label: "Capacitor", prefix: "C", tag: "capacitor", attributes: "capacitance=\"100nF\" footprint=\"0402\"")
        case .led: PartToPlace(label: "LED", prefix: "D", tag: "led", attributes: "color=\"red\" footprint=\"0603\"")
        case .chip: PartToPlace(label: "Chip", prefix: "U", tag: "chip", attributes: "footprint=\"soic8\"")
        }
    }

    /// Reference prefix for a tscircuit element kind.
    static func prefix(forElement e: String) -> String {
        switch e {
        case "resistor": "R"
        case "capacitor": "C"
        case "led", "diode": "D"
        case "inductor": "L"
        case "crystal", "resonator": "Y"
        case "connector", "pinheader", "jumper": "J"
        case "pushbutton", "switch": "SW"
        case "fuse": "F"
        case "transistor", "mosfet": "Q"
        default: "U"
        }
    }
}

/// Real parts: JLCPCB/LCSC through jlcsearch (tscircuit's public JLC index) with footprints from
/// EasyEDA, and DigiKey through its Product Information API (your own client id and secret).
/// A DigiKey part is matched to the same manufacturer part number at JLCPCB for its footprint;
/// common passives and packages fall back to a tscircuit footprint string.
enum PartsCatalog {
    enum Source: String, CaseIterable, Identifiable, Sendable {
        case jlc = "JLCPCB", digikey = "DigiKey"
        var id: String { rawValue }
    }

    struct Hit: Identifiable, Sendable, Hashable {
        var id: String { source.rawValue + ":" + partNumber }
        var source: Source
        /// LCSC (C25804) or DigiKey (311-10.0KHRCT-ND) part number.
        var partNumber: String
        var mpn: String
        var manufacturer: String?
        var package: String?
        var description: String
        var stock: Int
        var price: Double?
        /// JLCPCB Basic parts carry no extended-part loading fee.
        var basic = false
        var category: String?
        /// DigiKey parameters (name → value), used for the footprint fallback.
        var parameters: [String: String] = [:]
        var url: URL?
    }

    enum CatalogError: LocalizedError {
        case http(Int, String), notFound(String), noFootprint(String), noDigiKeyKey, rateLimited
        var errorDescription: String? {
            switch self {
            case .http(let c, let m): "The parts service answered \(c). \(m)"
            case .notFound(let p): "EasyEDA has no symbol and footprint for \(p)."
            case .noFootprint(let p): "No footprint found for \(p): it isn't stocked at JLCPCB and its package isn't one Traceworks can draw. Ask the agent to make one."
            case .noDigiKeyKey: "Add your DigiKey API client ID and secret in Settings to search DigiKey."
            case .rateLimited: "EasyEDA is rate-limiting this network. Wait a couple of minutes and try again."
            }
        }
    }

    // MARK: JLCPCB

    static func searchJLC(_ query: String, inStock: Bool = true) async throws -> [Hit] {
        var c = URLComponents(string: "https://jlcsearch.tscircuit.com/components/list.json")!
        c.queryItems = [URLQueryItem(name: "search", value: query), URLQueryItem(name: "limit", value: "40")]
        let (data, resp) = try await URLSession.shared.data(from: c.url!)
        try check(resp, data)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let rows = obj?["components"] as? [[String: Any]] ?? []
        return rows.compactMap { r -> Hit? in
            guard let n = (r["lcsc"] as? NSNumber)?.intValue ?? Int(String(describing: r["lcsc"] ?? "").dropFirst()) else { return nil }
            let stock = (r["stock"] as? NSNumber)?.intValue ?? 0
            if inStock && stock <= 0 { return nil }
            return Hit(source: .jlc, partNumber: "C\(n)", mpn: r["mfr"] as? String ?? "C\(n)", package: r["package"] as? String,
                       description: r["description"] as? String ?? "", stock: stock, price: firstTierPrice(r["price"]),
                       basic: (r["is_basic"] as? Bool) ?? false, category: r["subcategory"] as? String ?? r["category"] as? String,
                       url: URL(string: "https://jlcpcb.com/partdetail/C\(n)"))
        }
        // Basic parts first (no loading fee), then by stock.
        .sorted { ($0.basic ? 1 : 0, $0.stock) > ($1.basic ? 1 : 0, $1.stock) }
    }

    /// "1-9:3.3286,10-29:2.98" → 3.3286
    private static func firstTierPrice(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        guard let s = v as? String, let first = s.split(separator: ",").first else { return nil }
        return Double(first.split(separator: ":").last ?? "")
    }

    /// The EasyEDA symbol + footprint for an LCSC part number, as raw JSON for the engine.
    static func fetchEasyEDA(_ lcsc: String) async throws -> Data {
        let headers = [
            "accept": "application/json, text/javascript, */*; q=0.01",
            "x-requested-with": "XMLHttpRequest",
            "content-type": "application/x-www-form-urlencoded; charset=UTF-8",
            "origin": "https://easyeda.com",
            "referer": "https://easyeda.com/editor",
        ]
        var search = URLRequest(url: URL(string: "https://easyeda.com/api/components/search")!)
        search.httpMethod = "POST"
        for (k, v) in headers { search.setValue(v, forHTTPHeaderField: k) }
        let wd = lcsc.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? lcsc
        search.httpBody = Data("type=3&doctype%5B%5D=2&uid=0819f05c4eef4c71ace90d822a990e87&returnListStyle=classifyarr&wd=\(wd)&version=6.4.7".utf8)
        let (sd, sr) = try await URLSession.shared.data(for: search)
        if (sr as? HTTPURLResponse)?.statusCode == 403 { throw CatalogError.rateLimited }
        try check(sr, sd)
        let want = lcsc.uppercased()
        let list = (((try JSONSerialization.jsonObject(with: sd) as? [String: Any])?["result"] as? [String: Any])?["lists"] as? [String: Any])?["lcsc"] as? [[String: Any]] ?? []
        let match = list.first { c in
            let head = ((c["dataStr"] as? [String: Any])?["head"] as? [String: Any])?["c_para"] as? [String: Any]
            let ids = [head?["Supplier Part"], (c["lcsc"] as? [String: Any])?["number"], (c["szlcsc"] as? [String: Any])?["number"]]
            return ids.contains { ($0 as? String)?.uppercased() == want }
        }
        guard let uuid = match?["uuid"] as? String else { throw CatalogError.notFound(lcsc) }
        var get = URLRequest(url: URL(string: "https://easyeda.com/api/components/\(uuid)?version=6.4.7&uuid=\(uuid)&datastrid=")!)
        for (k, v) in headers { get.setValue(v, forHTTPHeaderField: k) }
        get.setValue("https://easyeda.com/editor?uuid=\(uuid)", forHTTPHeaderField: "referer")
        let (cd, cr) = try await URLSession.shared.data(for: get)
        if (cr as? HTTPURLResponse)?.statusCode == 403 { throw CatalogError.rateLimited }
        try check(cr, cd)
        guard let result = (try JSONSerialization.jsonObject(with: cd) as? [String: Any])?["result"] else { throw CatalogError.notFound(lcsc) }
        return try JSONSerialization.data(withJSONObject: result)
    }

    /// An imported module: where it goes and the component it exports.
    struct ImportedModule: Sendable {
        var path: String
        var componentName: String
        var source: String
        var element: String
    }

    /// JLCPCB part → `imports/<Name>.tsx` (the same layout `tsci import` uses).
    static func importJLC(_ lcsc: String, extraSuppliers: [String: String] = [:]) async throws -> ImportedModule {
        let raw = try await fetchEasyEDA(lcsc)
        var tsx = try await EngineBridge.shared.easyEDAToTSX(raw: raw)
        guard let r = tsx.range(of: #"export const (\w+)"#, options: .regularExpression) else { throw CatalogError.notFound(lcsc) }
        let name = String(tsx[r].split(separator: " ").last ?? "Part")
        for (supplier, pn) in extraSuppliers {
            tsx = tsx.replacingOccurrences(of: "supplierPartNumbers={{", with: "supplierPartNumbers={{\n  \"\(supplier)\": [\"\(pn)\"],", options: [], range: tsx.range(of: "supplierPartNumbers={{"))
        }
        var element = "chip"
        if let body = tsx.range(of: "return (") {
            let rest = tsx[body.upperBound...]
            if let t = rest.range(of: #"<([a-z]+)"#, options: .regularExpression) { element = String(rest[t].dropFirst()) }
        }
        return ImportedModule(path: "imports/\(name).tsx", componentName: name, source: tsx, element: element)
    }

    // MARK: DigiKey

    private static let tokenCache = TokenCache()

    static var hasDigiKeyKey: Bool {
        !(Keychain.get("digikeyClientId") ?? "").isEmpty && !(Keychain.get("digikeyClientSecret") ?? "").isEmpty
    }

    static func searchDigiKey(_ query: String, inStock: Bool = true) async throws -> [Hit] {
        guard let id = Keychain.get("digikeyClientId"), let secret = Keychain.get("digikeyClientSecret"), !id.isEmpty, !secret.isEmpty else {
            throw CatalogError.noDigiKeyKey
        }
        let token = try await tokenCache.token(id: id, secret: secret)
        var req = URLRequest(url: URL(string: "https://api.digikey.com/products/v4/search/keyword")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(id, forHTTPHeaderField: "X-DIGIKEY-Client-Id")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("US", forHTTPHeaderField: "X-DIGIKEY-Locale-Site")
        req.setValue("USD", forHTTPHeaderField: "X-DIGIKEY-Locale-Currency")
        var body: [String: Any] = ["Keywords": query, "Limit": 30, "Offset": 0]
        if inStock { body["FilterOptionsRequest"] = ["SearchOptions": ["InStock"]] }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        if (resp as? HTTPURLResponse)?.statusCode == 401 { await tokenCache.clear() }
        try check(resp, data)
        let products = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["Products"] as? [[String: Any]] ?? []
        return products.compactMap { p -> Hit? in
            let variations = p["ProductVariations"] as? [[String: Any]] ?? []
            // Prefer cut tape: the variation people buy in prototype quantities.
            let v = variations.first { ($0["PackageType"] as? [String: Any])?["Name"] as? String == "Cut Tape (CT)" } ?? variations.first
            guard let dk = v?["DigiKeyProductNumber"] as? String else { return nil }
            var params: [String: String] = [:]
            for q in p["Parameters"] as? [[String: Any]] ?? [] {
                if let n = q["ParameterText"] as? String, let val = q["ValueText"] as? String { params[n] = val }
            }
            let desc = p["Description"] as? [String: Any]
            return Hit(source: .digikey, partNumber: dk, mpn: p["ManufacturerProductNumber"] as? String ?? dk,
                       manufacturer: (p["Manufacturer"] as? [String: Any])?["Name"] as? String,
                       package: params["Package / Case"] ?? params["Supplier Device Package"],
                       description: desc?["ProductDescription"] as? String ?? desc?["DetailedDescription"] as? String ?? "",
                       stock: (p["QuantityAvailable"] as? NSNumber)?.intValue ?? 0,
                       price: (p["UnitPrice"] as? NSNumber)?.doubleValue,
                       category: (p["Category"] as? [String: Any])?["Name"] as? String,
                       parameters: params, url: (p["ProductUrl"] as? String).flatMap(URL.init(string:)))
        }
    }

    private actor TokenCache {
        var value: (token: String, expires: Date)?
        func clear() { value = nil }
        func token(id: String, secret: String) async throws -> String {
            if let value, value.expires > Date().addingTimeInterval(30) { return value.token }
            var req = URLRequest(url: URL(string: "https://api.digikey.com/v1/oauth2/token")!)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let enc = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s }
            req.httpBody = Data("client_id=\(enc(id))&client_secret=\(enc(secret))&grant_type=client_credentials".utf8)
            let (data, resp) = try await URLSession.shared.data(for: req)
            try PartsCatalog.check(resp, data)
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let t = obj?["access_token"] as? String else { throw CatalogError.http(0, "DigiKey sent no access token.") }
            value = (t, Date().addingTimeInterval((obj?["expires_in"] as? NSNumber)?.doubleValue ?? 600))
            return t
        }
    }

    // MARK: Turning a hit into something to place

    /// JLCPCB: the EasyEDA footprint. DigiKey: the same MPN at JLCPCB if it is there, else a
    /// tscircuit footprint string for common passives and packages.
    static func prepare(_ hit: Hit) async throws -> (PartToPlace, ImportedModule?) {
        switch hit.source {
        case .jlc:
            let m = try await importJLC(hit.partNumber)
            return (PartToPlace(label: hit.mpn, prefix: PartToPlace.prefix(forElement: m.element), tag: m.componentName, module: m.path), m)
        case .digikey:
            let norm = { (s: String) in s.uppercased().filter { $0.isLetter || $0.isNumber } }
            if let jlc = try? await searchJLC(hit.mpn, inStock: false).first(where: { norm($0.mpn) == norm(hit.mpn) }),
               let m = try? await importJLC(jlc.partNumber, extraSuppliers: ["digikey": hit.partNumber]) {
                return (PartToPlace(label: hit.mpn, prefix: PartToPlace.prefix(forElement: m.element), tag: m.componentName, module: m.path), m)
            }
            guard let p = fallback(hit) else { throw CatalogError.noFootprint(hit.mpn) }
            return (p, nil)
        }
    }

    /// A built-in element with a footprinter string, for parts with no EasyEDA footprint.
    static func fallback(_ hit: Hit) -> PartToPlace? {
        let pkg = footprint(for: hit.package ?? "")
        let ids = "manufacturerPartNumber=\"\(hit.mpn)\" supplierPartNumbers={{ digikey: [\"\(hit.partNumber)\"] }}"
        let cat = (hit.category ?? "") + " " + hit.description
        if cat.localizedCaseInsensitiveContains("resistor"), let fp = pkg, let v = hit.parameters["Resistance"].map(engValue) {
            return PartToPlace(label: hit.mpn, prefix: "R", tag: "resistor", attributes: "resistance=\"\(v)\" footprint=\"\(fp)\" \(ids)")
        }
        if cat.localizedCaseInsensitiveContains("capacitor"), let fp = pkg, let v = hit.parameters["Capacitance"].map(engValue) {
            return PartToPlace(label: hit.mpn, prefix: "C", tag: "capacitor", attributes: "capacitance=\"\(v)\" footprint=\"\(fp)\" \(ids)")
        }
        if cat.localizedCaseInsensitiveContains("LED"), let fp = pkg {
            let color = (hit.parameters["Color"] ?? "red").lowercased().split(separator: " ").first.map(String.init) ?? "red"
            return PartToPlace(label: hit.mpn, prefix: "D", tag: "led", attributes: "color=\"\(color)\" footprint=\"\(fp)\" \(ids)")
        }
        if let fp = pkg, !["0201", "0402", "0603", "0805", "1206", "1210", "2512"].contains(fp) {
            return PartToPlace(label: hit.mpn, prefix: "U", tag: "chip", attributes: "footprint=\"\(fp)\" \(ids)")
        }
        return nil
    }

    /// DigiKey "Package / Case" → a tscircuit footprinter string.
    static func footprint(for package: String) -> String? {
        let p = package.uppercased()
        for size in ["0201", "0402", "0603", "0805", "1206", "1210", "2512"] where p.hasPrefix(size) { return size }
        let pins = p.firstMatch(of: /-(\d+)/).flatMap { Int($0.1) }
        if p.hasPrefix("SOT-23") { return pins.map { $0 == 3 ? "sot23" : "sot23_\($0)" } ?? "sot23" }
        if p.hasPrefix("SOT-223") { return "sot223" }
        if p.hasPrefix("SOD-123") { return "sod123" }
        if p.hasPrefix("SOIC"), let n = pins { return "soic\(n)" }
        if p.hasPrefix("TSSOP"), let n = pins { return "tssop\(n)" }
        if p.hasPrefix("MSOP"), let n = pins { return "msop\(n)" }
        if p.hasPrefix("QFN") || p.contains("VFQFN"), let n = pins { return "qfn\(n)" }
        if p.hasPrefix("DIP") || p.contains("PDIP"), let n = pins { return "dip\(n)" }
        return nil
    }

    /// "10 kOhms" → "10k", "100 nF" → "100nF", "4.7 µF" → "4.7uF".
    static func engValue(_ s: String) -> String {
        s.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "Ohms", with: "").replacingOccurrences(of: "Ohm", with: "")
            .replacingOccurrences(of: "µ", with: "u").replacingOccurrences(of: "μ", with: "u")
    }

    static func check(_ resp: URLResponse, _ data: Data) throws {
        guard let h = resp as? HTTPURLResponse else { return }
        guard (200..<300).contains(h.statusCode) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap { $0["detail"] as? String ?? $0["ErrorMessage"] as? String ?? $0["error_description"] as? String } ?? ""
            throw CatalogError.http(h.statusCode, msg)
        }
    }
}
