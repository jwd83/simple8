// ============================================================================
//  Simple8MVB-TN20K — A Tang Nano 20K friendly byte-addressable multicycle CPU
//
//  Quick overview
//  ──────────────
//  • 8-bit data path with 32-bit instructions
//  • 16-bit program counter and 16-bit shared memory address bus
//  • Von Neumann organization: one shared 64 KiB byte-addressable memory
//  • 4-byte instruction fetch over a single shared memory port
//  • Memory layout is chosen to fit cleanly into Tang Nano 20K block RAM
//
//  Memory layout
//  ──────────────────────────────────────
//  Byte-addressable: 65536 bytes (addresses 0x0000–0xFFFF).
//  Instructions occupy four consecutive bytes, big-endian:
//      mem[pc + 0] = opcode | rd | rs
//      mem[pc + 1] = imm8
//      mem[pc + 2] = addr16[15:8]
//      mem[pc + 3] = addr16[7:0]
//
//  Data loads and stores operate on a single byte.
//
//  Instruction encoding (stored across four bytes, big-endian)
//  ───────────────────────────────────────────────────────────────────────────
//   Byte 0 (mem[PC+0]):  7  6  5  4 | 3  2 | 1  0
//                           opcode  |  rd  |  rs
//
//   Byte 1 (mem[PC+1]):  7  6  5  4  3  2  1  0
//                                 imm8
//
//   Byte 2 (mem[PC+2]):  addr16[15:8]
//   Byte 3 (mem[PC+3]):  addr16[7:0]
//  ───────────────────────────────────────────────────────────────────────────
//
//  Instruction set
//  ──────────────────────────────────────────────────────
//   Opcode  Name   Action                    Flags
//   0x0     NOP    do nothing                —
//   0x1     ADD    rd = rd + rs              Z
//   0x2     SUB    rd = rd - rs              Z
//   0x3     AND    rd = rd & rs              Z
//   0x4     OR     rd = rd | rs              Z
//   0x5     XOR    rd = rd ^ rs              Z
//   0x6     LDI    rd = imm8                 Z
//   0x7     LD     rd = MEM[addr16]          Z
//   0x8     ST     MEM[addr16] = rd          —
//   0x9     JMP    pc = addr16               —
//   0xA     JZ     if Z: pc = addr16         —
//  ──────────────────────────────────────────────────────
//
//  Notes
//  ──────────────────────────────────────────────────────
//  • LDI keeps the original 8-bit immediate because the register file is 8-bit.
//  • LD, ST, JMP, and JZ now use the full 16-bit address field.
//  • Jump targets should be multiples of 4 for valid instruction fetch.
//
// ============================================================================

