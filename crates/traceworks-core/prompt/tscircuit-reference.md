<!-- From github.com/tscircuit/skill (MIT License, Copyright (c) 2026 tscircuit). -->
# tscircuit syntax primer

## 1) Root element

A circuit is typically a default export that returns a `<board />` or a form-factor board component from `@tscircuit/common`.

Example:

```tsx
import React from "react"

export default () => (
  <board width="10mm" height="10mm" layers={2}>
    <resistor name="R1" resistance="1k" footprint="0402" />
  </board>
)
```


## 2) Layout properties

You can place nearly any element with:
- `pcbX`, `pcbY` (PCB position)
- `pcbRotation`
- `layer` (e.g., `"bottom"`)


For schematics:
- `schX`, `schY`
- `schRotation`
- `schOrientation`

Units
- Numbers are interpreted as mm.
- Strings can include units (e.g., `"0.1in"`, `"2.54mm"`).

## 3) Pin labels with `pinLabels`

Use `pinLabels` to map physical pin numbers to meaningful names. This is essential for chips and ICs.

```tsx
<chip
  name="U1"
  footprint="qfp32"
  pinLabels={{
    pin1: ["GP0", "SPI0_RX", "I2C0_SDA", "UART0_TX"],
    pin2: ["GP1", "SPI0_CS", "I2C0_SCL", "UART0_RX"],
    pin3: "GND",
    // ...
  }}
/>
```

With multi-alias, any of the names can be used in traces:

```tsx
<trace from="U1.GP0" to="U2.SDA" />
<trace from="U1.SPI0_RX" to="U3.MISO" />
```

## 4) Pin attributes with `pinAttributes`

Use `pinAttributes` to add semantic metadata to pins. This enables DRC checks, schematic arrows, and board-level pinout exposure.

Example using a 555 timer (NE555):

```tsx
<chip
  name="U1"
  footprint="dip8"
  pinLabels={{
    pin1: "GND",
    pin2: "TRIG",
    pin3: "OUT",
    pin4: "RESET",
    pin5: "CTRL",
    pin6: "THRES",
    pin7: "DISCH",
    pin8: "VCC",
  }}
  pinAttributes={{
    VCC: { requiresPower: true },
    RESET: { mustBeConnected: true },
  }}
/>
```

Available attributes:

| Attribute | Type | Description |
|-----------|------|-------------|
| `requiresPower` | boolean | Signal goes INTO the chip (shows input arrow on schematic) |
| `providesPower` | boolean | Signal comes OUT of the chip (shows output arrow on schematic) |
| `mustBeConnected` | boolean | DRC error if this pin is left floating |
| `includeInBoardPinout` | boolean | Expose this pin to the board-level pinout |

## 5) Type-safe chip components

For reusable chip components, define `pinLabels` as a const and use `ChipProps` for type safety:

```tsx
import type { ChipProps } from "tscircuit"

const pinLabels = {
  pin1: "VCC",
  pin2: "GND",
  pin3: ["SDA", "I2C_DATA"],
  pin4: ["SCL", "I2C_CLK"],
} as const

export const MyChip = (props: ChipProps<typeof pinLabels>) => (
  <chip
    {...props}
    pinLabels={pinLabels}
    footprint="soic4"
  />
)
```

## 6) Use `<connector />` for USB connectors

Use `<connector />` for all USB connector footprints (USB-C, Micro-USB, Mini-USB, and USB-A/B variants). This gives the design checker better semantic information for connector-related DRC.

If a `<chip />` is currently modeling a USB receptacle, plug, or jack, consider refactoring it to `<connector />` so additional USB-specific DRC checks can apply.

For a USB-C connector component, prefer the built-in standard:

```tsx
<connector name="USBC" standard="usb_c" />

<trace from="USBC.VBUS1" to="net.VBUS" />
<trace from="USBC.VBUS2" to="net.VBUS" />
<trace from="USBC.DP1" to="net.USB_DP" />
<trace from="USBC.DP2" to="net.USB_DP" />
<trace from="USBC.DM1" to="net.USB_DM" />
<trace from="USBC.DM2" to="net.USB_DM" />
```

No JLC import is required for this default USB-C connector usage.

## 7) Connectivity with `<trace />`

Connect pins with port selectors:

```tsx
<trace from="R1.pin1" to="C1.pin1" />
```

Connect to named nets. Net names must start with a letter or underscore and can only contain letters, numbers and underscores. 

