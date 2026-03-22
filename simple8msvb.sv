// ============================================================================
//  Simple8MSVB — Byte-addressable multicycle von Neumann CPU
//
//  Quick overview
//  ──────────────
//  • Same instruction set as Simple8
//  • Multicycle control with byte-addressable memory
//  • Von Neumann organization: one shared memory for code and data
//  • Memory is 256 bytes × 8 bits — each byte has its own address
//  • Instructions are 16 bits wide, stored big-endian across two bytes
//  • Fetch takes two cycles: read high byte at PC, low byte at PC+1
//  • PC increments by 2 for sequential execution
//
//  Memory layout
//  ──────────────────────────────────────
//  Byte-addressable: 256 bytes (addresses 0x00–0xFF).
//  Instructions occupy two consecutive bytes, big-endian:
//      mem[addr]   = opcode | rd | rs      (high byte)
//      mem[addr+1] = imm8                  (low byte)
//
//  Data loads and stores operate on a single byte.
//
//  Instruction encoding (same logical format, stored across two bytes)
//  ──────────────────────────────────────────────────────
//   High byte (mem[PC]):    7  6  5  4 | 3  2 | 1  0
//                              opcode  |  rd  |  rs
//
//   Low byte (mem[PC+1]):   7  6  5  4  3  2  1  0
//                                    imm8
//  ──────────────────────────────────────────────────────
//
//  Instruction set
//  ──────────────────────────────────────────────────────
//   Opcode  Name   Action                  Flags
//   0x0     NOP    do nothing              —
//   0x1     ADD    rd = rd + rs            Z
//   0x2     SUB    rd = rd - rs            Z
//   0x3     AND    rd = rd & rs            Z
//   0x4     OR     rd = rd | rs            Z
//   0x5     XOR    rd = rd ^ rs            Z
//   0x6     LDI    rd = imm8              Z
//   0x7     LD     rd = MEM[imm8]          Z
//   0x8     ST     MEM[imm8] = rd          —
//   0x9     JMP    pc = imm8              —
//   0xA     JZ     if Z: pc = imm8        —
//  ──────────────────────────────────────────────────────
//
//  Note: All addresses (LD, ST, JMP, JZ) use the full 8-bit immediate,
//        giving access to the entire 256-byte address space.
//        Jump targets should be even addresses for valid instruction fetch.
//
// ============================================================================

