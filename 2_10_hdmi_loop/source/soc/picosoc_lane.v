`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:  Ziguang Tongchuang Competition
// Engineer:
//
// Create Date: 2026-10-19
// Module Name: picosoc_lane
// Description: PicoRV32 SoC —— 决策层 (基础任务2 的 MCU 角色)
//
//   在 Clifford Wolf 的 picosoc 基础上改写, 增加了到 reg_bank 的总线接口。
//   原来的 SPI 从机前端不再需要: 软核片内直连寄存器组, 没有 SPI 带宽限制,
//   也不需要外部接线。
//
//   【存储器映射】
//     0x0000_0000 - 0x0000_7FFF   32 KB RAM (MEM_WORDS = 8192 字)
//                                 程序从 0x1000 开始 (复位向量)
//     0x0000_8000                 UART 分频寄存器
//     0x0000_8010                 UART 数据寄存器
//     0x0000_8020 - 0x0000_841F   reg_bank, 共 256 个 32 位寄存器
//                                 地址 = 0x8020 + (reg_index << 2)
//     0x0000_8420                 调试 LED (低 8 位)
//
//   【总线时序】
//     RAM 是 1 周期响应; UART / reg_bank / LED 是组合响应(0 等待)。
//     这与 vendor 原版 picosoc 的写法一致, 是经过验证的模式。
//
//   【时钟】
//     本模块不产生时钟。clk 建议 50 MHz; 先用 10 MHz 也能跑(决策逻辑每帧
//     只有几百个点, 10MHz 完全够), 等确认功能后再提速。
//
//   【跨时钟域】
//     reg_bank 必须和本模块同处 clk 域。它输出的配置信号(mode/edge_thr/...)
//     是准静态的, 用两级触发器同步到像素时钟域即可; 状态输入(h_act/v_act/
//     frame_cnt)同理反向同步。这些同步器放在 hdmi_loop.v 里做。
//
//////////////////////////////////////////////////////////////////////////////////

module picosoc_lane #(
    parameter integer MEM_WORDS = 8192,             // 32 KB
    parameter [31:0]  PROGADDR_RESET = 32'h0000_1000,
    parameter [31:0]  PROGADDR_IRQ   = 32'h0000_0000
)(
    input               clk,
    input               resetn,                     // 低有效

    // ---- UART (接板载 CP2102: RXD=B24, TXD=C24) ----
    output              ser_tx,
    input               ser_rx,

    // ---- 寄存器总线 (接 reg_bank, 同一时钟域) ----
    output reg [ 7:0]   rb_addr,
    output reg [31:0]   rb_wdata,
    output reg          rb_we,
    output reg          rb_re,
    input      [31:0]   rb_rdata,

    // ---- 状态 ----
    output     [ 7:0]   led,
    output              cpu_trap
);

    //==========================================================================
    //  1. 复位同步
    //==========================================================================
    reg [3:0] reset_cnt = 4'd0;
    wire      resetn_sys = &reset_cnt;

    always @(posedge clk) begin
        if(!resetn)      reset_cnt <= 4'd0;
        else if(!resetn_sys) reset_cnt <= reset_cnt + 1'b1;
    end

    //==========================================================================
    //  2. CPU
    //==========================================================================
    wire        mem_valid;
    wire        mem_instr;
    wire        mem_ready;
    wire [31:0] mem_addr;
    wire [31:0] mem_wdata;
    wire [ 3:0] mem_wstrb;
    wire [31:0] mem_rdata;

    picorv32 #(
        .STACKADDR       ( 4*MEM_WORDS           ),
        .PROGADDR_RESET  ( PROGADDR_RESET        ),
        .PROGADDR_IRQ    ( PROGADDR_IRQ          ),
        .BARREL_SHIFTER  ( 1                     ),
        .COMPRESSED_ISA  ( 1                     ),
        .ENABLE_MUL      ( 1                     ),
        .ENABLE_DIV      ( 1                     ),
        .ENABLE_IRQ      ( 0                     )
    ) cpu (
        .clk         ( clk          ),
        .resetn      ( resetn_sys   ),
        .trap        ( cpu_trap     ),
        .mem_valid   ( mem_valid    ),
        .mem_instr   ( mem_instr    ),
        .mem_ready   ( mem_ready    ),
        .mem_addr    ( mem_addr     ),
        .mem_wdata   ( mem_wdata    ),
        .mem_wstrb   ( mem_wstrb    ),
        .mem_rdata   ( mem_rdata    ),
        .irq         ( 32'd0        )
    );

    //==========================================================================
    //  3. 地址译码
    //==========================================================================
    localparam [31:0] RAM_END   = 32'h0000_8000;
    localparam [31:0] UART_DIV  = 32'h0000_8000;
    localparam [31:0] UART_DAT  = 32'h0000_8010;
    localparam [31:0] RB_BASE   = 32'h0000_8020;
    localparam [31:0] RB_END    = 32'h0000_8420;
    localparam [31:0] LED_ADDR  = 32'h0000_8420;

    wire ram_sel  = mem_valid && (mem_addr <  RAM_END);
    wire udiv_sel = mem_valid && (mem_addr == UART_DIV);
    wire udat_sel = mem_valid && (mem_addr == UART_DAT);
    wire rb_sel   = mem_valid && (mem_addr >= RB_BASE) && (mem_addr < RB_END);
    wire led_sel  = mem_valid && (mem_addr == LED_ADDR);

    //==========================================================================
    //  4. RAM (32 KB, 程序从 0x1000 开始)
    //==========================================================================
    reg [31:0] memory [0:MEM_WORDS-1] /* synthesis syn_ramstyle = "block_ram" */;

    initial begin
        $readmemh("firmware.hex", memory, PROGADDR_RESET >> 2);
    end

    reg        ram_ready;
    reg [31:0] ram_rdata;
    wire       ram_en = ram_sel && !mem_ready;
    wire [12:0] widx  = mem_addr[14:2];

    always @(posedge clk) begin
        ram_ready <= 1'b0;
        if(ram_en) ram_ready <= 1'b1;
    end

    always @(posedge clk) begin
        if(ram_en) ram_rdata <= memory[widx];
    end

    always @(posedge clk) begin
        if(ram_en) begin
            if(mem_wstrb[0]) memory[widx][ 7: 0] <= mem_wdata[ 7: 0];
            if(mem_wstrb[1]) memory[widx][15: 8] <= mem_wdata[15: 8];
            if(mem_wstrb[2]) memory[widx][23:16] <= mem_wdata[23:16];
            if(mem_wstrb[3]) memory[widx][31:24] <= mem_wdata[31:24];
        end
    end

    //==========================================================================
    //  5. UART (simpleuart, vendor 原样使用)
    //==========================================================================
    wire [31:0] uart_dat_do;
    wire        uart_dat_wait;

    simpleuart simpleuart (
        .clk          ( clk                  ),
        .resetn       ( resetn_sys           ),
        .ser_tx       ( ser_tx               ),
        .ser_rx       ( ser_rx               ),
        .reg_div_we   ( udiv_sel ? mem_wstrb : 4'b0000 ),
        .reg_div_di   ( mem_wdata            ),
        .reg_div_do   (                      ),
        .reg_dat_we   ( udat_sel ? mem_wstrb[0] : 1'b0 ),
        .reg_dat_re   ( udat_sel && !(|mem_wstrb) ),
        .reg_dat_di   ( mem_wdata            ),
        .reg_dat_do   ( uart_dat_do          ),
        .reg_dat_wait ( uart_dat_wait        )
    );

    //==========================================================================
    //  6. 寄存器组接口
    //     0 等待响应: 地址组合送给 reg_bank, 读写使能组合产生。
    //     这个模式与 vendor 原版 picosoc 里 GPIO 的处理完全一致。
    //==========================================================================
    // 注意地址换算: 必须用 "先减基址、再右移两位"。
    // 直接取 mem_addr[9:2] 是错的 —— 那只是截了低 10 位, RB_BASE=0x8020
    // 会让结果整体偏移 8, 而且高位地址也丢掉了。
    // 正确: off = mem_addr - 0x8020, rb_addr = off[9:2], 范围 0..255。
    wire [31:0] rb_off = mem_addr - RB_BASE;

    always @(*) begin
        rb_addr  = rb_off[9:2];
        rb_wdata = mem_wdata;
        rb_we    = rb_sel && (|mem_wstrb);
        rb_re    = rb_sel && !(|mem_wstrb);
    end

    //==========================================================================
    //  7. 调试 LED
    //==========================================================================
    reg [7:0] led_r;

    always @(posedge clk) begin
        if(!resetn_sys)  led_r <= 8'd0;
        else if(led_sel) led_r <= mem_wdata[7:0];
    end

    assign led = led_r;

    //==========================================================================
    //  8. 总线仲裁
    //==========================================================================
    // UART 数据寄存器必须等它空闲: simpleuart 只在 send_bitcnt==0 时接收
    // 写入, 忙的时候直接丢弃。所以这里用 uart_dat_wait 把总线停住,
    // CPU 会一直保持写使能直到 UART 腾出空。
    assign mem_ready = ram_ready || udiv_sel
                       || (udat_sel && !uart_dat_wait)
                       || rb_sel || led_sel;

    assign mem_rdata = ram_ready ? ram_rdata :
                       rb_sel    ? rb_rdata :
                       udat_sel  ? uart_dat_do :
                       udiv_sel  ? 32'h0 :
                       32'h0;

endmodule
