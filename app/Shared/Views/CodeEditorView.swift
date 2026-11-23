import SwiftUI

/// TSX highlighting (regex based; a tree-sitter grammar is the planned upgrade).
enum TSXHighlighter {
    struct Rule { let re: NSRegularExpression; let color: UInt32; let light: UInt32; let group: Int }
    static let rules: [Rule] = [
        Rule(re: try! NSRegularExpression(pattern: #"\b(import|export|from|const|let|var|return|default|function|as|type|interface|if|else|for|of|in|new|true|false|null|undefined)\b"#), color: 0x81A1C1, light: 0x3B5F8F, group: 0),
        Rule(re: try! NSRegularExpression(pattern: #"</?([a-zA-Z][\w.]*)"#), color: 0x81A1C1, light: 0x3B5F8F, group: 1),
        Rule(re: try! NSRegularExpression(pattern: #"\b([a-zA-Z_][\w]*)(?==)"#), color: 0x8FBCBB, light: 0x2E7D7A, group: 1),
        Rule(re: try! NSRegularExpression(pattern: #"\b[A-Z][A-Za-z0-9_]*\b"#), color: 0x88C0D0, light: 0x2F6F8A, group: 0),
        Rule(re: try! NSRegularExpression(pattern: #"(?<![\w.])-?\d+(\.\d+)?(mm|in|mil)?\b"#), color: 0xB48EAD, light: 0x8C4F86, group: 0),
        Rule(re: try! NSRegularExpression(pattern: #""[^"\n]*"|'[^'\n]*'|`[^`]*`"#), color: 0xA3BE8C, light: 0x4E7A2E, group: 0),
        Rule(re: try! NSRegularExpression(pattern: #"//[^\n]*|/\*[\s\S]*?\*/"#), color: 0x7B88A1, light: 0x6B7385, group: 0),
    ]

    static func apply(to storage: NSTextStorage, base: PlatformColor, font: PlatformFont) {
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.foregroundColor: base, .font: font], range: full)
        let s = storage.string
        for r in rules {
            for m in r.re.matches(in: s, range: full) {
                let range = m.range(at: r.group)
                guard range.location != NSNotFound else { continue }
                storage.addAttribute(.foregroundColor, value: PlatformColor.dynamic(r.color, r.light), range: range)
            }
        }
        storage.endEditing()
    }
}

#if os(macOS)
typealias PlatformFont = NSFont
#else
typealias PlatformFont = UIFont
#endif

/// Code pane: the editable editor, or a read-only full-file diff while the agent's change to this
/// file is pending review.
struct CodePane: View {
    @Bindable var doc: DocumentModel
    var showTabs = true

    var body: some View {
        VStack(spacing: 0) {
            if showTabs { tabs }
            if doc.showsAgentView && doc.isAgentModified(doc.openFile) {
                FileDiffView(old: doc.text(of: doc.openFile, agentView: false), new: doc.text(of: doc.openFile, agentView: true))
                    .id("\(doc.openFile)#\(doc.editorRevision)")
            } else {
                CodeTextView(doc: doc, path: doc.openFile)
                    .id(doc.openFile)
            }
            statusBar
        }
        .background(Theme.canvas)
    }

    private var tabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(doc.openTabs, id: \.self) { p in
                    Button { doc.open(p) } label: {
                        HStack(spacing: 6) {
                            Text((p as NSString).lastPathComponent)
                            if doc.isAgentModified(p) { Circle().fill(Theme.success).frame(width: 6, height: 6) }
                        }
                        .font(.system(size: 13, weight: p == doc.openFile ? .semibold : .regular))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(p == doc.openFile ? Theme.surfaceRaised : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .foregroundStyle(p == doc.openFile ? Theme.text : Theme.muted)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { Button("Close tab") { doc.closeTab(p) } }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator.opacity(0.5)).frame(height: 0.5) }
    }

    private var statusBar: some View {
        let rc = doc.routedCounts
        let errs = doc.compileErrors.filter { $0.type == "compile_error" || $0.type.hasSuffix("_error") }.count
        return HStack(spacing: 18) {
            HStack(spacing: 6) {
                Circle().fill(doc.compiling ? Theme.warning : (errs == 0 ? Theme.success : Theme.danger)).frame(width: 7, height: 7)
                Text(doc.compiling ? "compiling…" : doc.compileMs.map { "compiled \($0) ms" } ?? "waiting for engine")
                    .foregroundStyle(doc.compiling ? Theme.muted : Theme.success)
            }
            Text("\(errs) errors")
            Text("\(rc.routed) traces routed")
            Text("\(rc.unrouted) unrouted")
            Spacer()
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.muted)
        .padding(.horizontal, 16).frame(height: 30)
        .overlay(alignment: .top) { Rectangle().fill(Theme.separator.opacity(0.5)).frame(height: 0.5) }
        .overlay(alignment: .topLeading) {
            if let e = doc.compileErrors.first(where: { $0.type == "compile_error" }) {
                Text(e.message).font(Theme.mono(11)).foregroundStyle(Theme.danger).lineLimit(3)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surface).offset(y: -60)
            }
        }
    }
}

/// Line-level diff rows for a full file (old = main, new = agent branch).
struct DiffRow: Identifiable {
    enum Kind { case same, added, removed }
    let id: Int
    let kind: Kind
    let number: Int?
    let text: String
}

func fullDiffRows(old: String, new: String) -> [DiffRow] {
    let a = old.components(separatedBy: "\n"), b = new.components(separatedBy: "\n")
    let diff = b.difference(from: a)
    var removed = Set<Int>(), inserted = Set<Int>()
    for c in diff {
        switch c {
        case .remove(let o, _, _): removed.insert(o)
        case .insert(let o, _, _): inserted.insert(o)
        }
    }
    var rows: [DiffRow] = []
    var i = 0, j = 0, k = 0
    while i < a.count || j < b.count {
        if i < a.count, removed.contains(i) {
            rows.append(DiffRow(id: k, kind: .removed, number: nil, text: a[i])); i += 1
        } else if j < b.count, inserted.contains(j) {
            rows.append(DiffRow(id: k, kind: .added, number: j + 1, text: b[j])); j += 1
        } else {
            if j < b.count { rows.append(DiffRow(id: k, kind: .same, number: j + 1, text: b[j])) }
            i += 1; j += 1
        }
        k += 1
    }
    if rows.last?.text.isEmpty == true && rows.last?.kind == .same { rows.removeLast() }
    return rows
}

struct FileDiffView: View {
    let rows: [DiffRow]
    init(old: String, new: String) { rows = fullDiffRows(old: old, new: new) }

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { r in
                    HStack(spacing: 0) {
                        Rectangle().fill(r.kind == .same ? .clear : (r.kind == .added ? Theme.success : Theme.danger)).frame(width: 3)
                        Text(r.number.map(String.init) ?? "").frame(width: 34, alignment: .trailing).foregroundStyle(Theme.muted)
                        Text(r.kind == .added ? " +" : r.kind == .removed ? " −" : "  ").frame(width: 22, alignment: .leading)
                            .foregroundStyle(r.kind == .added ? Theme.success : Theme.danger)
                        Text(highlighted(r.text)).fixedSize()
                        Spacer(minLength: 0)
                    }
                    .font(Theme.mono(13))
                    .frame(minHeight: 22)
                    .background(r.kind == .added ? Theme.addedLine : r.kind == .removed ? Theme.removedLine : .clear)
                }
            }
            .padding(.vertical, 10)
        }
        .accessibilityLabel("Agent changes to this file")
    }

    private func highlighted(_ s: String) -> AttributedString {
        let storage = NSTextStorage(string: s)
        TSXHighlighter.apply(to: storage, base: PlatformColor.dynamic(0xD8DEE9, 0x2E3440), font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        return (try? AttributedString(storage, including: \.appKitOrUIKit)) ?? AttributedString(s)
    }
}

extension AttributeScopes {
    #if os(macOS)
    var appKitOrUIKit: AppKitAttributes.Type { AppKitAttributes.self }
    #else
    var appKitOrUIKit: UIKitAttributes.Type { UIKitAttributes.self }
    #endif
}

/// Unified-diff hunk rows (for diff cards and history).
func unifiedRows(_ unified: String) -> [DiffRow] {
    var rows: [DiffRow] = []
    var n = 0, k = 0
    for line in unified.components(separatedBy: "\n") {
        if line.hasPrefix("---") || line.hasPrefix("+++") || line.isEmpty { continue }
        if line.hasPrefix("@@") {
            if let m = line.range(of: #"\+(\d+)"#, options: .regularExpression) { n = Int(line[m].dropFirst()) ?? 1 }
            if !rows.isEmpty { rows.append(DiffRow(id: k, kind: .same, number: nil, text: "⋯")); k += 1 }
            continue
        }
        let body = String(line.dropFirst())
        switch line.first {
        case "+": rows.append(DiffRow(id: k, kind: .added, number: n, text: body)); n += 1
        case "-": rows.append(DiffRow(id: k, kind: .removed, number: nil, text: body))
        default: rows.append(DiffRow(id: k, kind: .same, number: n, text: body)); n += 1
        }
        k += 1
    }
    return rows
}

struct HunkView: View {
    let diff: FileDiff
    var maxRows = 400
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(unifiedRows(diff.unified).prefix(maxRows)) { r in
                HStack(spacing: 6) {
                    Text(r.kind == .added ? "+" : r.kind == .removed ? "−" : " ").foregroundStyle(r.kind == .added ? Theme.success : Theme.danger)
                    Text(r.text).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(Theme.mono(12.5))
                .padding(.horizontal, 10).frame(minHeight: 24)
                .background(r.kind == .added ? Theme.addedLine : r.kind == .removed ? Theme.removedLine : .clear)
            }
        }
    }
}

// MARK: - Platform text views

#if os(macOS)
struct CodeTextView: NSViewRepresentable {
    @Bindable var doc: DocumentModel
    let path: String

    func makeCoordinator() -> Coordinator { Coordinator(doc: doc) }

    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSTextView.scrollableTextView()
        sv.drawsBackground = false
        let tv = sv.documentView as! NSTextView
        _ = tv.layoutManager  // TextKit 1 for the line-number ruler
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.drawsBackground = false
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.textColor = NSColor.dynamic(0xD8DEE9, 0x2E3440)
        tv.insertionPointColor = NSColor(hex: 0x88C0D0)
        tv.textContainerInset = NSSize(width: 6, height: 10)
        tv.delegate = context.coordinator
        let ruler = LineNumberRuler(textView: tv)
        sv.verticalRulerView = ruler
        sv.hasVerticalRuler = true
        sv.rulersVisible = true
        context.coordinator.textView = tv
        context.coordinator.load(path: path)
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        let c = context.coordinator
        if c.path != path || c.revision != doc.editorRevision { c.load(path: path) }
        if let line = doc.revealLine { c.reveal(line: line); DispatchQueue.main.async { doc.revealLine = nil } }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        let doc: DocumentModel
        weak var textView: NSTextView?
        var path = ""
        var revision = -1
        private var saveTask: Task<Void, Never>?
        init(doc: DocumentModel) { self.doc = doc }

        func load(path: String) {
            guard let tv = textView else { return }
            let text = doc.text(of: path, agentView: false)
            self.path = path
            revision = doc.editorRevision
            if tv.string != text {
                let sel = tv.selectedRange()
                tv.string = text
                tv.setSelectedRange(NSRange(location: min(sel.location, (text as NSString).length), length: 0))
            }
            highlight()
        }

        func highlight() {
            guard let tv = textView, let storage = tv.textStorage else { return }
            TSXHighlighter.apply(to: storage, base: NSColor.dynamic(0xD8DEE9, 0x2E3440), font: .monospacedSystemFont(ofSize: 13, weight: .regular))
            tv.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }

        func reveal(line: Int) {
            guard let tv = textView else { return }
            let ns = tv.string as NSString
            var loc = 0, l = 1
            while l < line, loc < ns.length {
                let r = ns.lineRange(for: NSRange(location: loc, length: 0)); loc = NSMaxRange(r); l += 1
            }
            let r = ns.lineRange(for: NSRange(location: min(loc, ns.length), length: 0))
            tv.setSelectedRange(r)
            tv.scrollRangeToVisible(r)
        }

        func textDidChange(_ notification: Notification) {
            highlight()
            saveTask?.cancel()
            let text = textView?.string ?? ""
            let p = path
            saveTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                doc.saveFromEditor(path: p, text: text)
                revision = doc.editorRevision
            }
        }
    }
}

final class LineNumberRuler: NSRulerView {
    weak var textView: NSTextView?
    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 40
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: textView.enclosingScrollView?.contentView, queue: .main) { [weak self] _ in
            self?.needsDisplay = true
        }
    }
    required init(coder: NSCoder) { fatalError() }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        let ns = tv.string as NSString
        let visible = tv.visibleRect
        let glyphs = lm.glyphRange(forBoundingRect: visible, in: tc)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var line = ns.substring(to: chars.location).components(separatedBy: "\n").count
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.dynamic(0x7B88A1, 0x6B7385)]
        var idx = chars.location
        while idx <= NSMaxRange(chars) && idx <= ns.length {
            let lr = ns.lineRange(for: NSRange(location: idx, length: 0))
            let gr = lm.glyphRange(forCharacterRange: NSRange(location: lr.location, length: 0), actualCharacterRange: nil)
            var frag = lm.lineFragmentRect(forGlyphAt: min(gr.location, max(0, lm.numberOfGlyphs - 1)), effectiveRange: nil)
            if lm.numberOfGlyphs == 0 { frag = .zero }
            let y = frag.minY + tv.textContainerInset.height - visible.minY
            let s = "\(line)" as NSString
            let size = s.size(withAttributes: attrs)
            s.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y + 1), withAttributes: attrs)
            line += 1
            if NSMaxRange(lr) == idx { break }
            idx = NSMaxRange(lr)
            if idx == ns.length { break }
        }
    }
}
#else
struct CodeTextView: UIViewRepresentable {
    @Bindable var doc: DocumentModel
    let path: String

