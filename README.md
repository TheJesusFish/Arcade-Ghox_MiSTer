# Ghox MiSTer Core

This is a vibe coded, MAME-based Ghox arcade core for the MiSTer FPGA.
It is built on top of the excellent work from
[Erin Olafsen](https://github.com/va7deo) (Toaplan scaffolding) and
[Pramod Somashakar](https://github.com/psomashekar) (GP9001 implementation).

Save state code is thanks to [WickerWaka](https://github.com/wickerwaka)'s
amazing work with the Taito F2 and PGM cores. This made chasing down bugs much
easier.

**This core is vibe coded based on MAME. Its built binaries and MRAs live in
the [Slop Core Repo](https://github.com/TheJesusFish/Slop-Core).**

## Hardware Reference

MAME models Ghox as:

- Motorola 68000 main CPU at 10 MHz.
- Hitachi HD647180X audio/control CPU at 10 MHz, with 32 KiB internal ROM.
- One GP9001 video device clocked from 27 MHz.
- YM2151 at 27 MHz / 8; the TP-021 board has no OKIM6295.
- Raster timing: 27 MHz / 4 pixel clock, 432 total horizontal clocks, 320
  visible pixels, 262 total lines, 240 visible lines, and `ROT270` orientation.
- The `ghox` parent uses spinner input. The `ghoxj` and `ghoxjo` revisions use
  ordinary 8-way joystick input.

All three included MRAs use the same `Ghox.rbf` core. Use `Ghox.mra` for the
spinner parent, `Ghox (Joystick).mra` for `ghoxj`, or
`Ghox (Joystick, Older).mra` for `ghoxjo`.

## Source Notes

- MiSTer framework and top-level structure:
  [MiSTer-devel/Main_MiSTer](https://github.com/MiSTer-devel/Main_MiSTer) and
  [Jotego jtcores / JTFrame](https://github.com/jotego/jtcores/tree/master/modules/jtframe)

- MC68000-compatible CPU core:
  [ijor/fx68k](https://github.com/ijor/fx68k)

- YM2151-compatible sound core:
  [ika-musume IKAOPM](https://github.com/ika-musume/IKAOPM)

- Behavioral references:
  [MAME Toaplan `ghox.cpp`](https://github.com/mamedev/mame/blob/master/src/mame/toaplan/ghox.cpp),
  [MAME Toaplan `gp9001.cpp`](https://github.com/mamedev/mame/blob/master/src/mame/toaplan/gp9001.cpp), and
  [MAME Toaplan `gp9001.h`](https://github.com/mamedev/mame/blob/master/src/mame/toaplan/gp9001.h)

- HD647180X-compatible core: Ghox-local wrapper around a BSD-licensed T80
  derivative, extended for the Z180 MMU, internal I/O and RAM, and the observed
  OTIM behavior, then validated against MAME 0.288.