```tsx
<trace from="U1.pin1" to="net.GND" />
<trace from="U1.pin8" to="net.VCC" />
<trace from="U1.pin8" to="net.V3_3" />
```

Pin labels (in `pinLabels`) can contain letters, numbers, and underscores. Unlike net names, pin labels **can** start with a number (e.g., `"3V3"` is valid).

Useful trace props (optional)
- `width` / `thickness`
- `minLength` / `maxLength`

## 8) Grouping for PCB layout

Use `<group />` like a container to move/layout parts together.

```tsx
<board width="20mm" height="20mm">
  <group pcbX={5} pcbY={5}>
    <resistor name="R1" resistance="1k" footprint="0402" pcbX={2.5} pcbY={2.5} />
    <resistor name="R2" resistance="1k" footprint="0402" pcbX={2.5} pcbY={0} />
    <resistor name="R3" resistance="1k" footprint="0402" pcbX={2.5} pcbY={-2.5} />
  </group>
</board>
```

## 9) Schematic pin arrangement

Control how pins appear on the schematic symbol with `schPinArrangement`:

```tsx
<chip
  name="U1"
  footprint="soic16"
  pinLabels={{
    pin1: "VCC1",
    pin2: "IN1",
    pin3: "IN2",
    pin4: "IN3",
    pin5: "IN4",
    pin6: "GND1",
    pin7: "GND2",
    pin8: "VCC2",
    pin9: "OUT1",
    pin10: "OUT2",
    pin11: "OUT3",
    pin12: "OUT4",
  }}
  schPinArrangement={{
    topSide: { pins: ["VCC1", "VCC2"], direction: "left-to-right" },
    bottomSide: { pins: ["GND1", "GND2"], direction: "left-to-right" },
    leftSide: { pins: ["IN1", "IN2", "IN3", "IN4"], direction: "top-to-bottom" },
    rightSide: { pins: ["OUT1", "OUT2", "OUT3", "OUT4"], direction: "top-to-bottom" },
  }}
/>
```

Available sides: `leftSide`, `rightSide`, `topSide`, `bottomSide`
- Left/right sides use `direction: "top-to-bottom"` or `"bottom-to-top"`
- Top/bottom sides use `direction: "left-to-right"` or `"right-to-left"`

## 10) Manufacturing helpers

For turnkey assembly you will often want:
- `supplierPartNumbers` (pin a specific supplier SKU/part number)
- `doNotPlace` (exclude from automated placement)

Example:

```tsx
<capacitor
  name="C1"
  capacitance="100nF"
  footprint="0402"
  supplierPartNumbers={{ jlcpcb: "C14663" }}
/>

<resistor name="R1" resistance="10k" footprint="0402" doNotPlace />
```

# Footprints

Use a footprinter string for standard packages.

For JLCPCB parts, run `tsci import <C-number>`. It uses a string only when there is a close footprinter string match. Otherwise it keeps the exact EasyEDA footprint. `--use-exact-footprint` skips conversion.

To simplify explicit pads, run `tsci convert imports/MyChip.tsx --footprinter`
(one component, not a board). Use the printed string as `footprint="..."` after
checking pad geometry and pin mapping. The source is not rewritten. Optional
`--json` returns a match report containing the string and scores, not a footprint file.

## Examples

```tsx
// Passives
<resistor footprint="0201" />
<resistor footprint="0402" />
<resistor footprint="0603" />
<resistor footprint="0805" />
<resistor footprint="1206" />
<capacitor footprint="cap0402" />
<resistor footprint="res0805" />
<resistor footprint="axial_p0.2in" />
<capacitor footprint="radial_p2.54mm" />
<capacitor footprint="electrolytic_d6.3mm_p2.5mm" />

// Diodes and transistors
<diode footprint="sod123" />
<diode footprint="sod323" />
<diode footprint="sma" />
<diode footprint="smb" />
<diode footprint="smf" />
<transistor footprint="sot23" />
<transistor footprint="sot223" />
<transistor footprint="sot323" />
<transistor footprint="sot363" />
<transistor footprint="sot563" />

// ICs
<chip footprint="dip8_w0.3in" />
<chip footprint="dip16" />
<chip footprint="soic8_p1.27mm" />
<chip footprint="soic16_p1.27mm" />
<chip footprint="ssop16_p0.65mm" />
<chip footprint="tssop20_p0.5mm" />
<chip footprint="msop10_p0.5mm" />
<chip footprint="vssop8_p0.5mm" />
<chip footprint="qfn16_w3_h3_p0.5mm_thermalpad" />
<chip footprint="qfn24_w6_h6_p0.8mm_thermalpad" />
<chip footprint="qfn32_w5_h5_p0.5mm_thermalpad" />
<chip footprint="tqfp32_w7_h7_p0.8mm" />
<chip footprint="lqfp48_w7_h7_p0.5mm" />
<chip footprint="bga64_grid8x8_p0.8mm_w8_h8" />

// Connectors and through-hole packages
<connector footprint="pinrow4_p2.54mm" />
<connector footprint="pinrow10_p2.54mm" />
<connector footprint="pinrow6_p2.54mm_rows2" />
<connector footprint="jst2_p2mm_ph" />
<connector footprint="jst4_p1mm_sh" />
<crystal footprint="hc49_p4.88mm" />
<crystal footprint="crystal4_px2.5mm_py2mm" />
<transistor footprint="to220" />
<transistor footprint="to220f" />
<transistor footprint="to92" />
<pushbutton footprint="smdpushbutton" />
```

