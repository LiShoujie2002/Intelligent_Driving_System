`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// eth_udp_video_tx 自检
//
//   小图 8x4，DATA_PER=32 -> 每帧 2 包。
//   帧缓存用"字节值 = 字节地址"的合成源，
//   这样收到的数据流可以直接和地址比对，一眼看出有没有错位。
//////////////////////////////////////////////////////////////////////////////////

module eth_udp_video_tx_tb;

    localparam IW = 8;
    localparam IH = 4;
    localparam TOTAL = IW * IH * 2;      // 64 字节
    localparam DP    = 32;               // 每包数据字节
    localparam PKTS  = TOTAL / DP;       // 2 包

    reg clk = 0, rstn = 0;
    reg  frame_start = 0;
    wire [31:0] frame_id;

    wire [18:0] fb_addr;
    reg  [7:0]  fb_data;

    wire        tx_en;
    wire [7:0]  txd;
    wire        busy, frame_done;

    eth_udp_video_tx #(
        .IMG_W       ( IW    ),
        .IMG_H       ( IH    ),
        .DATA_PER    ( DP    ),
        .PKT_GAP     ( 24'd20 ),
        .FB_PREFETCH ( 1      )
    ) dut (
        .clk         ( clk         ),
        .rstn        ( rstn        ),
        .frame_start ( frame_start ),
        .frame_id    ( frame_id    ),
        .fb_addr     ( fb_addr     ),
        .fb_data     ( fb_data     ),
        .gmii_tx_en  ( tx_en       ),
        .gmii_txd    ( txd         ),
        .frame_done  ( frame_done  ),
        .busy        ( busy        )
    );

    always #5 clk = ~clk;

    // 合成"帧缓存"：字节值 = 字节地址，1 拍延迟
    always @(posedge clk)
        fb_data <= fb_addr[7:0];

    //------------------------------------------------------------------
    //  抓发送字节流
    //------------------------------------------------------------------
    integer n = 0;                       // 当前帧内的字节序号（含前导码）
    integer pkt = 0;
    integer errs = 0;
    integer k;

    // 应用层头（MAC 14 + IP 20 + UDP 8 = 42 字节之后）
    reg [7:0] hdr_buf [0:31];
    integer   hdr_n;
    integer   data_n;
    integer   data_base;

    always @(posedge clk) begin
        if(!rstn) begin
            n <= 0; pkt <= 0; hdr_n <= 0; data_n <= 0; data_base <= 0;
        end
        else if(tx_en) begin
            n <= n + 1;

            // 前导码 8 字节之后是 MAC/IP/UDP/应用头
            if(n >= 8) begin
                if(n < 8+42) begin
                    // MAC/IP/UDP 头，跳过
                end
                else if(n < 8+42+32) begin
                    hdr_buf[hdr_n] <= txd;
                    hdr_n <= hdr_n + 1;
                end
                else begin
                    // 数据区：期望 = 该包数据基址 + 序号
                    if(data_n == 0) begin
                        $display("  pkt%0d: 头部 PNG1=%c%c%c%c  plen=%0d%0d",
                                 pkt, hdr_buf[0], hdr_buf[1], hdr_buf[2], hdr_buf[3],
                                 hdr_buf[28], hdr_buf[29]);
                        $display("        packet_id=%0d  pkt_total=%0d",
                                 {hdr_buf[14], hdr_buf[15]},
                                 {hdr_buf[16], hdr_buf[17]});
                    end
                    if(txd !== ((data_base + data_n) & 8'hFF)) begin
                        if(errs < 12)
                            $display("    MISMATCH pkt%0d data[%0d] got=%02h exp=%02h",
                                     pkt, data_n, txd, (data_base + data_n) & 8'hFF);
                        errs = errs + 1;
                    end
                    data_n <= data_n + 1;
                end
            end
        end
        else begin
            // 帧间：复位计数，进入下一包
            if(n != 0) begin
                n        <= 0;
                hdr_n    <= 0;
                data_n   <= 0;
                pkt      <= pkt + 1;
                data_base<= data_base + DP;
            end
        end
    end

    //------------------------------------------------------------------
    initial begin
        #30 rstn = 1;
        @(negedge clk); frame_start = 1;
        @(negedge clk); frame_start = 0;

        repeat (200000) @(negedge clk);

        $display("");
        $display("  发出的包数: %0d (期望 %0d)", pkt, PKTS);
        if(errs == 0) $display("RESULT: OK");
        else          $display("RESULT: FAIL 错误 %0d 处", errs);
        $finish;
    end

endmodule
