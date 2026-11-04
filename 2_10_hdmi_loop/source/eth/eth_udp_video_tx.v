`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: eth_udp_video_tx
// Description: 视频帧分包发送（协议 v1.3 的 msg_type = 0x01）
//
//   把一整幅图像切成若干个 UDP 包，每包 = 32 字节应用头 + 最多 1440 字节图像数据。
//
//   【取数接口】
//     fb_addr : 帧内字节偏移（组合输出）
//     fb_data : 对应字节，**1 拍延迟**（SRAM/BRAM 的读时序）
//   模块在头部阶段就把 fb_addr 停在 base，让第一拍数据提前就绪；
//   数据阶段 fb_addr = base + data_cnt + 1，正好抵消 BRAM 的 1 拍延迟。
//
//   【帧长】
//     640×360 RGB565 = 460,800 字节 / 1440 = 320 包，整除，
//     所以每一包都是满的（最后一包也是 1440）。
//
//////////////////////////////////////////////////////////////////////////////////

module eth_udp_video_tx #(
    parameter [47:0] SRC_MAC  = 48'hA0_B1_C2_D3_E1_E1,
    parameter [31:0] SRC_IP   = 32'hC0_A8_01_0B,
    parameter [15:0] SRC_PORT = 16'd5000,

    parameter [47:0] DST_MAC  = 48'hFF_FF_FF_FF_FF_FF,
    parameter [31:0] DST_IP   = 32'hC0_A8_01_69,
    parameter [15:0] DST_PORT = 16'd5000,

    parameter [15:0] IMG_W    = 16'd640,
    parameter [15:0] IMG_H    = 16'd360,
    parameter [15:0] SRC_W    = 16'd1280,
    parameter [15:0] SRC_H    = 16'd720,

    parameter [15:0] DATA_PER = 16'd1440,     // 每包图像字节
    parameter [7:0]  PFMT     = 8'd1,         // 1 = RGB565
    parameter [7:0]  RMODE    = 8'd0,         // 0 = 整数抽取

    // 帧缓存读延迟补偿（拍）。fb_addr 在数据阶段要提前这么久给出。
    // 1 = 单级寄存读（合成图案/简单 RAM）
    // 2 = 双口 RAM + 字节选择时的实际延迟（BRAM 地址/输出各有寄存）
    parameter        FB_PREFETCH = 1,

    // 帧内总字节数 = IMG_W * IMG_H * 2（RGB565）
    parameter [31:0] TOTAL_BYTES = IMG_W * IMG_H * 2,
    parameter [15:0] PKT_TOTAL   = (TOTAL_BYTES + DATA_PER - 1) / DATA_PER,

    // 包间空闲拍数。背靠背发 320 包会在 3.8 ms 内打出 480 KB（接近线速），
    // 普通 PC 的软件收包路径会丢包。留出间隔让对端来得及处理。
    // 125 MHz 下：12500 -> 包率约 9.6k/s，320 包约 32 ms（30fps 的极限）
    parameter [23:0] PKT_GAP     = 24'd20000
)(
    input                    clk,          // 125 MHz
    input                    rstn,

    input                    frame_start,  // 单拍脉冲
    output reg  [31:0]       frame_id,

    // ---- 帧缓存读接口 ----
    output      [18:0]       fb_addr,
    input       [7:0]        fb_data,

    // ---- 以太网 ----
    output                   gmii_tx_en,
    output      [7:0]        gmii_txd,

    // ---- 状态 ----
    output                   busy,
    output reg               frame_done
);

    localparam [15:0] HDR_LEN = 16'd32;

    //==========================================================================
    //  状态
    //==========================================================================
    reg        sending;         // 正在发这一帧
    reg [15:0] pkt_id;
    reg [31:0] offset;          // 本包在帧内的起始字节偏移
    reg [15:0] cur_data_len;    // 本包图像字节数
    reg [5:0]  hdr_cnt;         // 0..31
    reg [15:0] data_cnt;        // 本包已发出的图像字节数

    reg        in_gap;          // 包间空闲
    reg [23:0] gap_cnt;
    reg        pending;         // 有一包等着发

    wire [31:0] remain      = TOTAL_BYTES - offset;
    wire [15:0] this_len    = (remain > DATA_PER) ? DATA_PER : remain[15:0];
    wire        is_last_pkt = (pkt_id == PKT_TOTAL - 16'd1);

    //==========================================================================
    //  32 字节应用头
    //==========================================================================
    reg [7:0] hdr_byte;

    always @(*) begin
        case(hdr_cnt)
            6'd0  : hdr_byte = 8'h50;        // "PNG1"
            6'd1  : hdr_byte = 8'h4E;
            6'd2  : hdr_byte = 8'h47;
            6'd3  : hdr_byte = 8'h31;
            6'd4  : hdr_byte = 8'h01;        // version
            6'd5  : hdr_byte = 8'h01;        // msg_type = VIDEO
            6'd6  : hdr_byte = 8'h00;        // flags hi
            6'd7  : hdr_byte = {7'd0, is_last_pkt};
            6'd8  : hdr_byte = frame_id[31:24];
            6'd9  : hdr_byte = frame_id[23:16];
            6'd10 : hdr_byte = frame_id[15:8];
            6'd11 : hdr_byte = frame_id[7:0];
            6'd12 : hdr_byte = 8'h00;        // packet_id hi
            6'd13 : hdr_byte = 8'h00;
            6'd14 : hdr_byte = pkt_id[15:8];
            6'd15 : hdr_byte = pkt_id[7:0];
            6'd16 : hdr_byte = PKT_TOTAL[15:8];
            6'd17 : hdr_byte = PKT_TOTAL[7:0];
            6'd18 : hdr_byte = SRC_W[15:8];
            6'd19 : hdr_byte = SRC_W[7:0];
            6'd20 : hdr_byte = SRC_H[15:8];
            6'd21 : hdr_byte = SRC_H[7:0];
            6'd22 : hdr_byte = IMG_W[15:8];
            6'd23 : hdr_byte = IMG_W[7:0];
            6'd24 : hdr_byte = IMG_H[15:8];
            6'd25 : hdr_byte = IMG_H[7:0];
            6'd26 : hdr_byte = PFMT;
            6'd27 : hdr_byte = RMODE;
            6'd28 : hdr_byte = cur_data_len[15:8];
            6'd29 : hdr_byte = cur_data_len[7:0];
            6'd30 : hdr_byte = 8'h00;
            default: hdr_byte = 8'h00;       // 6'd31 reserved
        endcase
    end

    //==========================================================================
    //  接到 eth_udp_tx
    //==========================================================================
    wire        udp_busy;
    wire        udp_done;
    wire        udp_ready;
    wire [7:0]  udp_data;
    wire        udp_en;
    wire [7:0]  udp_txd;

    reg         udp_start;

    wire use_hdr = (hdr_cnt < HDR_LEN[5:0]);

    assign udp_data = use_hdr ? hdr_byte : fb_data;

    eth_udp_tx #(
        .SRC_MAC  ( SRC_MAC  ),
        .SRC_IP   ( SRC_IP   ),
        .SRC_PORT ( SRC_PORT )
    ) u_udp (
        .clk         ( clk                          ),
        .rstn        ( rstn                         ),
        .start       ( udp_start                    ),
        .dst_mac     ( DST_MAC                      ),
        .dst_ip      ( DST_IP                       ),
        .dst_port    ( DST_PORT                     ),
        .payload_len ( HDR_LEN + cur_data_len       ),
        .src_ready   ( udp_ready                    ),
        .src_data    ( udp_data                     ),
        .gmii_tx_en  ( udp_en                       ),
        .gmii_txd    ( udp_txd                      ),
        .busy        ( udp_busy                     ),
        .done        ( udp_done                     )
    );

    assign gmii_tx_en = udp_en;
    assign gmii_txd   = udp_txd;
    assign busy       = sending;

    // 帧缓存地址：头部阶段停在 base，数据阶段超前 1 拍抵消 BRAM 延迟
    assign fb_addr = offset[18:0]
                   + (use_hdr ? 19'd0 : {3'd0, data_cnt} + FB_PREFETCH);

    //==========================================================================
    //  主状态机
    //==========================================================================
    always @(posedge clk) begin
        if(!rstn) begin
            sending      <= 1'b0;
            pkt_id       <= 16'd0;
            offset       <= 32'd0;
            cur_data_len <= 16'd0;
            hdr_cnt      <= 6'd0;
            data_cnt     <= 16'd0;
            udp_start    <= 1'b0;
            frame_id     <= 32'd0;
            frame_done   <= 1'b0;
            in_gap       <= 1'b0;
            gap_cnt      <= 24'd0;
            pending      <= 1'b0;
        end
        else begin
            udp_start  <= 1'b0;
            frame_done <= 1'b0;

            // 头字节计数
            if(udp_ready && use_hdr)
                hdr_cnt <= hdr_cnt + 6'd1;

            // 数据字节计数
            if(udp_ready && !use_hdr)
                data_cnt <= data_cnt + 16'd1;

            // ---- 包间间隔 ----
            if(in_gap) begin
                if(gap_cnt == 24'd0) begin
                    in_gap    <= 1'b0;
                    pending   <= 1'b0;
                    udp_start <= 1'b1;
                end
                else begin
                    gap_cnt <= gap_cnt - 24'd1;
                end
            end

            if(!sending) begin
                if(frame_start) begin
                    sending      <= 1'b1;
                    pkt_id       <= 16'd0;
                    offset       <= 32'd0;
                    cur_data_len <= this_len;
                    hdr_cnt      <= 6'd0;
                    data_cnt     <= 16'd0;
                    udp_start    <= 1'b1;
                end
            end
            else if(udp_done) begin
                if(is_last_pkt) begin
                    sending    <= 1'b0;
                    frame_done <= 1'b1;
                    frame_id   <= frame_id + 32'd1;
                end
                else begin
                    pkt_id       <= pkt_id + 16'd1;
                    offset       <= offset + {16'd0, cur_data_len};
                    cur_data_len <= (remain - cur_data_len > DATA_PER)
                                    ? DATA_PER : (remain - cur_data_len);
                    hdr_cnt      <= 6'd0;
                    data_cnt     <= 16'd0;
                    in_gap       <= 1'b1;
                    gap_cnt      <= PKT_GAP;
                    pending      <= 1'b1;
                end
            end
        end
    end

endmodule
