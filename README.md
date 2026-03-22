# Simple8

A series of tiny 8-bit CPU written in SystemVerilog, designed for learning computer architecture.

## Project Overview

The designs are organized as follows with increasing complexity:

* Section I: Harvard - 
  * simple8.sv - A simple 8 bit single-cycle CPU, separate program ROM and data RAM (Harvard architecture)
  * simple8mh.sv - A simple 8 bit multi-cycle CPU, separate program ROM and data RAM (Harvard architecture)
* Section II: von Neumann
  * simple8mv.sv - A simple 8 bit multi-cycle CPU, unified program and data memory (von Neumann architecture)
  * simple8mvb.sv - A simple 8 bit multi-cycle CPU, unified byte adressable program and data memory (von Neumann architecture)


## simple8.sv Overview
The base Simple8 is a minimal but complete CPU that demonstrates fetch-decode-execute-writeback in a single clock cycle. It's intended for use with [svsim](https://github.com/jwd83/svsim) or any SystemVerilog simulator.

- **8-bit data path**, 16-bit instructions
- **4 general-purpose registers**: R0, R1, R2, R3
- **32 words of instruction memory** (ROM, loaded at reset)
- **32 bytes of data memory** (RAM)
- **1 flag**: Z (zero) — set when a result equals zero
- **11 instructions**: arithmetic, logic, load/store, and branching

## Instruction Set

```
 Opcode  Name   Action                  Flags
 0x0     NOP    do nothing              —
 0x1     ADD    rd = rd + rs            Z
 0x2     SUB    rd = rd - rs            Z
 0x3     AND    rd = rd & rs            Z
 0x4     OR     rd = rd | rs            Z
 0x5     XOR    rd = rd ^ rs            Z
 0x6     LDI    rd = imm8               Z
 0x7     LD     rd = RAM[imm8]          Z
 0x8     ST     RAM[imm8] = rd          —
 0x9     JMP    pc = imm8               —
 0xA     JZ     if Z: pc = imm8         —
```

## Instruction Encoding

```
 15  14  13  12 | 11  10 |  9   8 |  7  6  5  4  3  2  1  0
    opcode      |   rd   |   rs   |         imm8
```

- LDI uses the full 8-bit immediate (values 0-255)
- Memory and jump addresses use the low 5 bits (addresses 0-31)

## Example Program

The CPU ships with a built-in example program (loaded at reset) that adds two numbers, stores and loads the result, subtracts, and branches on zero:

```
 Addr  Instruction       Meaning
 0x00  LDI R0, 5         R0 = 5
 0x01  LDI R1, 3         R1 = 3
 0x02  ADD R0, R1        R0 = R0 + R1 = 8
 0x03  ST  [0x10], R0    RAM[16] = 8
 0x04  LD  R2, [0x10]    R2 = RAM[16] = 8
 0x05  SUB R2, R1        R2 = R2 - R1 = 5
 0x06  LDI R3, 5         R3 = 5
 0x07  SUB R2, R3        R2 = R2 - R3 = 0 → Z=1
 0x08  JZ  0x0A          Z is set, so jump to 0x0A
 0x09  JMP 0x09          (skipped — would loop forever)
 0x0A  NOP               done!
```

## Usage

The module has a simple interface — just `clk` and `reset`:

```systemverilog
simple8_cpu cpu (
    .clk(clk),
    .reset(reset)
);
```

## License

Copyright (c) 2026 Jared De Blander. This project is licensed under [CC0 1.0 Universal](LICENSE).
