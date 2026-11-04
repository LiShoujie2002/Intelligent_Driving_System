`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: eth_frame_tx
// Description: Ethernet II 帧发送器
//
//   自动产生 前导码(7x0x55 + 0xD5) + MAC 头 + 数据 + CRC32 FCS。
//   PHY 不会补前导码和 FCS，这两样必须由 MAC 侧生成，否则对端判 CRC 错丢弃。
//
//   【接口】
//     start      单拍脉冲启动一帧，同时锁存 dst_mac / ethertype / frame_len
//     frame_len  MAC 头 + payload 的总字节数（不含前导码和 FCS），最小 60
//     src_ready  每拍拉高一次，表示要吃下一个数据字节
//     src_data   数据字节，必须在 src_ready 拉高的同一拍有效
//
//   【重要约束】
//     src_ready 一旦拉高，数据必须当拍给出。本模块不支持 source 中途停顿
//     （停顿会让 TX_EN 期间重复发送同一字节，帧就坏了）。
//     上游用 BRAM / 计数器这类"永远就绪"的数据源即可。
//
//   【时序】
//     gmii_txd / gmii_tx_en 是寄存器输出，比内部状态晚一拍，
//     FCS 在最后一个数据字节写入 CRC 后再取，二者天然对齐。
//
//////////////////////////////////////////////////////////////////////////////////

module eth_frame_tx #(
    parameter [47:0] SRC_MAC = 48'hA0_B1_C2_D3_E1_E1
)(
    input                    clk,          // 125 MHz (RGMII)
    input                    rstn,

    // ---- 帧参数（start 时锁存）----
    input                    start,
    input      [47:0]        dst_mac,
    input      [15:0]        ethertype,
    input      [15:0]        frame_len,     // 含 14 字节 MAC 头，不含 FCS

    // ---- 数据源 ----
    output                   src_ready,
    input      [7:0]         src_data,

    // ---- RGMII/GMII 物理接口 ----
    output reg               gmii_tx_en,
    output reg  [7:0]        gmii_txd,

    // ---- 状态 ----
    output                   busy,
    output reg               done          // 单拍脉冲
);

    localparam S_IDLE = 3'd0;
    localparam S_PRE  = 3'd1;
    localparam S_HDR  = 3'd2;
    localparam S_DATA = 3'd3;
    localparam S_PAD  = 3'd4;
    localparam S_FCS  = 3'd5;

    localparam MIN_LEN = 16'd60;           // 不含 FCS 的最小帧长

    reg [2:0]  st;
    reg [4:0]  cnt;                        // 相位内字节序号
    reg [15:0] data_left;                  // DATA 相位剩余字节
    reg [15:0] pad_left;                   // PAD 相位剩余字节
    reg [31:0] crc;

    reg [47:0] dmac_lat;
    reg [15:0] et_lat;
    reg [15:0] len_lat;

    //==========================================================================
    //  CRC32（反射，多项式 0xEDB88320）
    //==========================================================================
    function [31:0] crc32_next;
        input [31:0] c;
        input [7:0]  d;
        integer i;
        reg [31:0] v;
        begin
            v = c ^ {24'd0, d};
            for(i = 0; i < 8; i = i + 1)
                v = v[0] ? ((v >> 1) ^ 32'hEDB8_8320) : (v >> 1);
            crc32_next = v;
        end
    endfunction

    //==========================================================================
    //  当前要发送的字节（组合选择）
    //==========================================================================
    reg [7:0] tx_byte;

    always @(*) begin
        case(st)
            S_PRE : tx_byte = (cnt == 5'd7) ? 8'hD5 : 8'h55;

            S_HDR : case(cnt)
                5'd0  : tx_byte = dmac_lat[47:40];
                5'd1  : tx_byte = dmac_lat[39:32];
                5'd2  : tx_byte = dmac_lat[31:24];
                5'd3  : tx_byte = dmac_lat[23:16];
                5'd4  : tx_byte = dmac_lat[15:8];
                5'd5  : tx_byte = dmac_lat[7:0];
                5'd6  : tx_byte = SRC_MAC[47:40];
                5'd7  : tx_byte = SRC_MAC[39:32];
                5'd8  : tx_byte = SRC_MAC[31:24];
                5'd9  : tx_byte = SRC_MAC[23:16];
                5'd10 : tx_byte = SRC_MAC[15:8];
                5'd11 : tx_byte = SRC_MAC[7:0];
                5'd12 : tx_byte = et_lat[15:8];
                default: tx_byte = et_lat[7:0];
            endcase

            S_DATA : tx_byte = src_data;

            S_PAD  : tx_byte = 8'h00;

            S_FCS : case(cnt[1:0])
                2'd0 : tx_byte = ~crc[7:0];
                2'd1 : tx_byte = ~crc[15:8];
                2'd2 : tx_byte = ~crc[23:16];
                default: tx_byte = ~crc[31:24];
            endcase

            default: tx_byte = 8'h00;
        endcase
    end

    // 本拍是否要真正发出一个字节
    wire emit = (st == S_PRE) || (st == S_HDR) || (st == S_DATA)
             || (st == S_PAD) || (st == S_FCS);

    // CRC 只覆盖 MAC 头 + 数据 + 填充，不含前导码
    wire crc_en = (st == S_HDR) || (st == S_DATA) || (st == S_PAD);

    assign src_ready = (st == S_DATA);
    assign busy      = (st != S_IDLE);

    //==========================================================================
    //  主状态机
    //==========================================================================
    always @(posedge clk) begin
        if(!rstn) begin
            st         <= S_IDLE;
            cnt        <= 5'd0;
            data_left  <= 16'd0;
            pad_left   <= 16'd0;
            crc        <= 32'hFFFF_FFFF;
            dmac_lat   <= 48'd0;
            et_lat     <= 16'd0;
            len_lat    <= 16'd0;
            gmii_tx_en <= 1'b0;
            gmii_txd   <= 8'h00;
            done       <= 1'b0;
        end
        else begin
            done <= 1'b0;

            if(st == S_IDLE) begin
                gmii_tx_en <= 1'b0;
                if(start) begin
                    dmac_lat  <= dst_mac;
                    et_lat    <= ethertype;
                    len_lat   <= frame_len;
                    crc       <= 32'hFFFF_FFFF;
                    cnt       <= 5'd1;          // 第 0 个前导字节在这一拍就发出去了
                    data_left <= frame_len - 16'd14;
                    pad_left  <= (frame_len < MIN_LEN) ? (MIN_LEN - frame_len)
                                                      : 16'd0;
                    gmii_tx_en <= 1'b1;
                    gmii_txd   <= 8'h55;
                    st         <= S_PRE;
                end
            end
            else if(emit) begin
                gmii_tx_en <= 1'b1;
                gmii_txd   <= tx_byte;

                if(crc_en) crc <= crc32_next(crc, tx_byte);

                case(st)
                    S_PRE : begin
                        if(cnt == 5'd7) begin
                            cnt <= 5'd0;
                            st  <= S_HDR;
                        end
                        else cnt <= cnt + 5'd1;
                    end

                    S_HDR : begin
                        if(cnt == 5'd13) begin
                            cnt <= 5'd0;
                            st  <= (data_left != 16'd0) ? S_DATA : S_PAD;
                        end
                        else cnt <= cnt + 5'd1;
                    end

                    S_DATA : begin
                        if(data_left == 16'd1) begin
                            data_left <= 16'd0;
                            cnt       <= 5'd0;
                            st        <= (pad_left != 16'd0) ? S_PAD : S_FCS;
                        end
                        else data_left <= data_left - 16'd1;
                    end

                    S_PAD : begin
                        if(pad_left == 16'd1) begin
                            pad_left <= 16'd0;
                            cnt      <= 5'd0;
                            st       <= S_FCS;
                        end
                        else pad_left <= pad_left - 16'd1;
                    end

                    S_FCS : begin
                        if(cnt == 5'd3) begin
                            cnt  <= 5'd0;
                            st   <= S_IDLE;
                            done <= 1'b1;
                        end
                        else cnt <= cnt + 5'd1;
                    end

                    default: st <= S_IDLE;
                endcase
            end
            else begin
                gmii_tx_en <= 1'b0;
            end
        end
    end

endmodule
