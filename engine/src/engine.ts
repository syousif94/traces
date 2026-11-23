// Traceworks engine: the unmodified tscircuit compiler and exporters, behind a tiny JSON job API.
// Loaded into a hidden WKWebView (or JSContext). The host calls `TraceworksEngine.run(jobJson)`;
// results go back through `webkit.messageHandlers.engine.postMessage` (or the returned promise).
import "./polyfills"
import { CircuitRunner } from "@tscircuit/eval"
import { runAllChecks } from "@tscircuit/checks"
import {
  convertCircuitJsonToGerberFiles,
  convertSoupToExcellonDrillCommands,
  stringifyExcellonDrill,
  stringifyGerberCommandLayers,
  convertSoupToGerberCommands,
} from "circuit-json-to-gerber"
import { convertCircuitJsonToBomRows, convertBomRowsToCsv } from "circuit-json-to-bom-csv"
import { convertCircuitJsonToPickAndPlaceCsv } from "circuit-json-to-pnp-csv"
import { convertRawEasyToTsx } from "easyeda/browser"

type Job =
  | { id: string; kind: "compile"; files: Record<string, string>; entry: string; autoroute?: boolean }
  | { id: string; kind: "drc"; circuitJson: any[] }
  | { id: string; kind: "export"; circuitJson: any[]; formats: string[] }
  | { id: string; kind: "cancel"; target: string }
  | { id: string; kind: "version" }
  | { id: string; kind: "easyeda"; raw: any }

const cancelled = new Set<string>()

function errorLocation(err: any): { file?: string; line?: number; col?: number } {
  const stack = String(err?.stack ?? "")
  const m = stack.match(/([\w./-]+\.tsx?):(\d+):(\d+)/)
  if (m) return { file: m[1], line: Number(m[2]), col: Number(m[3]) }
  return {}
}

async function compile(job: Extract<Job, { kind: "compile" }>) {
  const t0 = performance.now()
  const runner = new CircuitRunner({ disableCdnLoading: true } as any)
  try {
    await runner.setDisableCdnLoading(true)
    // Compile never touches the network: no parts engine, stock checks or cloud routing.
    await runner.setPlatformConfig({
      partsEngineDisabled: true,
      checkAvailability: false,
      useCloudAutorouter: false,
      routingDisabled: job.autoroute === false,
    } as any)
    // A file with circuit.add(...) is a script entry; otherwise the entry exports a component.
    const src = job.files[job.entry] ?? ""
    if (/circuit\.add\(/.test(src)) await runner.executeWithFsMap({ fsMap: job.files, entrypoint: job.entry })
    else await runner.executeWithFsMap({ fsMap: job.files, mainComponentPath: job.entry })
    await runner.renderUntilSettled()
    if (cancelled.has(job.id)) return { cancelled: true }
    const circuitJson = await runner.getCircuitJson()
    const errors = circuitJson
      .filter((e: any) => typeof e.type === "string" && e.type.endsWith("_error"))
      .map((e: any) => ({ type: e.type, message: e.message ?? e.type }))
    return { circuitJson, errors, ms: Math.round(performance.now() - t0) }
  } catch (err: any) {
    return {
      circuitJson: [],
      errors: [{ type: "compile_error", message: String(err?.message ?? err), ...errorLocation(err) }],
      ms: Math.round(performance.now() - t0),
    }
  } finally {
    runner.kill().catch(() => {})
  }
}

async function drc(job: Extract<Job, { kind: "drc" }>) {
  const t0 = performance.now()
  const found: any[] = await runAllChecks(job.circuitJson as any)
  const existing = job.circuitJson.filter(
    (e: any) => typeof e.type === "string" && e.type.startsWith("pcb_") && (e.type.endsWith("_error") || e.type.endsWith("_warning")),
  )
  const all = [...existing, ...found]
  const seen = new Set<string>()
  const violations = all
    .filter((v: any) => {
      const key = `${v.type}:${v.message}`
      if (seen.has(key)) return false
      seen.add(key)
      return true
    })
    .map((v: any) => ({
      type: v.type,
      severity: String(v.type).endsWith("_warning") || v.warning_type ? "warning" : "error",
      message: v.message ?? v.type,
      elementIds: Object.entries(v)
        .filter(([k, val]) => k.endsWith("_ids") && Array.isArray(val))
        .flatMap(([, val]) => val as string[])
        .concat(
          Object.entries(v)
            .filter(([k, val]) => k.endsWith("_id") && typeof val === "string" && !k.endsWith("error_id") && !k.endsWith("warning_id"))
            .map(([, val]) => val as string),
        ),
      x: v.center?.x ?? v.pcb_center?.x,
      y: v.center?.y ?? v.pcb_center?.y,
    }))
  return { violations, ms: Math.round(performance.now() - t0) }
}

function b64(text: string): string {
  const bytes = new TextEncoder().encode(text)
  let bin = ""
  for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000))
  return btoa(bin)
}

async function exportFab(job: Extract<Job, { kind: "export" }>) {
  const cj = job.circuitJson as any
  const files: Record<string, string> = {}
  const want = new Set(job.formats)
  if (want.has("gerber")) {
    const gerbers = convertCircuitJsonToGerberFiles(cj)
    for (const [name, content] of Object.entries(gerbers)) { if (name.includes("drill")) continue; files[`gerber/${name.endsWith(".gbr") ? name : name + ".gbr"}`] = b64(String(content)) }
  }
  if (want.has("drill")) {
    const plated = convertSoupToExcellonDrillCommands({ circuitJson: cj, is_plated: true } as any)
    const npth = convertSoupToExcellonDrillCommands({ circuitJson: cj, is_plated: false } as any)
    files["gerber/drill_PTH.drl"] = b64(stringifyExcellonDrill(plated))
    files["gerber/drill_NPTH.drl"] = b64(stringifyExcellonDrill(npth))
  }
  if (want.has("bom")) {
    const rows = await convertCircuitJsonToBomRows({ circuitJson: cj } as any)
    files["bom.csv"] = b64(convertBomRowsToCsv(rows))
  }
  if (want.has("pnp")) {
    files["pick_and_place.csv"] = b64(convertCircuitJsonToPickAndPlaceCsv(cj))
  }
  return { files }
}

async function runJob(job: Job): Promise<any> {
  switch (job.kind) {
    case "compile":
      return compile(job)
    case "drc":
      return drc(job)
    case "export":
      return exportFab(job)
    case "easyeda":
      // A raw EasyEDA part (fetched by the host, which has no CORS limits) → a tscircuit
      // component module with the real footprint, pin labels and supplier part number.
      return { tsx: await convertRawEasyToTsx({ rawEasy: job.raw }) }
    case "cancel":
      cancelled.add(job.target)
      return { ack: true }
    case "version":
      return { tscircuit: TSCIRCUIT_VERSION }
  }
}

declare const TSCIRCUIT_VERSION: string

async function run(jobJson: string): Promise<string> {
  let job: Job
  try {
    job = JSON.parse(jobJson)
  } catch (e: any) {
    return JSON.stringify({ id: null, ok: false, error: String(e) })
  }
  let reply: any
  try {
    reply = { id: job.id, ok: true, result: await runJob(job) }
  } catch (e: any) {
    reply = { id: job.id, ok: false, error: String(e?.stack ?? e) }
  }
  const text = JSON.stringify(reply)
  const wk = (globalThis as any).webkit?.messageHandlers?.engine
  if (wk) wk.postMessage(text)
  return text
}

;(globalThis as any).TraceworksEngine = { run }
const ready = (globalThis as any).webkit?.messageHandlers?.engineReady
if (ready) ready.postMessage("ready")
