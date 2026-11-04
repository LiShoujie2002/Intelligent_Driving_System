`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:  Ziguang Tongchuang Competition
// Engineer:
//
// Create Date: 2026-10-16
// Module Name: reg_bank
// Description: 寄存器组 —— MCU 与 FPGA 之间的全部接口 (基础任务2)
//
//   【设计原则】
//   MCU 只碰"结果"和"参数", 永远不碰像素。数据量对比:
//     视频流     148.5M 像素/秒 × 24bit ≈ 3.6 Gbit/s
//     寄存器访问  每帧几十字节           ≈ 数 KB/s
//   差 6~7 个数量级, 所以两条路必须分开。
//
//   【读是组合的】
//   读通路不寄存(纯 case 多路选择), 这样 SPI / FMC 前端可以在同一个时钟周期
//   里取到数据, 不需要等待。写通路是同步寄存的。
//
//   【时钟域】
//   整个模块跑在 clk 上。SPI/FMC 前端也在同一时钟域里采样外部信号
//   (外部总线远慢于像素时钟, 直接采样即可, 不需要 CDC)。
//
//   【寄存器映射】
//     0x00  R    0x504E4750           魔术字 "PNGP", MCU 用它确认链路通
//     0x04  R    {v_act, h_act}       当前输入分辨率
//     0x08  R    {frame_cnt, 15'b0, stable}
//     0x0C  R    {24'b0, det_cnt}     检测到的目标数量 (预留)
//     0x10  RW   {28'b0, en, bypass, mode}
//     0x14  RW   {24'b0, edge_thr}
//     0x18  RW   {8'b0, roi_bot, roi_top}
//     0x1C  RW   {24'b0, lane_w}
//     0x20  RW   {24'b0, led}
//
//////////////////////////////////////////////////////////////////////////////////

module reg_bank (
    input               clk,
    input               rstn,

    // ---- 总线侧 (由 spi_slave / fmc_slave 驱动, 同一时钟域) ----
    input      [7:0]    addr,
    input      [31:0]   wdata,
    input               we,
    input               re,
    output reg [31:0]   rdata,

    // ---- 状态输入 (硬件 → 寄存器) ----
    input      [11:0]   h_act,
    input      [11:0]   v_act,
    input      [15:0]   frame_cnt,
    input               video_stable,
    input      [7:0]    det_cnt,
    input      [15:0]   dbg_line,        // 诊断: 行结束计数

    // ---- 配置输出 (寄存器 → 硬件) ----
    output reg          cfg_en,          // 整个图像处理通路的使能
    output reg          cfg_bypass,      // 1 = 旁路, 输出等于输入
    output reg [1:0]    cfg_mode,        // 0=原图 1=纯边缘 2=叠加 3=车道线
    output reg [7:0]    cfg_edge_thr,    // 边缘阈值
    output reg [11:0]   cfg_roi_top,
    output reg [11:0]   cfg_roi_bot,
    output reg [7:0]    cfg_lane_w,      // 画线半宽
    output reg [7:0]    cfg_led           // LED / 报警指示
);

    localparam [31:0] MAGIC = 32'h504E_4750;   // "PNGP"

    //==========================================================================
    //  写通路 (同步)
    //  复位值就是"没有 MCU 时的默认工作状态", 所以即使 MCU 不接也能正常出图
    //==========================================================================
    always @(posedge clk) begin
        if(!rstn) begin
            cfg_en       <= 1'b1;
            cfg_bypass   <= 1'b0;
            cfg_mode     <= 2'd2;          // 默认: 边缘叠加
            cfg_edge_thr <= 8'd48;
            cfg_roi_top  <= 12'd464;
            cfg_roi_bot  <= 12'd719;
            cfg_lane_w   <= 8'd6;
            cfg_led      <= 8'd0;
        end
        else if(we) begin
            case(addr)
                8'h10: begin
                    cfg_mode   <= wdata[1:0];
                    cfg_bypass <= wdata[2];
                    cfg_en     <= wdata[3];
                end
                8'h14: cfg_edge_thr <= wdata[7:0];
                8'h18: begin
                    cfg_roi_top <= wdata[11:0];
                    cfg_roi_bot <= wdata[23:12];
                end
                8'h1C: cfg_lane_w   <= wdata[7:0];
                8'h20: cfg_led      <= wdata[7:0];
                default: ;                 // 只读寄存器忽略写
            endcase
        end
    end

    //==========================================================================
    //  读通路 (组合, 不寄存)
    //==========================================================================
    always @(*) begin
        case(addr)
            8'h00:   rdata = MAGIC;
            8'h04:   rdata = {8'b0, v_act, h_act};
            8'h08:   rdata = {frame_cnt, 15'b0, video_stable};
            8'h0C:   rdata = {24'b0, det_cnt};
            8'h24:   rdata = {16'b0, dbg_line};
            8'h10:   rdata = {28'b0, cfg_en, cfg_bypass, cfg_mode};
            8'h14:   rdata = {24'b0, cfg_edge_thr};
            8'h18:   rdata = {8'b0, cfg_roi_bot, cfg_roi_top};
            8'h1C:   rdata = {24'b0, cfg_lane_w};
            8'h20:   rdata = {24'b0, cfg_led};
            default: rdata = 32'hDEAD_BEEF;   // 未实现地址, 便于 MCU 侧排查
        endcase
    end

endmodule
