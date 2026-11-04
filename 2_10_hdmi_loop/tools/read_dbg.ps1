# 读串口调试字并带时间戳，用来算 FPGA 真实发包率
# 用法: powershell -File tools\read_dbg.ps1 [秒数]
param([int]$Seconds = 12)

$port = New-Object System.IO.Ports.SerialPort COM10,115200,None,8,one
$port.ReadTimeout = 300
try {
    $port.Open()
} catch {
    Write-Output "COM10 打不开: $_"
    exit 1
}

$buf  = New-Object System.Text.StringBuilder
$t0   = Get-Date
$end  = $t0.AddSeconds($Seconds)

while ((Get-Date) -lt $end) {
    $s = $port.ReadExisting()
    if ($s) {
        [void]$buf.Append($s)
        # 每收到一行就带上相对时间
        $parts = $buf.ToString() -split "`r`n"
        if ($parts.Count -gt 1) {
            [void]$buf.Clear()
            [void]$buf.Append($parts[-1])
            foreach ($line in $parts[0..($parts.Count - 2)]) {
                if ($line -match 'dbg=(\d+)') {
                    $ms = [int]((Get-Date) - $t0).TotalMilliseconds
                    "t=$ms ms   dbg=$($Matches[1])"
                }
            }
        }
    }
    Start-Sleep -Milliseconds 60
}
$port.Close()
