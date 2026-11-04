set_arch -family Logos2 -device PG2L200H -speedgrade -6 -package FBB676
add_design -verilog "e:/ZiGuangProject/2_10_hdmi_loop/ipcore/PLL/PLL.v"
add_design -verilog "e:/ZiGuangProject/2_10_hdmi_loop/source/hdmi_loop.v"
add_design -verilog "e:/ZiGuangProject/2_10_hdmi_loop/source/iic_dri.v"
add_design -verilog "e:/ZiGuangProject/2_10_hdmi_loop/source/ms72xx_ctl.v"
add_design -verilog "e:/ZiGuangProject/2_10_hdmi_loop/source/ms7200_ctl.v"
add_design -verilog "e:/ZiGuangProject/2_10_hdmi_loop/source/ms7210_ctl.v"
add_design -verilog "e:/ZiGuangProject/2_10_hdmi_loop/source/video_timing.v"
add_design -verilog "e:/ZiGuangProject/2_10_hdmi_loop/source/reg_bank.v"
add_design -verilog "e:/ZiGuangProject/2_10_hdmi_loop/source/soc/picosoc_lane.v"
add_design -verilog "e:/ZiGuangProject/2_10_hdmi_loop/source/soc/simpleuart.v"
add_design -verilog "e:/ZiGuangProject/2_10_hdmi_loop/source/soc/picorv32.v"
add_design -verilog "e:/ZiGuangProject/2_10_hdmi_loop/source/eth/rgmii_interface.v"
add_design -verilog "e:/ZiGuangProject/2_10_hdmi_loop/source/eth/ref_clock.v"
add_design -verilog "e:/ZiGuangProject/2_10_hdmi_loop/source/eth/video_downsample.v"
add_design -verilog "e:/ZiGuangProject/2_10_hdmi_loop/source/eth/eth_frame_tx.v"
add_design -verilog "e:/ZiGuangProject/2_10_hdmi_loop/source/eth/eth_udp_tx.v"
add_design -verilog "e:/ZiGuangProject/2_10_hdmi_loop/source/eth/eth_udp_video_tx.v"
add_design -verilog "e:/ZiGuangProject/2_10_hdmi_loop/source/eth/net_video_uplink.v"
add_design -verilog "e:/ZiGuangProject/2_10_hdmi_loop/source/eth/eth_rx.v"
add_design -verilog "e:/ZiGuangProject/2_10_hdmi_loop/source/eth/eth_udp_rx.v"
add_design -verilog "e:/ZiGuangProject/2_10_hdmi_loop/source/eth/eth_app_rx.v"
add_design -verilog "e:/ZiGuangProject/2_10_hdmi_loop/source/eth/net_rx_path.v"
add_design -verilog "e:/ZiGuangProject/2_10_hdmi_loop/source/eth/osd_overlay.v"
add_constraint -fdc "e:/ZiGuangProject/2_10_hdmi_loop/hdmi_loop.fdc"
compile -system_verilog -top_module hdmi_loop
synthesize -ads -selected_syn_tool_opt 2
dev_map
pnr
report_timing
gen_bit_stream
