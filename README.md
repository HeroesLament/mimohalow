# mimohalow

2x2 MIMO 802.11ah (HaLow) PHY for the LibreSDR (Zynq-7020 + AD9363).
RTL in EHDL, emitted as Verilog, built to a bitstream with oxibit.

## Layout

| app | path | deps | contents |
|---|---|---|---|
| `:mimohalow_model` | `model/` | none | fixed-point twins and float reference of the PHY, channel model |
| `:mimohalow_hdl` | `hdl/` | ehdl, model | PHY blocks, LibreSDR board top, emit / bitstream / regmap tasks, co-sim tests |
| `:mimohalow` | `radio/` | model | runtime API: configure, send, receive, stats; talks to the PL through `MimoHalow.Bus` |

## Dependency rule

nervezynq depends on `radio` and implements `MimoHalow.Bus` over its PL mapping.
Nothing here depends on nervezynq or on oxibit source; oxibit is called as binaries
from `OXIBIT_BIN`. Generic blocks (FFT, LDPC, rotators, SPI, AD936x ports) live in
ehdl std; HaLow-specific logic lives here.

## Flow

    EHDL --mh.emit--> build/v/*.v --mh.bit (oxibit synth, place, pnr, fasm2bit)--> build/bit/*.bin
    hdl board top --mh.regmap--> radio/lib/mimo_halow/regmap.ex

## License

MIT or Apache-2.0, at your option. See LICENSE.md.
