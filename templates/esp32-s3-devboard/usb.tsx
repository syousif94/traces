export const UsbInput = () => (
  <group name="usb" pcbX={-25} pcbY={0}>
    <chip
      name="J1"
      footprint="pinrow4"
      pinLabels={{ pin1: "VBUS", pin2: "DM", pin3: "DP", pin4: "GND" }}
      pcbRotation={90}
    />
    <trace from=".J1 > .VBUS" to="net.VBUS" />
    <trace from=".J1 > .GND" to="net.GND" />
    <trace from=".J1 > .DP" to="net.USB_DP" />
    <trace from=".J1 > .DM" to="net.USB_DM" />
  </group>
)
