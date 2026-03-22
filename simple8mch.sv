// ============================================================================
//  Simple8MCH — A tiny multicycle Harvard CPU for learning computer architecture
//
//  Quick overview
//  ──────────────
//  • Same instruction set as Simple8
//  • Multicycle control: fetch, decode, execute, memory, writeback
//  • Harvard organization: separate instruction ROM and data RAM
//  • Memory access is synchronous, which maps more naturally to FPGA block RAM
//
//  Why this version exists
//  ───────────────────────
//  The original Simple8 is single-cycle, which is easy to read, but it models
//  memory like a combinational lookup table. This version stretches each
//  instruction across a few clock cycles so instruction fetch and data loads can
//  happen through clocked memory reads instead.
//
//  Instruction encoding
//  ──────────────────────────────────────────────────────
//   15  14  13  12 | 11  10 |  9   8 |  7  6  5  4  3  2  1  0
//      opcode      |   rd   |   rs   |         imm8
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
//   0x6     LDI    rd = imm8               Z
//   0x7     LD     rd = RAM[imm8]          Z
//   0x8     ST     RAM[imm8] = rd          —
//   0x9     JMP    pc = imm8               —
//   0xA     JZ     if Z: pc = imm8         —
//  ──────────────────────────────────────────────────────
//
//  Note: LDI uses the full 8-bit immediate (values 0–255).
//        Memory and jump addresses use the low 5 bits (addresses 0–31).
//
// ============================================================================

