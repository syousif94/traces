import Foundation

/// The Swift side of `EngineHost`: called by the Rust core (agent loop, MCP) on its own threads.
/// Each call hops to the main actor and blocks the calling Rust thread until the job finishes.
/// Never called on the main thread (the agent runs detached; MCP has its own threads).
final class AppEngineHost: EngineHost, @unchecked Sendable {
    private weak var document: DocumentModel?

    @MainActor init(document: DocumentModel) { self.document = document }

    private func blocking<T: Sendable>(_ fallback: T, _ work: @escaping @MainActor (DocumentModel) async -> T) -> T {
        precondition(!Thread.isMainThread, "EngineHost must not be called on the main thread")
        let box = ResultBox(fallback)
        let sem = DispatchSemaphore(value: 0)
        Task { @MainActor [weak document] in
            if let d = document { box.value = await work(d) }
            sem.signal()
        }
        sem.wait()
        return box.value
    }

    func compile(filesJson: String, autoroute: Bool) -> String {
        blocking("{\"circuitJson\":[],\"errors\":[{\"type\":\"compile_error\",\"message\":\"no document\"}]}") { doc in
            await doc.compileForAgent(filesJSON: filesJson)
        }
    }

    func runDrc(circuitJson: String) -> String {
        blocking("{\"violations\":[]}") { doc in await doc.drcForAgent(circuitJSON: circuitJson) }
    }

    func renderSnapshot(view: String, highlight: [String]) -> Data {
        blocking(Data()) { doc in doc.renderSnapshot(view: view, highlight: highlight) ?? Data() }
    }

    func exportFab(formats: [String]) -> String {
        blocking("{\"error\":\"no document\"}") { doc in await doc.exportForAgent(formats: formats) }
    }
}

private final class ResultBox<T>: @unchecked Sendable {
    var value: T
    init(_ v: T) { value = v }
}