module simple8msvb_cpu (
    input  logic clk,
    input  logic reset
);

    // ─── Architectural state ─────────────────────────────────────────────

    logic [7:0]  pc;                    // program counter (addresses 0–255)
    logic [7:0]  regfile [0:3];         // registers R0–R3
    logic        z_flag;                // zero flag

    // ─── Byte-addressable shared memory ─────────────────────────────────

    logic [7:0]  mem [0:255];           // one byte per address

    // ─── Multicycle control ──────────────────────────────────────────────

    typedef enum logic [2:0] {
        FETCH_HI,                       // read high byte of instruction at PC
        FETCH_LO,                       // read low byte of instruction at PC+1
        EXECUTE,                        // do ALU work, stores, and branches
        MEM_READ,                       // wait for a synchronous data read
        WRITEBACK                       // finish a load
    } state_t;

    state_t state;

    // ─── Instruction register and decoded fields ────────────────────────

    logic [7:0]  instr_hi;             // high byte (opcode | rd | rs)
    logic [7:0]  instr_lo;             // low byte  (imm8)

    logic [3:0]  opcode;               // high byte [7:4]
    logic [1:0]  rd_idx;               // high byte [3:2]
    logic [1:0]  rs_idx;               // high byte [1:0]
    logic [7:0]  imm8;                 // low byte
    logic [7:0]  addr;                 // alias for imm8 (full byte address)

    // ─── Internal registers ──────────────────────────────────────────────

    logic [7:0]  mem_read;             // value returned by a load

    assign opcode = instr_hi[7:4];
    assign rd_idx = instr_hi[3:2];
    assign rs_idx = instr_hi[1:0];
    assign imm8   = instr_lo;
    assign addr   = imm8;

    // =====================================================================
    //  STATE MACHINE — advance one micro-step per clock
    // =====================================================================

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            // Clear the processor state
            pc         <= 8'd0;
            z_flag     <= 1'b0;
            state      <= FETCH_HI;
            instr_hi   <= 8'h00;
            instr_lo   <= 8'h00;
            mem_read   <= 8'd0;

            regfile[0] <= 8'd0;
            regfile[1] <= 8'd0;
            regfile[2] <= 8'd0;
            regfile[3] <= 8'd0;

            // Clear shared memory
            for (int i = 0; i < 256; i++) begin
                mem[i] <= 8'h00;
            end

            // ─────────────────────────────────────────────────────────
            //  Example program: same instructions as Simple8.
            //  Code starts at address 0x00 (occupies bytes 0x00–0x15).
            //  Address 0x80 is used as a data location.
            //
            //  Each instruction is two bytes, big-endian:
            //    high byte = {opcode, rd, rs}
            //    low byte  = imm8
            // ─────────────────────────────────────────────────────────

            // LDI R0, 5          opcode=6, rd=0, rs=0 → high=0x60, low=0x05
            mem[8'h00] <= 8'h60;  mem[8'h01] <= 8'h05;

            // LDI R1, 3          opcode=6, rd=1, rs=0 → high=0x64, low=0x03
            mem[8'h02] <= 8'h64;  mem[8'h03] <= 8'h03;

            // ADD R0, R1         opcode=1, rd=0, rs=1 → high=0x11, low=0x00
            mem[8'h04] <= 8'h11;  mem[8'h05] <= 8'h00;

            // ST [0x80], R0      opcode=8, rd=0, rs=0 → high=0x80, low=0x80
            mem[8'h06] <= 8'h80;  mem[8'h07] <= 8'h80;

            // LD R2, [0x80]      opcode=7, rd=2, rs=0 → high=0x78, low=0x80
            mem[8'h08] <= 8'h78;  mem[8'h09] <= 8'h80;

            // SUB R2, R1         opcode=2, rd=2, rs=1 → high=0x29, low=0x00
            mem[8'h0A] <= 8'h29;  mem[8'h0B] <= 8'h00;

            // LDI R3, 5          opcode=6, rd=3, rs=0 → high=0x6C, low=0x05
            mem[8'h0C] <= 8'h6C;  mem[8'h0D] <= 8'h05;

            // SUB R2, R3         opcode=2, rd=2, rs=3 → high=0x2B, low=0x00
            mem[8'h0E] <= 8'h2B;  mem[8'h0F] <= 8'h00;

            // JZ 0x14            opcode=A, rd=0, rs=0 → high=0xA0, low=0x14
            mem[8'h10] <= 8'hA0;  mem[8'h11] <= 8'h14;

            // JMP 0x12           opcode=9, rd=0, rs=0 → high=0x90, low=0x12
            mem[8'h12] <= 8'h90;  mem[8'h13] <= 8'h12;

            // NOP                opcode=0, rd=0, rs=0 → high=0x00, low=0x00
            mem[8'h14] <= 8'h00;  mem[8'h15] <= 8'h00;

        end else begin
            case (state)

                // -----------------------------------------------------
                // FETCH_HI — read the high byte of the instruction
                //             (opcode, rd, rs) from mem[pc]
                // -----------------------------------------------------
                FETCH_HI: begin
                    instr_hi <= mem[pc];
                    state    <= FETCH_LO;
                end

                // -----------------------------------------------------
                // FETCH_LO — read the low byte of the instruction
                //             (imm8) from mem[pc+1]; advance to execute
                // -----------------------------------------------------
                FETCH_LO: begin
                    instr_lo <= mem[pc + 8'd1];
                    state    <= EXECUTE;
                end

                // -----------------------------------------------------
                // EXECUTE — do the main work of the instruction
                // -----------------------------------------------------
                EXECUTE: begin
                    case (opcode)
                        4'h0: begin // NOP
                            pc    <= pc + 8'd2;
                            state <= FETCH_HI;
                        end

                        4'h1: begin // ADD rd, rs
                            regfile[rd_idx] <= regfile[rd_idx] + regfile[rs_idx];
                            z_flag          <= ((regfile[rd_idx] + regfile[rs_idx]) == 8'd0);
                            pc              <= pc + 8'd2;
                            state           <= FETCH_HI;
                        end

                        4'h2: begin // SUB rd, rs
                            regfile[rd_idx] <= regfile[rd_idx] - regfile[rs_idx];
                            z_flag          <= ((regfile[rd_idx] - regfile[rs_idx]) == 8'd0);
                            pc              <= pc + 8'd2;
                            state           <= FETCH_HI;
                        end

                        4'h3: begin // AND rd, rs
                            regfile[rd_idx] <= regfile[rd_idx] & regfile[rs_idx];
                            z_flag          <= ((regfile[rd_idx] & regfile[rs_idx]) == 8'd0);
                            pc              <= pc + 8'd2;
                            state           <= FETCH_HI;
                        end

                        4'h4: begin // OR rd, rs
                            regfile[rd_idx] <= regfile[rd_idx] | regfile[rs_idx];
                            z_flag          <= ((regfile[rd_idx] | regfile[rs_idx]) == 8'd0);
                            pc              <= pc + 8'd2;
                            state           <= FETCH_HI;
                        end

                        4'h5: begin // XOR rd, rs
                            regfile[rd_idx] <= regfile[rd_idx] ^ regfile[rs_idx];
                            z_flag          <= ((regfile[rd_idx] ^ regfile[rs_idx]) == 8'd0);
                            pc              <= pc + 8'd2;
                            state           <= FETCH_HI;
                        end

                        4'h6: begin // LDI rd, imm8
                            regfile[rd_idx] <= imm8;
                            z_flag          <= (imm8 == 8'd0);
                            pc              <= pc + 8'd2;
                            state           <= FETCH_HI;
                        end

                        4'h7: begin // LD rd, [addr]
                            pc    <= pc + 8'd2;
                            state <= MEM_READ;
                        end

                        4'h8: begin // ST [addr], rd
                            mem[addr] <= regfile[rd_idx];
                            pc        <= pc + 8'd2;
                            state     <= FETCH_HI;
                        end

                        4'h9: begin // JMP addr
                            pc    <= addr;
                            state <= FETCH_HI;
                        end

                        4'hA: begin // JZ addr
                            if (z_flag)
                                pc <= addr;
                            else
                                pc <= pc + 8'd2;
                            state <= FETCH_HI;
                        end

                        default: begin // Unknown opcode — treat as NOP
                            pc    <= pc + 8'd2;
                            state <= FETCH_HI;
                        end
                    endcase
                end

                // -----------------------------------------------------
                // MEM_READ — read a single byte from shared memory
                // -----------------------------------------------------
                MEM_READ: begin
                    mem_read <= mem[addr];
                    state    <= WRITEBACK;
                end

                // -----------------------------------------------------
                // WRITEBACK — finish a load into the register file
                // -----------------------------------------------------
                WRITEBACK: begin
                    regfile[rd_idx] <= mem_read;
                    z_flag          <= (mem_read == 8'd0);
                    state           <= FETCH_HI;
                end

                default: begin
                    state <= FETCH_HI;
                end
            endcase
        end
    end

endmodule