module simple8mch_cpu (
    input  logic clk,
    input  logic reset
);

    // ─── Architectural state ─────────────────────────────────────────────

    logic [4:0]  pc;                    // program counter (addresses 0–31)
    logic [7:0]  regfile [0:3];         // registers R0–R3
    logic        z_flag;                // zero flag

    // ─── Memory ──────────────────────────────────────────────────────────

    logic [15:0] instr_mem [0:31];      // 32 × 16-bit instruction memory
    logic [7:0]  data_mem  [0:31];      // 32 × 8-bit  data memory

    // ─── Multicycle control ──────────────────────────────────────────────

    typedef enum logic [2:0] {
        FETCH,                          // read instruction memory
        DECODE,                         // split instruction into fields
        EXECUTE,                        // do ALU work, stores, and branches
        MEM_READ,                       // wait for a synchronous data read
        WRITEBACK                       // finish a load
    } state_t;

    state_t state;

    // ─── Instruction register and decoded fields ────────────────────────

    logic [15:0] instr;                 // current instruction
    logic [3:0]  opcode;                // bits [15:12]
    logic [1:0]  rd_idx;                // bits [11:10]
    logic [1:0]  rs_idx;                // bits  [9:8]
    logic [7:0]  imm8;                  // bits  [7:0]
    logic [4:0]  addr;                  // low 5 bits of imm8

    // ─── Internal registers ──────────────────────────────────────────────

    logic [7:0]  alu_result;            // result from an ALU instruction
    logic [7:0]  mem_read;              // value returned by a load

    assign opcode = instr[15:12];
    assign rd_idx = instr[11:10];
    assign rs_idx = instr[9:8];
    assign imm8   = instr[7:0];
    assign addr   = imm8[4:0];

    // =====================================================================
    //  STATE MACHINE — advance one micro-step per clock
    // =====================================================================

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            // Clear the processor state
            pc       <= 5'd0;
            z_flag   <= 1'b0;
            state    <= FETCH;
            instr    <= 16'h0000;
            alu_result <= 8'd0;
            mem_read <= 8'd0;

            regfile[0] <= 8'd0;
            regfile[1] <= 8'd0;
            regfile[2] <= 8'd0;
            regfile[3] <= 8'd0;

            // Clear data memory
            for (int i = 0; i < 32; i++) begin
                data_mem[i] <= 8'd0;
            end

            // ─────────────────────────────────────────────────────────
            //  Example program: same as Simple8.
            // ─────────────────────────────────────────────────────────

            instr_mem[5'h00] <= 16'h6005;  // LDI R0, 5
            instr_mem[5'h01] <= 16'h6503;  // LDI R1, 3
            instr_mem[5'h02] <= 16'h1100;  // ADD R0, R1
            instr_mem[5'h03] <= 16'h8010;  // ST  [0x10], R0
            instr_mem[5'h04] <= 16'h7810;  // LD  R2, [0x10]
            instr_mem[5'h05] <= 16'h2900;  // SUB R2, R1
            instr_mem[5'h06] <= 16'h6F05;  // LDI R3, 5
            instr_mem[5'h07] <= 16'h2B00;  // SUB R2, R3
            instr_mem[5'h08] <= 16'hA00A;  // JZ  0x0A
            instr_mem[5'h09] <= 16'h9009;  // JMP 0x09
            instr_mem[5'h0A] <= 16'h0000;  // NOP

            for (int i = 11; i < 32; i++) begin
                instr_mem[i] <= 16'h0000;
            end

        end else begin
            case (state)

                // -----------------------------------------------------
                // FETCH — synchronous instruction read
                // -----------------------------------------------------
                FETCH: begin
                    instr  <= instr_mem[pc];
                    state  <= DECODE;
                end

                // -----------------------------------------------------
                // DECODE — break the instruction into fields
                // -----------------------------------------------------
                DECODE: begin
                    state <= EXECUTE;
                end

                // -----------------------------------------------------
                // EXECUTE — do the main work of the instruction
                // -----------------------------------------------------
                EXECUTE: begin
                    case (opcode)
                        4'h0: begin // NOP
                            pc    <= pc + 5'd1;
                            state <= FETCH;
                        end

                        4'h1: begin // ADD rd, rs
                            alu_result      <= regfile[rd_idx] + regfile[rs_idx];
                            regfile[rd_idx] <= regfile[rd_idx] + regfile[rs_idx];
                            z_flag          <= ((regfile[rd_idx] + regfile[rs_idx]) == 8'd0);
                            pc              <= pc + 5'd1;
                            state           <= FETCH;
                        end

                        4'h2: begin // SUB rd, rs
                            alu_result      <= regfile[rd_idx] - regfile[rs_idx];
                            regfile[rd_idx] <= regfile[rd_idx] - regfile[rs_idx];
                            z_flag          <= ((regfile[rd_idx] - regfile[rs_idx]) == 8'd0);
                            pc              <= pc + 5'd1;
                            state           <= FETCH;
                        end

                        4'h3: begin // AND rd, rs
                            alu_result      <= regfile[rd_idx] & regfile[rs_idx];
                            regfile[rd_idx] <= regfile[rd_idx] & regfile[rs_idx];
                            z_flag          <= ((regfile[rd_idx] & regfile[rs_idx]) == 8'd0);
                            pc              <= pc + 5'd1;
                            state           <= FETCH;
                        end

                        4'h4: begin // OR rd, rs
                            alu_result      <= regfile[rd_idx] | regfile[rs_idx];
                            regfile[rd_idx] <= regfile[rd_idx] | regfile[rs_idx];
                            z_flag          <= ((regfile[rd_idx] | regfile[rs_idx]) == 8'd0);
                            pc              <= pc + 5'd1;
                            state           <= FETCH;
                        end

                        4'h5: begin // XOR rd, rs
                            alu_result      <= regfile[rd_idx] ^ regfile[rs_idx];
                            regfile[rd_idx] <= regfile[rd_idx] ^ regfile[rs_idx];
                            z_flag          <= ((regfile[rd_idx] ^ regfile[rs_idx]) == 8'd0);
                            pc              <= pc + 5'd1;
                            state           <= FETCH;
                        end

                        4'h6: begin // LDI rd, imm8
                            regfile[rd_idx] <= imm8;
                            z_flag          <= (imm8 == 8'd0);
                            pc              <= pc + 5'd1;
                            state           <= FETCH;
                        end

                        4'h7: begin // LD rd, [addr]
                            pc    <= pc + 5'd1;
                            state <= MEM_READ;
                        end

                        4'h8: begin // ST [addr], rd
                            data_mem[addr] <= regfile[rd_idx];
                            pc             <= pc + 5'd1;
                            state          <= FETCH;
                        end

                        4'h9: begin // JMP addr
                            pc    <= addr;
                            state <= FETCH;
                        end

                        4'hA: begin // JZ addr
                            if (z_flag)
                                pc <= addr;
                            else
                                pc <= pc + 5'd1;
                            state <= FETCH;
                        end

                        default: begin // Unknown opcode — treat as NOP
                            pc    <= pc + 5'd1;
                            state <= FETCH;
                        end
                    endcase
                end

                // -----------------------------------------------------
                // MEM_READ — synchronous data memory read
                // -----------------------------------------------------
                MEM_READ: begin
                    mem_read <= data_mem[addr];
                    state    <= WRITEBACK;
                end

                // -----------------------------------------------------
                // WRITEBACK — finish a load into the register file
                // -----------------------------------------------------
                WRITEBACK: begin
                    regfile[rd_idx] <= mem_read;
                    z_flag          <= (mem_read == 8'd0);
                    state           <= FETCH;
                end

                default: begin
                    state <= FETCH;
                end
            endcase
        end
    end

endmodule