Syntax: `<family>[pin-count]_<modifier><value>...`. Include units.

## Inspect a footprint

To see which pin sits where before placing a part, run
`tsci inspect footprint` from the project directory.

```bash
tsci inspect footprint jst2_p2.5mm_xh
```

```text
jst2_p2.5mm_xh
source: footprinter string (@tscircuit/footprinter installed in this project)
parameters: fn=jst p=2.5 xh=true id=1 pw=1.7 pl=2 w=7.62 h=5.97 num_pins=2
pads: 2 plated holes
copper: 4.2 x 2 mm (x -2.1 to 2.1, y -1 to 1)
courtyard: 8.4 x 6.75 mm (x -4.2 to 4.2, y -3.9 to 2.85)

pin  kind         shape                        x      y  width  height  hole  layers
1    plated_hole  circular_hole_with_rect_pad  -1.25  0  1.7    2       1     top,bottom
2    plated_hole  pill                         1.25   0  1.7    2       1     top,bottom

Millimetres in the footprint's own frame (+x right, +y up), before pcbRotation.
```

- `x` and `y` are the pad centre. `width` and `height` are the copper extent.
  `hole` is the drill size.
- `parameters` shows how the string was parsed. Check it: a modifier that
  footprinter does not recognise is dropped without an error, so a missing
  thermal pad or a default pitch shows up here and in the pad count.
- The argument can also be a library footprint
  (`kicad:Resistor_SMD/R_0402_1005Metric`, `jlcpcb:C14877`) or a file: a
  `.kicad_mod`, a `.circuit.json`, or a TSX file that renders one component,
  such as `imports/MyChip.tsx`. For a component file the pin labels are listed
  next to the pin numbers (`1,VCC`).
- `--json` prints the same data as JSON.
- A string that does not parse exits with status 1.
- If the CLI reports `unknown command 'inspect'`, it predates this command; run
  `tsci upgrade`.

Use custom `<footprint>` TSX only for unsupported manufacturer geometry, such as asymmetric pads, slots, shield tabs, segmented thermal pads, or mixed SMT and through-hole layouts. Never guess.

# Pre-export / pre-fab checklist

Connectivity
- Review `tsci check source` and `tsci check netlist` diagnostics and resolve connectivity errors.
- All intended nets are connected; no floating power pins.
- `tsci check shorts` passes with no detected shorts; inspect and resolve any generated `checks/check-shorts/` debug artifacts.

Footprints and pinout
- Review `tsci check pin_specification` for unmet pin requirements.
- Footprints match intended package size and orientation.
- Pin 1 orientation is correct for polarized parts.

PCB constraints
- Review `tsci check pcb-style` and its highlighted SVG; fix long odd-angle runs and unnecessary stair stepping.
- Board outline, mounting holes, and keepouts are correct.
- Trace width/clearance meets target fab rules.

Schematic hygiene
- Key nets labeled; power/ground clear.
- Reference designators present and stable.

Assembly readiness
- Use `supplierPartNumbers` for critical parts / specific suppliers.
- Mark hand-soldered parts with `doNotPlace`.

Build/export
- `tsci build` succeeds without unexpected errors.
- Exported artifacts match your needs (SVG, netlist, DSN, 3D, KiCad library).
- Fabrication zip contains Gerbers, BOM CSV, Pick'n'Place CSV.
