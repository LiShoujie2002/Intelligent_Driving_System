`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: net_video_uplink
// Description: 视频上传通路（像素域 → 网络域）
//
//   ┌──────────── 像素域 pix_clk (74.25MHz) ────────────┐
//   │  de/r/g/b  ──► video_downsample ──► 写帧缓存       │
//   │  采集状态机 ──toggle──►                         ──┼──► 网络域
//   │            ◄──toggle──                          ◄─┼──  发送状态机
//   └───────────────────────────────────────────────────┘
//   ┌──────────── 网络域 net_clk (125MHz) ──────────────┐
//   │  读帧缓存 ──► eth_udp_video_tx ──► MAC 字节流      │
//   └───────────────────────────────────────────────────┘
//
//   帧缓存是真双口：写口在 pix_clk、读口在 net_clk。
//   帧与帧之间用 toggle 握手跨域，不用异步 FIFO。
//
//   这个模块在测试工程里已经过验证：
//   330 帧 640×360 逐字节一致（见 HANDOFF）。
//////////////////////////////////////////////////////////////////////////////////

module net_video_uplink #(
    parameter [15:0] IMG_W    = 16'd640,
    parameter [15:0] IMG_H    = 16'd360,
    parameter [15:0] SRC_W    = 16'd1280,
    parameter [15:0] SRC_H    = 16'd720,
    parameter [15:0] DATA_PER = 16'd1440,
    parameter [23:0] PKT_GAP  = 24'd11000,
    parameter [47:0] SRC_MAC  = 48'hA0_B1_C2_D3_E1_E1,
    parameter [31:0] SRC_IP   = 32'hC0_A8_01_0B,
    parameter [15:0] SRC_PORT = 16'd5000,
    parameter [47:0] DST_MAC  = 48'hFF_FF_FF_FF_FF_FF,
    parameter [31:0] DST_IP   = 32'hC0_A8_01_69,
    parameter [15:0] DST_PORT = 16'd5000
)(
    // ---- 像素域 ----
    input               pix_clk,
    input               pix_rstn,
    input               de_in,
    input      [7:0]    r_in,
    input      [7:0]    g_in,
    input      [7:0]    b_in,

    // ---- 网络域 ----
    input               net_clk,
    input               net_rstn,
    output              tx_en,
    output     [7:0]    txd,

    // ---- 状态（可选，给软核看）----
    output reg [31:0]   frame_cnt,
    output reg          link_busy
);

    localparam [31:0] TOTAL_BYTES = IMG_W * IMG_H * 2;
    localparam [18:0] NPIX        = TOTAL_BYTES / 2;

    //==========================================================================
    //  像素域：降采样
    //==========================================================================
    wire        ds_de;
    wire [15:0] ds_rgb;
    wire [9:0]  ds_x, ds_y;
    wire        ds_sync;

    video_downsample #(
        .H_ACT ( SRC_W ),
        .V_ACT ( SRC_H )
    ) u_ds (
        .clk        ( pix_clk  ),
        .rstn       ( pix_rstn ),
        .de_in      ( de_in    ),
        .r_in       ( r_in     ),
        .g_in       ( g_in     ),
        .b_in       ( b_in     ),
        .de_out     ( ds_de    ),
        .rgb_out    ( ds_rgb   ),
        .x_out      ( ds_x     ),
        .y_out      ( ds_y     ),
        .frame_sync ( ds_sync  )
    );

    //==========================================================================
    //  帧缓存：写 pix_clk / 读 net_clk
    //==========================================================================
    reg [7:0] fb_hi [0:NPIX-1];
    reg [7:0] fb_lo [0:NPIX-1];

    reg         cap_en;
    wire [17:0] waddr = ({8'd0, ds_y} * 18'd640) + {8'd0, ds_x};

    always @(posedge pix_clk) begin
        if(cap_en && ds_de) begin
            fb_hi[waddr] <= ds_rgb[15:8];
            fb_lo[waddr] <= ds_rgb[7:0];
        end
    end

    wire [18:0] fb_addr;
    reg  [7:0]  fb_data;

    always @(posedge net_clk) begin
        fb_data <= fb_addr[0] ? fb_lo[fb_addr[18:1]] : fb_hi[fb_addr[18:1]];
    end

    //==========================================================================
    //  像素域采集状态机
    //==========================================================================
    localparam [1:0] P_IDLE = 2'd0, P_CAP = 2'd1, P_WAIT = 2'd2;

    reg [1:0]  pstate;
    reg [18:0] pix_cnt;
    reg        cap_done_tog;
    reg        send_done_tog;        // 由网络域翻转，这里同步后使用
    reg [2:0]  send_done_sync;

    wire send_done_edge = send_done_sync[1] ^ send_done_sync[2];

    always @(posedge pix_clk) begin
        if(!pix_rstn) begin
            pstate         <= P_IDLE;
            cap_en         <= 1'b0;
            pix_cnt        <= 19'd0;
            cap_done_tog   <= 1'b0;
            send_done_sync <= 3'b000;
        end
        else begin
            send_done_sync <= {send_done_sync[1:0], send_done_tog};

            case(pstate)
                P_IDLE: begin
                    cap_en <= 1'b0;
                    if(ds_sync) begin
                        pix_cnt <= 19'd0;
                        cap_en  <= 1'b1;
                        pstate  <= P_CAP;
                    end
                end
                P_CAP: begin
                    if(ds_de) pix_cnt <= pix_cnt + 19'd1;
                    if(ds_de && pix_cnt == NPIX - 19'd1) begin
                        cap_en       <= 1'b0;
                        cap_done_tog <= ~cap_done_tog;
                        pstate       <= P_WAIT;
                    end
                end
                P_WAIT: begin
                    if(send_done_edge) pstate <= P_IDLE;
                end
            endcase
        end
    end

    //==========================================================================
    //  网络域发送
    //==========================================================================
    reg [2:0]  cap_done_sync;
    wire       cap_done_edge = cap_done_sync[1] ^ cap_done_sync[2];

    reg         frame_start;
    wire        vid_busy, vid_done;
    wire [31:0] fid_w;

    eth_udp_video_tx #(
        .IMG_W       ( IMG_W    ),
        .IMG_H       ( IMG_H    ),
        .SRC_W       ( SRC_W    ),
        .SRC_H       ( SRC_H    ),
        .DATA_PER    ( DATA_PER ),
        .PKT_GAP     ( PKT_GAP  ),
        .FB_PREFETCH ( 1        ),
        .SRC_MAC     ( SRC_MAC  ),
        .SRC_IP      ( SRC_IP   ),
        .SRC_PORT    ( SRC_PORT ),
        .DST_MAC     ( DST_MAC  ),
        .DST_IP      ( DST_IP   ),
        .DST_PORT    ( DST_PORT )
    ) u_video (
        .clk         ( net_clk    ),
        .rstn        ( net_rstn   ),
        .frame_start ( frame_start),
        .frame_id    ( fid_w      ),
        .fb_addr     ( fb_addr    ),
        .fb_data     ( fb_data    ),
        .gmii_tx_en  ( tx_en      ),
        .gmii_txd    ( txd        ),
        .busy        ( vid_busy   ),
        .frame_done  ( vid_done   )
    );

    always @(posedge net_clk) begin
        if(!net_rstn) begin
            cap_done_sync <= 3'b000;
            send_done_tog <= 1'b0;
            frame_start   <= 1'b0;
            frame_cnt     <= 32'd0;
            link_busy     <= 1'b0;
        end
        else begin
            cap_done_sync <= {cap_done_sync[1:0], cap_done_tog};
            frame_start   <= 1'b0;
            link_busy     <= vid_busy;

            if(cap_done_edge && !vid_busy)
                frame_start <= 1'b1;

            if(vid_done) begin
                send_done_tog <= ~send_done_tog;
                frame_cnt     <= frame_cnt + 32'd1;
            end
        end
    end

endmodule
