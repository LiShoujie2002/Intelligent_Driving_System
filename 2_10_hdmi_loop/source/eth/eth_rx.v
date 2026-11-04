`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: eth_rx
// Description: 以太网帧接收 —— 剥前导码，给出字节流
//
//   【重要】RGMII 接收流里 **包含** 8 字节前导码(7x0x55 + 0xD5) 和 4 字节 FCS。
//   这一点在板上实测过：一个 60 字节的 ARP 帧，RX_CTL 高电平持续了
//   8 + 60 + 4 = 72 拍。所以这里必须跳过前 8 个字节。
//
//   【输出】
//     dv        字节有效（不含前导码，含 FCS）
//     data      字节
//     byte_idx  帧内字节序号，从 0 开始（0 = 目的 MAC 最高字节）
//     sof       第一个字节那一拍
//     eof       RX_CTL 下降沿那一拍（此时 dv 已经为 0）
//
//   注意：末 4 字节是 FCS，下游按 UDP 长度自行截断即可。
//
//////////////////////////////////////////////////////////////////////////////////

module eth_rx (
    input            clk,          // 125 MHz
    input            rstn,

    // ---- 来自 rgmii_interface ----
    input            rx_dv,
    input      [7:0] rx_data,

    // ---- 字节流 ----
    output           dv,
    output     [7:0] data,
    output    [10:0] byte_idx,
    output           sof,
    output reg       eof
);

    localparam [10:0] PRE_LEN = 11'd8;      // 前导码 + SFD

    reg [10:0] cnt;

    always @(posedge clk) begin
        if(!rstn)                 cnt <= 11'd0;
        else if(rx_dv)            cnt <= cnt + 11'd1;
        else                      cnt <= 11'd0;
    end

    // 组合输出：数据随 RX 流同拍，不做额外延迟，
    // 这样下游看到的 byte_idx 和 data 是直接对应的。
    assign dv       = rx_dv && (cnt >= PRE_LEN);
    assign data     = rx_data;
    assign byte_idx = cnt - PRE_LEN;
    assign sof      = dv && (cnt == PRE_LEN);

    reg rx_dv_d;

    always @(posedge clk) begin
        if(!rstn) rx_dv_d <= 1'b0;
        else      rx_dv_d <= rx_dv;
    end

    always @(posedge clk) begin
        if(!rstn) eof <= 1'b0;
        else      eof <= rx_dv_d && !rx_dv;
    end

endmodule
