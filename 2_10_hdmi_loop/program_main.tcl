cfg_connect -ip 127.0.0.1 -port 65420
cfg_scan_chain
cfg_assign_file -file {E:/ZiGuangProject/2_10_hdmi_loop/generate_bitstream/hdmi_loop.sbit} -device_index 0
cfg_program -device_index 0
cfg_read_device_property -device_index 0 -mode 3
cfg_disconnect
