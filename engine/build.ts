// Builds ../app/Shared/Resources/engine.js: one self-contained IIFE, no runtime downloads.
import pkg from "./node_modules/tscircuit/package.json"
const out = await Bun.build({
  entrypoints: ["./src/engine.ts"],
  target: "browser",
  format: "iife",
  minify: true,
  define: { "import.meta.url": JSON.stringify("https://engine.traceworks.invalid/engine.js"), TSCIRCUIT_VERSION: JSON.stringify(pkg.version), "process.env.NODE_ENV": '"production"' },
})
if (!out.success) {
  for (const l of out.logs) console.error(l)
  process.exit(1)
}
const js = await out.outputs[0].text()
const dest = process.argv[2] ?? "../app/Shared/Resources/engine.js"
await Bun.write(dest, js)
console.log(`engine.js ${(js.length / 1024 / 1024).toFixed(2)} MB, tscircuit ${pkg.version} -> ${dest}`)
