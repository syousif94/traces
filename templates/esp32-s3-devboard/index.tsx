import { UsbInput } from "./usb"
import { Power } from "./power"
import { boardW, boardH } from "./vars"
import manualEdits from "./manual-edits.json"

export default () => (
  <board width={`${boardW}mm`} height={`${boardH}mm`} manualEdits={manualEdits}>
    <UsbInput />
    <Power />
    <chip
      name="U1"
      manufacturerPartNumber="ESP32-S3-WROOM-1"
      footprint="qfn32"
      pinLabels={{ pin1: "V3_3", pin2: "GND", pin3: "USB_DP", pin4: "USB_DM", pin5: "IO1", pin6: "IO2" }}
      pcbX={12}
      pcbY={0}
    />
    <trace from=".U1 > .V3_3" to="net.V3_3" />
    <trace from=".U1 > .GND" to="net.GND" />
    <trace from=".U1 > .USB_DP" to="net.USB_DP" />
    <trace from=".U1 > .USB_DM" to="net.USB_DM" />
    <led name="D1" color="green" footprint="0603" pcbX={-4} pcbY={-10} />
    <led name="D2" color="blue" footprint="0603" pcbX={0} pcbY={-10} />
    <resistor name="R1" resistance="1k" footprint="0402" pcbX={-4} pcbY={-14} />
    <resistor name="R2" resistance="1k" footprint="0402" pcbX={0} pcbY={-14} />
    <trace from=".U1 > .IO1" to=".R1 > .pin1" />
    <trace from=".R1 > .pin2" to=".D1 > .anode" />
    <trace from=".D1 > .cathode" to="net.GND" />
    <trace from=".U1 > .IO2" to=".R2 > .pin1" />
    <trace from=".R2 > .pin2" to=".D2 > .anode" />
    <trace from=".D2 > .cathode" to="net.GND" />
  </board>
)
