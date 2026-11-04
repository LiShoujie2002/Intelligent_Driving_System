`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: eth_udp_tx
// Description: IPv4/UDP 发送器（UDP 校验和填 0）
//
//   在 eth_frame_tx 之上自动生成 20 字节 IPv4 头 + 8 字节 UDP 头，
//   然后从 src_* 接口取 payload。
//
//   【IPv4 头校验和】
//   组合逻辑算 10 个 16 位字的反码和。源/目的 IP 是参数（常量），
//   只有 total_len 随 payload_len 变化，综合后会简化成一小组加法器。
//
//   【UDP 校验和】
//   恒为 0（RFC768 允许），接收端不校验。
//
//   【接口约束】
//   src_ready 拉高时必须当拍给出 src_data，不支持中途停顿
//   （上游用 BRAM 或计数器这类"永远就绪"的数据源）。
//
//////////////////////////////////////////////////////////////////////////////////

module eth_udp_tx #(
    parameter [47:0] SRC_MAC  = 48'hA0_B1_C2_D3_E1_E1,
    parameter [31:0] SRC_IP   = 32'hC0_A8_01_0B,   // 192.168.1.11
    parameter [15:0] SRC_PORT = 16'd5000
)(
    input                    clk,          // 125 MHz
    input                    rstn,

    // ---- 一帧的参数（start 时锁存）----
    input                    start,
    input      [47:0]        dst_mac,
    input      [31:0]        dst_ip,
    input      [15:0]        dst_port,
    input      [15:0]        payload_len,   // UDP 载荷字节数，<= 1440

    // ---- payload 数据源 ----
    output                   src_ready,
    input      [7:0]         src_data,

    // ---- 物理接口 ----
    output                   gmii_tx_en,
    output      [7:0]        gmii_txd,

    // ---- 状态 ----
    output                   busy,
    output                   done
);

    //==========================================================================
    //  锁存的帧参数
    //==========================================================================
    reg  [47:0] dmac_lat;
    reg  [31:0] dip_lat;
    reg  [15:0] dport_lat;
    reg  [15:0] plen_lat;
    reg  [5:0]  hdr_cnt;
    reg         f_start;

    wire [15:0] ip_total_len = 16'd28 + plen_lat;   // IP + UDP 头 20+8
    wire [15:0] udp_len      = 16'd8  + plen_lat;

    //==========================================================================
    //  IPv4 头校验和
    //==========================================================================
    function [15:0] ip_cksum;
        input [15:0] total_len;
        input [31:0] sip;
        input [31:0] dip;
        reg [31:0] s;
        begin
            s = 32'h0000_4500                     // ver/IHL, TOS
              + {16'd0, total_len}                // total length
              + 32'h0000_0000                     // identification
              + 32'h0000_0000                     // flags / frag
              + 32'h0000_4011                     // TTL 64, proto UDP
                                                  // checksum 本身按 0 计
              + {16'd0, sip[31:16]} + {16'd0, sip[15:0]}
              + {16'd0, dip[31:16]} + {16'd0, dip[15:0]};
            s = (s & 32'h0000_FFFF) + (s >> 16);
            s = (s & 32'h0000_FFFF) + (s >> 16);
            ip_cksum = ~s[15:0];
        end
    endfunction

    // 校验和寄存一拍。plen_lat 在整个包期间不变，头字节要到第 2 拍之后才发，
    // 有足够时间。不寄存的话 "plen -> total_len -> 校验和 -> hdr_byte -> CRC"
    // 会挤在同一拍，125MHz 下差 0.14ns 收敛不了。
    reg [15:0] cksum;
    always @(posedge clk) begin
        if(!rstn) cksum <= 16'd0;
        else      cksum <= ip_cksum(ip_total_len, SRC_IP, dip_lat);
    end

    //==========================================================================
    //  28 字节 IP+UDP 头
    //==========================================================================
    reg [7:0] hdr_byte;

    always @(*) begin
        case(hdr_cnt)
            // ---- IPv4 header ----
            6'd0  : hdr_byte = 8'h45;
            6'd1  : hdr_byte = 8'h00;
            6'd2  : hdr_byte = ip_total_len[15:8];
            6'd3  : hdr_byte = ip_total_len[7:0];
            6'd4  : hdr_byte = 8'h00;              // ID
            6'd5  : hdr_byte = 8'h00;
            6'd6  : hdr_byte = 8'h00;              // flags / frag
            6'd7  : hdr_byte = 8'h00;
            6'd8  : hdr_byte = 8'h40;              // TTL
            6'd9  : hdr_byte = 8'h11;              // proto UDP
            6'd10 : hdr_byte = cksum[15:8];
            6'd11 : hdr_byte = cksum[7:0];
            6'd12 : hdr_byte = SRC_IP[31:24];
            6'd13 : hdr_byte = SRC_IP[23:16];
            6'd14 : hdr_byte = SRC_IP[15:8];
            6'd15 : hdr_byte = SRC_IP[7:0];
            6'd16 : hdr_byte = dip_lat[31:24];
            6'd17 : hdr_byte = dip_lat[23:16];
            6'd18 : hdr_byte = dip_lat[15:8];
            6'd19 : hdr_byte = dip_lat[7:0];
            // ---- UDP header ----
            6'd20 : hdr_byte = SRC_PORT[15:8];
            6'd21 : hdr_byte = SRC_PORT[7:0];
            6'd22 : hdr_byte = dport_lat[15:8];
            6'd23 : hdr_byte = dport_lat[7:0];
            6'd24 : hdr_byte = udp_len[15:8];
            6'd25 : hdr_byte = udp_len[7:0];
            6'd26 : hdr_byte = 8'h00;              // checksum disabled
            default: hdr_byte = 8'h00;
        endcase
    end

    //==========================================================================
    //  接到 eth_frame_tx
    //==========================================================================
    wire        f_ready;
    wire [7:0]  f_data;
    wire        f_en;
    wire [7:0]  f_txd;
    wire        f_done;

    wire use_hdr = (hdr_cnt < 6'd28);

    assign f_data  = use_hdr ? hdr_byte : src_data;
    assign src_ready = f_ready && !use_hdr;

    eth_frame_tx #(
        .SRC_MAC ( SRC_MAC )
    ) u_frame (
        .clk        ( clk            ),
        .rstn       ( rstn           ),
        .start      ( f_start        ),
        .dst_mac    ( dmac_lat       ),
        .ethertype  ( 16'h0800       ),
        .frame_len  ( 16'd42 + plen_lat ),
        .src_ready  ( f_ready        ),
        .src_data   ( f_data         ),
        .gmii_tx_en ( f_en           ),
        .gmii_txd   ( f_txd          ),
        .busy       ( busy           ),
        .done       ( f_done         )
    );

    assign gmii_tx_en = f_en;
    assign gmii_txd   = f_txd;
    assign done       = f_done;

    //==========================================================================
    //  参数锁存 + 头字节计数
    //==========================================================================
    always @(posedge clk) begin
        if(!rstn) begin
            dmac_lat  <= 48'd0;
            dip_lat   <= 32'd0;
            dport_lat <= 16'd0;
            plen_lat  <= 16'd0;
            hdr_cnt   <= 6'd0;
            f_start   <= 1'b0;
        end
        else begin
            f_start <= 1'b0;

            if(start && !busy) begin
                dmac_lat  <= dst_mac;
                dip_lat   <= dst_ip;
                dport_lat <= dst_port;
                plen_lat  <= payload_len;
                hdr_cnt   <= 6'd0;
                f_start   <= 1'b1;
            end
            else if(f_ready && use_hdr) begin
                hdr_cnt <= hdr_cnt + 6'd1;
            end
        end
    end

endmodule
