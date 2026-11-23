// Smoke test: load the built engine.js as a browser would and compile a project folder.
import { readdirSync, readFileSync, statSync } from "fs"
import { join, relative } from "path"
const dir = process.argv[2]
const files: Record<string, string> = {}
const walk = (d: string) => {
  for (const n of readdirSync(d)) {
    if (n.startsWith(".") || n === "node_modules") continue
    const p = join(d, n)
    if (statSync(p).isDirectory()) walk(p)
    else if (/\.(tsx?|json)$/.test(n)) files[relative(dir, p)] = readFileSync(p, "utf8")
  }
}
walk(dir)
;(0, eval)(readFileSync(new URL("../app/Shared/Resources/engine.js", import.meta.url), "utf8"))
const E = (globalThis as any).TraceworksEngine
const c = JSON.parse(await E.run(JSON.stringify({ id: "1", kind: "compile", files, entry: "index.tsx" })))
if (!c.ok) { console.error(c.error); process.exit(1) }
const cj = c.result.circuitJson
const counts: Record<string, number> = {}
for (const e of cj) counts[e.type] = (counts[e.type] ?? 0) + 1
console.log("compile ms", c.result.ms, "errors", JSON.stringify(c.result.errors).slice(0, 600))
console.log(counts)
const d = JSON.parse(await E.run(JSON.stringify({ id: "2", kind: "drc", circuitJson: cj })))
console.log("drc", d.ok ? d.result.violations.length + " violations " + JSON.stringify(d.result.violations.slice(0, 3)) : d.error)
const x = JSON.parse(await E.run(JSON.stringify({ id: "3", kind: "export", circuitJson: cj, formats: ["gerber", "drill", "bom", "pnp"] })))
console.log("export", x.ok ? Object.keys(x.result.files) : x.error)
if (process.argv[3]) await Bun.write(process.argv[3], JSON.stringify(cj, null, 1))
