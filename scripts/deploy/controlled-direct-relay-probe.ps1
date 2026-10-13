param(
    [Parameter(Mandatory = $true)]
    [string]$ServerAddress,
    [int]$Port = 21117,
    [string]$SessionUuid = ''
)

$ErrorActionPreference = 'Stop'

# 固定基线协议：RequestRelay.uuid 为字段 2，RendezvousMessage.request_relay 为字段 18。
$uuid = if ($SessionUuid) { $SessionUuid } else { [guid]::NewGuid().ToString() }
$uuidBytes = [System.Text.Encoding]::UTF8.GetBytes($uuid)
$relayRequest = [byte[]](@(0x12, [byte]$uuidBytes.Length) + $uuidBytes)
$rendezvousMessage = [byte[]](@(0x92, 0x01, [byte]$relayRequest.Length) + $relayRequest)
if ($rendezvousMessage.Length -gt 63) {
    throw 'ERR-239D 中继探针帧超出单字节长度编码范围'
}
$frame = [byte[]](@([byte]($rendezvousMessage.Length -shl 2)) + $rendezvousMessage)

$client = [System.Net.Sockets.TcpClient]::new()
try {
    $connect = $client.BeginConnect($ServerAddress, $Port, $null, $null)
    if (-not $connect.AsyncWaitHandle.WaitOne(5000)) {
        throw 'ERR-239D 连接中继服务器超时'
    }
    $client.EndConnect($connect)
    $stream = $client.GetStream()
    $stream.ReadTimeout = 6000
    $stream.Write($frame, 0, $frame.Length)
    $buffer = [byte[]]::new(1)
    if ($stream.Read($buffer, 0, 1) -ne 0) {
        throw 'ERR-239D 未签发中继会话收到意外数据'
    }
    Write-Output 'PASS: 无效中继会话连接被关闭；仍需核对 hbbr 日志中的 ERR-2315'
}
catch {
    if ($_.Exception.Message -like 'ERR-*') {
        throw
    }
    throw "ERR-239D 直连中继探针失败：$($_.Exception.Message)"
}
finally {
    $client.Dispose()
}
