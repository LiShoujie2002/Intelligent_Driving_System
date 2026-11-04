`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: net_rx_path
// Description: 接收通路 + 跨时钟域（网络域 → 像素域）
//
//   net_clk 域:  eth_rx ──► eth_udp_rx ──► eth_app_rx ──► 框表
//                                                          │ toggle 握手
//   pix_clk 域:  同步 toggle，检测到更新就把整张框表搬进像素域寄存器
//
//   【为什么用 toggle + 总线，而不是逐位同步】
//   框表有 2560 bit，逐位两级同步要 5120 个触发器；而且多 bit 逐位同步
//   不保证同一拍一起变。这里框表在一帧内保持不变，用"数据稳定 + toggle 握手"
//   的方式：网络域更新时翻转 toggle，像素域同步到 toggle 跳变后再采样总线，
//   这时数据早已稳定，是安全的。
//
//   一次更新到下一次至少隔一帧（~50ms），像素域采样只要几拍，不会撞上。
//////////////////////////////////////////////////////////////////////////////////

module net_rx_path #(
    parameter MAXBOX = 32,
    parameter [47:0] MY_MAC  = 48'hA0_B1_C2_D3_E1_E1,
    parameter [31:0] MY_IP   = 32'hC0_A8_01_0B,
    parameter [15:0] MY_PORT = 16'd5002
)(
    // ---- 网络域 ----
    input                     net_clk,
    input                     net_rstn,
    input                     rx_dv,
    input      [7:0]          rx_data,

    // ---- 像素域 ----
    input                     pix_clk,
    input                     pix_rstn,
    output reg [31:0]         o_fid,
    output reg [7:0]          o_nbox,
    output reg [MAXBOX*16-1:0] o_x1,
    output reg [MAXBOX*16-1:0] o_y1,
    output reg [MAXBOX*16-1:0] o_x2,
    output reg [MAXBOX*16-1:0] o_y2,
    output reg [MAXBOX*8-1:0]  o_cls,
    output reg [MAXBOX*8-1:0]  o_sub,     // 子类: 交通灯颜色
    output reg [MAXBOX*8-1:0]  o_conf,
    output reg                o_new        // 像素域里"新结果就绪"单拍
);

    //==========================================================================
    //  网络域：三层解析
    //==========================================================================
    wire        b_dv;
    wire [7:0]  b_data;
    wire [10:0] b_idx;
    wire        b_sof, b_eof;

    eth_rx u_eth_rx (
        .clk      ( net_clk ),
        .rstn     ( net_rstn),
        .rx_dv    ( rx_dv   ),
        .rx_data  ( rx_data ),
        .dv       ( b_dv    ),
        .data     ( b_data  ),
        .byte_idx ( b_idx   ),
        .sof      ( b_sof   ),
        .eof      ( b_eof   )
    );

    wire        p_dv;
    wire [7:0]  p_data;
    wire [15:0] p_idx;
    wire        p_sof, p_last;
    wire [15:0] p_len;
    wire        p_end;
    wire        p_acc;

    eth_udp_rx #(
        .MY_MAC   ( MY_MAC   ),
        .MY_IP    ( MY_IP    ),
        .MY_PORT  ( MY_PORT  ),
        .CHECK_IP ( 0        )
    ) u_udp_rx (
        .clk       ( net_clk ),
        .rstn      ( net_rstn),
        .rx_dv     ( b_dv    ),
        .rx_data   ( b_data  ),
        .byte_idx  ( b_idx   ),
        .sof       ( b_sof   ),
        .eof       ( b_eof   ),
        .pay_dv    ( p_dv    ),
        .pay_data  ( p_data  ),
        .pay_idx   ( p_idx   ),
        .pay_sof   ( p_sof   ),
        .pay_last  ( p_last  ),
        .pay_len   ( p_len   ),
        .frame_end ( p_end   ),
        .accept    ( p_acc   )
    );

    wire        a_upd;
    wire [31:0] a_fid;
    wire [7:0]  a_nbox;
    wire [MAXBOX*16-1:0] a_x1, a_y1, a_x2, a_y2;
    wire [MAXBOX*8-1:0]  a_cls, a_sub, a_conf;

    eth_app_rx #(.MAXBOX(MAXBOX)) u_app_rx (
        .clk        ( net_clk ),
        .rstn       ( net_rstn),
        .pay_dv     ( p_dv    ),
        .pay_data   ( p_data  ),
        .pay_idx    ( p_idx   ),
        .frame_end  ( p_end   ),
        .update     ( a_upd   ),
        .o_frame_id ( a_fid   ),
        .o_nbox     ( a_nbox  ),
        .o_x1       ( a_x1    ),
        .o_y1       ( a_y1    ),
        .o_x2       ( a_x2    ),
        .o_y2       ( a_y2    ),
        .o_cls      ( a_cls   ),
        .o_sub      ( a_sub   ),
        .o_conf     ( a_conf  )
    );

    //==========================================================================
    //  toggle 握手（网络域 → 像素域）
    //==========================================================================
    reg upd_tog;

    always @(posedge net_clk) begin
        if(!net_rstn) upd_tog <= 1'b0;
        else if(a_upd) upd_tog <= ~upd_tog;
    end

    reg [2:0] tog_sync;
    wire      tog_edge = tog_sync[1] ^ tog_sync[2];

    always @(posedge pix_clk) begin
        if(!pix_rstn) begin
            tog_sync <= 3'b000;
            o_new    <= 1'b0;
            o_fid    <= 32'd0;
            o_nbox   <= 8'd0;
            o_x1     <= {(MAXBOX*16){1'b0}};
            o_y1     <= {(MAXBOX*16){1'b0}};
            o_x2     <= {(MAXBOX*16){1'b0}};
            o_y2     <= {(MAXBOX*16){1'b0}};
            o_cls    <= {(MAXBOX*8){1'b0}};
            o_sub    <= {(MAXBOX*8){1'b0}};
            o_conf   <= {(MAXBOX*8){1'b0}};
        end
        else begin
            tog_sync <= {tog_sync[1:0], upd_tog};
            o_new    <= 1'b0;

            if(tog_edge) begin
                o_fid  <= a_fid;
                o_nbox <= a_nbox;
                o_x1   <= a_x1;
                o_y1   <= a_y1;
                o_x2   <= a_x2;
                o_y2   <= a_y2;
                o_cls  <= a_cls;
                o_sub  <= a_sub;
                o_conf <= a_conf;
                o_new  <= 1'b1;
            end
        end
    end

endmodule
