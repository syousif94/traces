// Polyfills for JavaScriptCore-only hosts. WKWebView already has these; they are no-ops there.
const g = globalThis as any
if (typeof g.structuredClone !== "function") g.structuredClone = (v: any) => (v === undefined ? v : JSON.parse(JSON.stringify(v)))
if (typeof g.performance === "undefined") g.performance = { now: () => Date.now() }
if (typeof g.queueMicrotask !== "function") g.queueMicrotask = (fn: () => void) => Promise.resolve().then(fn)
if (typeof g.self === "undefined") g.self = g
if (typeof g.window === "undefined") g.window = g