    func makeCoordinator() -> Coordinator { Coordinator(doc: doc) }

    func makeUIView(context: Context) -> NumberedTextView {
        let tv = NumberedTextView(usingTextLayoutManager: false)
        tv.backgroundColor = .clear
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.textColor = UIColor.dynamic(0xD8DEE9, 0x2E3440)
        tv.tintColor = UIColor(hex: 0x88C0D0)
        tv.autocorrectionType = .no
        tv.autocapitalizationType = .none
        tv.smartQuotesType = .no
        tv.smartDashesType = .no
        tv.spellCheckingType = .no
        tv.keyboardType = .asciiCapable
        tv.alwaysBounceVertical = true
        tv.textContainerInset = UIEdgeInsets(top: 10, left: 44, bottom: 40, right: 8)
        tv.delegate = context.coordinator
        context.coordinator.textView = tv
        context.coordinator.load(path: path)
        return tv
    }

    func updateUIView(_ tv: NumberedTextView, context: Context) {
        let c = context.coordinator
        if c.path != path || c.revision != doc.editorRevision { c.load(path: path) }
        if let line = doc.revealLine { c.reveal(line: line); DispatchQueue.main.async { doc.revealLine = nil } }
    }

    @MainActor final class Coordinator: NSObject, UITextViewDelegate {
        let doc: DocumentModel
        weak var textView: NumberedTextView?
        var path = ""
        var revision = -1
        private var saveTask: Task<Void, Never>?
        init(doc: DocumentModel) { self.doc = doc }

