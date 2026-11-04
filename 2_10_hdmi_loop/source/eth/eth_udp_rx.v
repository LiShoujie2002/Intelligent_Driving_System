`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: eth_udp_rx
// Description: IPv4/UDP 接收过滤器
//
//   逐字节比对 MAC / Ethernet 类型 / IPv4 / UDP 端口，通过后把
//   UDP 载荷以字节流形式吐出来。
//
//   【接受的帧】
//     目的 MAC  = MY_MAC 或 广播 FF:FF:FF:FF:FF:FF
//     目的 IP   = MY_IP  或 广播 255.255.255.255
//     EtherType = 0x0800, IPv4 IHL=5(无选项), proto=UDP
//     目的端口  = MY_PORT
//
//   接受广播是刻意的：PC 端不用实现 ARP 就能直接发包
//   （Python 开 SO_BROADCAST 发到 255.255.255.255 即可）。
//
//   【不做】
//     * 不校验 IP 头校验和、不校验 UDP 校验和、不校验 FCS
//     * 不处理 IP 分片、不支持 IHL > 5
//     直连网线场景下足够；上交换机后如需严格校验再加。
//
//////////////////////////////////////////////////////////////////////////////////

module eth_udp_rx #(
    parameter [47:0] MY_MAC   = 48'hA0_B1_C2_D3_E1_E1,
    parameter [31:0] MY_IP    = 32'hC0_A8_01_0B,  // 192.168.1.11
    parameter [15:0] MY_PORT  = 16'd5002,
    // 0 = 不检查目的 IP（直连场景下 MAC 广播 + 端口 + magic 已足够过滤）
    // 1 = 只接受 MY_IP 或 255.255.255.255
    parameter        CHECK_IP = 0
)(
    input            clk,
    input            rstn,

    // ---- 来自 eth_rx ----
    input            rx_dv,
    input      [7:0] rx_data,
    input     [10:0] byte_idx,
    input            sof,
    input            eof,

    // ---- UDP 载荷输出 ----
    output           pay_dv,
    output     [7:0] pay_data,
    output    [15:0] pay_idx,
    output           pay_sof,
    output           pay_last,
    output    [15:0] pay_len,
    output           frame_end,     // 本帧结束（不论是否被接受）

    // ---- 状态 ----
    output           accept
);

    reg        mac_me, mac_bc;
    reg        ip_me,  ip_bc;
    reg        ok_eth, ok_ver, ok_proto, ok_port;
    reg [15:0] plen;
    reg [7:0]  len_hi;
    reg [15:0] pidx;

    wire ip_pass = CHECK_IP ? (ip_me | ip_bc) : 1'b1;

    assign accept = (mac_me | mac_bc) & ip_pass
                  & ok_eth & ok_ver & ok_proto & ok_port;

    always @(posedge clk) begin
        if(!rstn) begin
            mac_me   <= 1'b0;
            mac_bc   <= 1'b0;
            ip_me    <= 1'b0;
            ip_bc    <= 1'b0;
            ok_eth   <= 1'b0;
            ok_ver   <= 1'b0;
            ok_proto <= 1'b0;
            ok_port  <= 1'b0;
            plen     <= 16'd0;
            len_hi   <= 8'd0;
            pidx     <= 16'd0;
        end
        else if(rx_dv) begin
            // 帧首：先把所有标志置为"通过"
            if(sof) begin
                mac_me   <= 1'b1;
                mac_bc   <= 1'b1;
                ip_me    <= 1'b1;
                ip_bc    <= 1'b1;
                ok_eth   <= 1'b1;
                ok_ver   <= 1'b1;
                ok_proto <= 1'b1;
                ok_port  <= 1'b1;
                plen     <= 16'd0;
                pidx     <= 16'd0;
            end

            // 逐字节比对（与上面的置位同拍时，case 的清除生效）
            case(byte_idx)
                // ---- 目的 MAC ----
                // 第 0 字节要"直接赋值"而不是 AND：
                // sof 和本 case 在同一拍都写 mac_me，Verilog 后写的赢，
                // 若写成 "mac_me & ..." 就会用上一帧的旧值，复位后恒为 0。
                11'd0 : begin
                    mac_me <= (rx_data == MY_MAC[47:40]);
                    mac_bc <= (rx_data == 8'hFF);
                end
                11'd1 : begin
                    mac_me <= mac_me & (rx_data == MY_MAC[39:32]);
                    mac_bc <= mac_bc & (rx_data == 8'hFF);
                end
                11'd2 : begin
                    mac_me <= mac_me & (rx_data == MY_MAC[31:24]);
                    mac_bc <= mac_bc & (rx_data == 8'hFF);
                end
                11'd3 : begin
                    mac_me <= mac_me & (rx_data == MY_MAC[23:16]);
                    mac_bc <= mac_bc & (rx_data == 8'hFF);
                end
                11'd4 : begin
                    mac_me <= mac_me & (rx_data == MY_MAC[15:8]);
                    mac_bc <= mac_bc & (rx_data == 8'hFF);
                end
                11'd5 : begin
                    mac_me <= mac_me & (rx_data == MY_MAC[7:0]);
                    mac_bc <= mac_bc & (rx_data == 8'hFF);
                end
                // ---- EtherType ----
                11'd12 : ok_eth <= ok_eth & (rx_data == 8'h08);
                11'd13 : ok_eth <= ok_eth & (rx_data == 8'h00);
                // ---- IPv4 ----
                11'd14 : ok_ver <= ok_ver & (rx_data == 8'h45);
                11'd23 : ok_proto <= ok_proto & (rx_data == 8'h11);
                11'd26 : begin
                    ip_me <= ip_me & (rx_data == MY_IP[31:24]);
                    ip_bc <= ip_bc & (rx_data == 8'hFF);
                end
                11'd27 : begin
                    ip_me <= ip_me & (rx_data == MY_IP[23:16]);
                    ip_bc <= ip_bc & (rx_data == 8'hFF);
                end
                11'd28 : begin
                    ip_me <= ip_me & (rx_data == MY_IP[15:8]);
                    ip_bc <= ip_bc & (rx_data == 8'hFF);
                end
                11'd29 : begin
                    ip_me <= ip_me & (rx_data == MY_IP[7:0]);
                    ip_bc <= ip_bc & (rx_data == 8'hFF);
                end
                // ---- UDP ----
                11'd36 : ok_port <= ok_port & (rx_data == MY_PORT[15:8]);
                11'd37 : ok_port <= ok_port & (rx_data == MY_PORT[7:0]);
                11'd38 : len_hi <= rx_data;
                11'd39 : plen   <= {len_hi, rx_data} - 16'd8;
                default: ;
            endcase

            // ---- 载荷计数 ----
            if(pay_dv) pidx <= pidx + 16'd1;
        end
    end

    localparam [10:0] PAY_OFF = 11'd42;      // 14 Eth + 20 IP + 8 UDP

    assign pay_dv   = rx_dv && (byte_idx >= PAY_OFF) && accept && (pidx < plen);
    assign pay_data = rx_data;
    assign pay_idx  = pidx;
    assign pay_sof  = pay_dv && (pidx == 16'd0);
    assign pay_last = pay_dv && (pidx == plen - 16'd1);
    assign pay_len  = plen;

    // 帧结束：上游 eof（RX_CTL 下降沿）且本帧被接受
    reg eof_d;
    always @(posedge clk) eof_d <= eof;
    assign frame_end = eof && !eof_d && accept;

endmodule
