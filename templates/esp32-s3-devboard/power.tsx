export const Power = () => (
  <group name="power" pcbX={-10} pcbY={10}>
    <chip
      name="U2"
      manufacturerPartNumber="AP2112K-3.3"
      footprint="sot23_5"
      pinLabels={{ pin1: "VIN", pin2: "GND", pin3: "EN", pin4: "NC", pin5: "VOUT" }}
    />
    <capacitor name="C1" capacitance="10uF" footprint="0402" pcbX={-5} pcbY={0} />
    <capacitor name="C2" capacitance="10uF" footprint="0402" pcbX={5} pcbY={0} />
    <trace from=".U2 > .VIN" to="net.VBUS" />
    <trace from=".U2 > .EN" to="net.VBUS" />
    <trace from=".U2 > .GND" to="net.GND" />
    <trace from=".U2 > .VOUT" to="net.V3_3" />
    <trace from=".C1 > .pin1" to="net.VBUS" />
    <trace from=".C1 > .pin2" to="net.GND" />
    <trace from=".C2 > .pin1" to="net.V3_3" />
    <trace from=".C2 > .pin2" to="net.GND" />
  </group>
)