        func load(path: String) {
            guard let tv = textView else { return }
            let text = doc.text(of: path, agentView: false)
            self.path = path
            revision = doc.editorRevision
            if tv.text != text { tv.text = text }
            highlight()
        }

        func highlight() {
            guard let tv = textView else { return }
            let sel = tv.selectedRange
            TSXHighlighter.apply(to: tv.textStorage, base: UIColor.dynamic(0xD8DEE9, 0x2E3440), font: .monospacedSystemFont(ofSize: 13, weight: .regular))
            tv.selectedRange = sel
            tv.setNeedsDisplay()
        }

        func reveal(line: Int) {
            guard let tv = textView else { return }
            let ns = tv.text as NSString
            var loc = 0, l = 1
            while l < line, loc < ns.length { loc = NSMaxRange(ns.lineRange(for: NSRange(location: loc, length: 0))); l += 1 }
            let r = ns.lineRange(for: NSRange(location: min(loc, ns.length), length: 0))
            tv.selectedRange = r
            tv.scrollRangeToVisible(r)
        }

        func textViewDidChange(_ textView: UITextView) {
            highlight()
            saveTask?.cancel()
            let text = textView.text ?? ""
            let p = path
            saveTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                doc.saveFromEditor(path: p, text: text)
                revision = doc.editorRevision
            }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) { scrollView.setNeedsDisplay() }
    }
}

/// UITextView that draws line numbers in its left inset.
final class NumberedTextView: UITextView {
    override func draw(_ rect: CGRect) {
        super.draw(rect)
        let lm = layoutManager
        let ns = text as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: UIColor.dynamic(0x7B88A1, 0x6B7385)]
        let visible = CGRect(origin: contentOffset, size: bounds.size)
        let glyphs = lm.glyphRange(forBoundingRect: visible.offsetBy(dx: 0, dy: -textContainerInset.top), in: textContainer)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var line = ns.substring(to: min(chars.location, ns.length)).components(separatedBy: "\n").count
        var idx = chars.location
        while idx < ns.length, idx <= NSMaxRange(chars) {
            let lr = ns.lineRange(for: NSRange(location: idx, length: 0))
            let g = lm.glyphIndexForCharacter(at: lr.location)
            let frag = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            let s = "\(line)" as NSString
            let size = s.size(withAttributes: attrs)
            s.draw(at: CGPoint(x: textContainerInset.left - size.width - 10, y: frag.minY + textContainerInset.top + 1), withAttributes: attrs)
            line += 1
            idx = NSMaxRange(lr)
        }
    }
    override var contentOffset: CGPoint { didSet { setNeedsDisplay() } }
}
#endif
