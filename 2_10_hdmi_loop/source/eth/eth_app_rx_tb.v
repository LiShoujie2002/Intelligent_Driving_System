`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// eth_app_rx 自检
//   造一帧"3 个框"的检测结果包，检查解析出的数量、帧号、坐标。
//   再发一帧 magic 错误的包，检查不会误更新。
//////////////////////////////////////////////////////////////////////////////////

module eth_app_rx_tb;

    localparam MAXBOX = 32;

    reg clk = 0, rstn = 0;
    reg        pay_dv = 0;
    reg  [7:0] pay_data = 0;
    reg  [15:0] pay_idx = 0;
    reg        frame_end = 0;

    wire        update;
    wire [31:0] o_frame_id;
    wire [7:0]  o_nbox;
    wire [MAXBOX*16-1:0] o_x1, o_y1, o_x2, o_y2;
    wire [MAXBOX*8-1:0]  o_cls, o_conf;

    eth_app_rx #(.MAXBOX(MAXBOX)) dut (
        .clk(clk), .rstn(rstn),
        .pay_dv(pay_dv), .pay_data(pay_data), .pay_idx(pay_idx),
        .frame_end(frame_end),
        .update(update), .o_frame_id(o_frame_id), .o_nbox(o_nbox),
        .o_x1(o_x1), .o_y1(o_y1), .o_x2(o_x2), .o_y2(o_y2),
        .o_cls(o_cls), .o_conf(o_conf)
    );

    reg [7:0] pktm [0:1023];
    integer   len;
    integer   k;
    integer   errs = 0;
    integer   upd_cnt = 0;

    always #5 clk = ~clk;

    always @(posedge clk) if(update) upd_cnt = upd_cnt + 1;

    //------------------------------------------------------------------
    task send_pkt;
        input integer corrupt;      // 1 = 破坏 magic
        integer n;
        begin
            for(n = 0; n < len; n = n + 1) begin
                @(negedge clk);
                pay_dv   = 1'b1;
                pay_idx  = n[15:0];
                pay_data = (corrupt && n == 0) ? 8'h00 : pktm[n];
            end
            @(negedge clk);
            pay_dv    = 1'b0;
            frame_end = 1'b1;
            @(negedge clk);
            frame_end = 1'b0;
            @(negedge clk);
        end
    endtask

    //------------------------------------------------------------------
    function [15:0] bx1_of;
        input integer i;
        begin bx1_of = o_x1[i*16 +: 16]; end
    endfunction
    function [15:0] by2_of;
        input integer i;
        begin by2_of = o_y2[i*16 +: 16]; end
    endfunction
    function [7:0] cls_of;
        input integer i;
        begin cls_of = o_cls[i*8 +: 8]; end
    endfunction
    function [7:0] conf_of;
        input integer i;
        begin conf_of = o_conf[i*8 +: 8]; end
    endfunction

    //------------------------------------------------------------------
    initial begin
        // 构造：32 字节头 + 3 个框
        for(k = 0; k < 32; k = k + 1) pktm[k] = 8'h00;
        pktm[0] = 8'h50; pktm[1] = 8'h4E; pktm[2] = 8'h47; pktm[3] = 8'h31; // PNG1
        pktm[4] = 8'h01;                     // version
        pktm[5] = 8'h02;                     // msg_type = 检测结果
        pktm[8]  = 8'h00; pktm[9]  = 8'h00;   // frame_id = 0x1234
        pktm[10] = 8'h12; pktm[11] = 8'h34;
        pktm[28] = 8'h00; pktm[29] = 8'd48;   // payload_len = 48 -> 3 个框

        // 框 0: (100,200)-(300,400) cls=2 conf=90
        pktm[32] = 8'h00; pktm[33] = 8'd100;
        pktm[34] = 8'h00; pktm[35] = 8'd200;
        pktm[36] = 8'h01; pktm[37] = 8'd44;    // 300
        pktm[38] = 8'h01; pktm[39] = 8'd144;   // 400
        pktm[40] = 8'd2;  pktm[42] = 8'd90;

        // 框 1: (10,20)-(30,40) cls=0 conf=77
        pktm[48] = 8'h00; pktm[49] = 8'd10;
        pktm[50] = 8'h00; pktm[51] = 8'd20;
        pktm[52] = 8'h00; pktm[53] = 8'd30;
        pktm[54] = 8'h00; pktm[55] = 8'd40;
        pktm[56] = 8'd0;  pktm[58] = 8'd77;

        // 框 2: (640,600)-(1279,719) cls=1 conf=55
        pktm[64] = 8'h02; pktm[65] = 8'd128;   // 640
        pktm[66] = 8'h02; pktm[67] = 8'd88;    // 600
        pktm[68] = 8'h04; pktm[69] = 8'd255;   // 1279
        pktm[70] = 8'h02; pktm[71] = 8'd207;   // 719
        pktm[72] = 8'd1;  pktm[74] = 8'd55;

        len = 32 + 48;

        #30 rstn = 1;
        repeat(5) @(negedge clk);

        // ---- 正常包 ----
        send_pkt(0);
        $display("  帧号=%h  框数=%0d", o_frame_id, o_nbox);
        if(o_nbox !== 8'd3) begin $display("  FAIL 框数"); errs = errs + 1; end
        if(o_frame_id !== 32'h0000_1234) begin $display("  FAIL 帧号"); errs = errs + 1; end
        if(bx1_of(0) !== 16'd100)  begin $display("  FAIL x1(%0d)=%0d", 0, bx1_of(0)); errs=errs+1; end
        if(by2_of(0) !== 16'd400)  begin $display("  FAIL y2(%0d)=%0d", 0, by2_of(0)); errs=errs+1; end
        if(cls_of(0) !== 8'd2)     begin $display("  FAIL cls(%0d)", 0); errs=errs+1; end
        if(conf_of(0) !== 8'd90)   begin $display("  FAIL conf(%0d)", 0); errs=errs+1; end
        if(bx1_of(1) !== 16'd10)   begin $display("  FAIL x1(%0d)=%0d", 1, bx1_of(1)); errs=errs+1; end
        if(bx1_of(2) !== 16'd640)  begin $display("  FAIL x1(%0d)=%0d", 2, bx1_of(2)); errs=errs+1; end
        if(by2_of(2) !== 16'd719)  begin $display("  FAIL y2(%0d)=%0d", 2, by2_of(2)); errs=errs+1; end
        if(conf_of(2) !== 8'd55)   begin $display("  FAIL conf(%0d)", 2); errs=errs+1; end

        // ---- 坏 magic 的包，应该不更新 ----
        send_pkt(1);
        if(upd_cnt !== 1) begin
            $display("  FAIL 坏包也被接受了 (upd_cnt=%0d)", upd_cnt);
            errs = errs + 1;
        end

        $display("");
        if(errs == 0) $display("RESULT: OK");
        else          $display("RESULT: FAIL 错误 %0d 处", errs);
        $finish;
    end

endmodule