module simple8mvbtn20k_cpu (
    input  logic clk,
    input  logic reset
);

    localparam int ADDR_WIDTH = 16;
    localparam int MEM_BYTES  = 1 << ADDR_WIDTH;

    // ─── Architectural state ─────────────────────────────────────────────

    logic [15:0] pc;                     // byte address of current instruction
    logic [7:0]  regfile [0:3];          // registers R0–R3
    logic        z_flag;                 // zero flag

    // ─── Shared memory ───────────────────────────────────────────────────

    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    logic [7:0] mem [0:MEM_BYTES-1];     // one shared 64 KiB byte-addressable memory

    // ─── Multicycle control ──────────────────────────────────────────────

    typedef enum logic [2:0] {
        FETCH_B0,
        FETCH_B1,
        FETCH_B2,
        FETCH_B3,
        EXECUTE,
        MEM_READ,
        WRITEBACK
    } state_t;

    state_t state;

    // ─── Instruction register and decoded fields ────────────────────────

    logic [7:0]  instr_b0;
    logic [7:0]  instr_b1;
    logic [7:0]  instr_b2;
    logic [7:0]  instr_b3;

    logic [3:0]  opcode;
    logic [1:0]  rd_idx;
    logic [1:0]  rs_idx;
    logic [7:0]  imm8;
    logic [15:0] addr16;

    // ─── Internal registers and wires ────────────────────────────────────

    logic [7:0]  mem_read;
    logic [15:0] mem_addr;               // shared memory read/write address bus
    logic [15:0] next_pc_seq;

    assign opcode      = instr_b0[7:4];
    assign rd_idx      = instr_b0[3:2];
    assign rs_idx      = instr_b0[1:0];
    assign imm8        = instr_b1;
    assign addr16      = {instr_b2, instr_b3};
    assign next_pc_seq = pc + 16'd4;

    always_comb begin
        case (state)
            FETCH_B0: mem_addr = pc;
            FETCH_B1: mem_addr = pc + 16'd1;
            FETCH_B2: mem_addr = pc + 16'd2;
            FETCH_B3: mem_addr = pc + 16'd3;
            default:  mem_addr = addr16;
        endcase
    end

    // =====================================================================
    //  PROGRAM IMAGE — initialized once so synthesis can map memory to BRAM
    // =====================================================================

    initial begin
        for (int i = 0; i < MEM_BYTES; i++) begin
            mem[i] = 8'h00;
        end

        // LDI R0, 5
        mem[16'h0000] = 8'h60;
        mem[16'h0001] = 8'h05;
        mem[16'h0002] = 8'h00;
        mem[16'h0003] = 8'h00;

        // LDI R1, 3
        mem[16'h0004] = 8'h64;
        mem[16'h0005] = 8'h03;
        mem[16'h0006] = 8'h00;
        mem[16'h0007] = 8'h00;

        // ADD R0, R1
        mem[16'h0008] = 8'h11;
        mem[16'h0009] = 8'h00;
        mem[16'h000A] = 8'h00;
        mem[16'h000B] = 8'h00;

        // ST [0x8000], R0
        mem[16'h000C] = 8'h80;
        mem[16'h000D] = 8'h00;
        mem[16'h000E] = 8'h80;
        mem[16'h000F] = 8'h00;

        // LD R2, [0x8000]
        mem[16'h0010] = 8'h78;
        mem[16'h0011] = 8'h00;
        mem[16'h0012] = 8'h80;
        mem[16'h0013] = 8'h00;

        // SUB R2, R1
        mem[16'h0014] = 8'h29;
        mem[16'h0015] = 8'h00;
        mem[16'h0016] = 8'h00;
        mem[16'h0017] = 8'h00;

        // LDI R3, 5
        mem[16'h0018] = 8'h6C;
        mem[16'h0019] = 8'h05;
        mem[16'h001A] = 8'h00;
        mem[16'h001B] = 8'h00;

        // SUB R2, R3
        mem[16'h001C] = 8'h2B;
        mem[16'h001D] = 8'h00;
        mem[16'h001E] = 8'h00;
        mem[16'h001F] = 8'h00;

        // JZ 0x0028
        mem[16'h0020] = 8'hA0;
        mem[16'h0021] = 8'h00;
        mem[16'h0022] = 8'h00;
        mem[16'h0023] = 8'h28;

        // JMP 0x0024
        mem[16'h0024] = 8'h90;
        mem[16'h0025] = 8'h00;
        mem[16'h0026] = 8'h00;
        mem[16'h0027] = 8'h24;

        // NOP
        mem[16'h0028] = 8'h00;
        mem[16'h0029] = 8'h00;
        mem[16'h002A] = 8'h00;
        mem[16'h002B] = 8'h00;

        // Example scratch byte
        mem[16'h8000] = 8'h00;
    end

    // =====================================================================
    //  STATE MACHINE — advance one micro-step per clock
    // =====================================================================

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            pc         <= 16'd0;
            z_flag     <= 1'b0;
            state      <= FETCH_B0;
            instr_b0   <= 8'h00;
            instr_b1   <= 8'h00;
            instr_b2   <= 8'h00;
            instr_b3   <= 8'h00;
            mem_read   <= 8'd0;

            regfile[0] <= 8'd0;
            regfile[1] <= 8'd0;
            regfile[2] <= 8'd0;
            regfile[3] <= 8'd0;
        end else begin
            case (state)

                FETCH_B0: begin
                    instr_b0 <= mem[mem_addr];
                    state    <= FETCH_B1;
                end

                FETCH_B1: begin
                    instr_b1 <= mem[mem_addr];
                    state    <= FETCH_B2;
                end

                FETCH_B2: begin
                    instr_b2 <= mem[mem_addr];
                    state    <= FETCH_B3;
                end

                FETCH_B3: begin
                    instr_b3 <= mem[mem_addr];
                    state    <= EXECUTE;
                end

                EXECUTE: begin
                    case (opcode)
                        4'h0: begin // NOP
                            pc    <= next_pc_seq;
                            state <= FETCH_B0;
                        end

                        4'h1: begin // ADD rd, rs
                            regfile[rd_idx] <= regfile[rd_idx] + regfile[rs_idx];
                            z_flag          <= ((regfile[rd_idx] + regfile[rs_idx]) == 8'd0);
                            pc              <= next_pc_seq;
                            state           <= FETCH_B0;
                        end

                        4'h2: begin // SUB rd, rs
                            regfile[rd_idx] <= regfile[rd_idx] - regfile[rs_idx];
                            z_flag          <= ((regfile[rd_idx] - regfile[rs_idx]) == 8'd0);
                            pc              <= next_pc_seq;
                            state           <= FETCH_B0;
                        end

                        4'h3: begin // AND rd, rs
                            regfile[rd_idx] <= regfile[rd_idx] & regfile[rs_idx];
                            z_flag          <= ((regfile[rd_idx] & regfile[rs_idx]) == 8'd0);
                            pc              <= next_pc_seq;
                            state           <= FETCH_B0;
                        end

                        4'h4: begin // OR rd, rs
                            regfile[rd_idx] <= regfile[rd_idx] | regfile[rs_idx];
                            z_flag          <= ((regfile[rd_idx] | regfile[rs_idx]) == 8'd0);
                            pc              <= next_pc_seq;
                            state           <= FETCH_B0;
                        end

                        4'h5: begin // XOR rd, rs
                            regfile[rd_idx] <= regfile[rd_idx] ^ regfile[rs_idx];
                            z_flag          <= ((regfile[rd_idx] ^ regfile[rs_idx]) == 8'd0);
                            pc              <= next_pc_seq;
                            state           <= FETCH_B0;
                        end

                        4'h6: begin // LDI rd, imm8
                            regfile[rd_idx] <= imm8;
                            z_flag          <= (imm8 == 8'd0);
                            pc              <= next_pc_seq;
                            state           <= FETCH_B0;
                        end

                        4'h7: begin // LD rd, [addr16]
                            pc    <= next_pc_seq;
                            state <= MEM_READ;
                        end

                        4'h8: begin // ST [addr16], rd
                            mem[mem_addr] <= regfile[rd_idx];
                            pc            <= next_pc_seq;
                            state         <= FETCH_B0;
                        end

                        4'h9: begin // JMP addr16
                            pc    <= addr16;
                            state <= FETCH_B0;
                        end

                        4'hA: begin // JZ addr16
                            if (z_flag)
                                pc <= addr16;
                            else
                                pc <= next_pc_seq;
                            state <= FETCH_B0;
                        end

                        default: begin
                            pc    <= next_pc_seq;
                            state <= FETCH_B0;
                        end
                    endcase
                end

                MEM_READ: begin
                    mem_read <= mem[mem_addr];
                    state    <= WRITEBACK;
                end

                WRITEBACK: begin
                    regfile[rd_idx] <= mem_read;
                    z_flag          <= (mem_read == 8'd0);
                    state           <= FETCH_B0;
                end

                default: begin
                    state <= FETCH_B0;
                end
            endcase
        end
    end

endmodule
