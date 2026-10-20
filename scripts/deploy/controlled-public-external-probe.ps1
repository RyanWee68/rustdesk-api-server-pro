# Windows PowerShell 5.1 / PowerShell 7；不登录、不修改证书信任或服务状态。
param([string]$OutputDirectory = [Environment]::GetFolderPath('Desktop'), [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

# 基准测试网段常被 DNS 代理用于合成地址，不可当公网端口证据。
function Test-SyntheticDns([string[]]$Addresses) {
    foreach ($address in $Addresses) {
        if ($address -match '^(::ffff:)?198\.(18|19)\.') { return $true }
    }
    return $false
}

# 将网络错误保守归类；只有明确拒绝才证明本次连接未开放。
function Get-PortState($ErrorCode) {
    if ($ErrorCode -eq [System.Net.Sockets.SocketError]::Success) { return 'open' }
    if ($ErrorCode -eq [System.Net.Sockets.SocketError]::ConnectionRefused) { return 'refused' }
    return 'unknown'
}

# 连接固定公开主机，超时和解析失败不冒充关闭。
function Test-PublicPort([int]$Port) {
    $client = [System.Net.Sockets.TcpClient]::new()
    $pending = $null
    try {
        $pending = $client.BeginConnect('rustdesk.jtzxsoft.com', $Port, $null, $null)
        if (-not $pending.AsyncWaitHandle.WaitOne(4000)) { return 'unknown' }
        $client.EndConnect($pending)
        return 'open'
    } catch {
        $cause = $_.Exception.GetBaseException()
        if ($cause -is [System.Net.Sockets.SocketException]) { return Get-PortState $cause.SocketErrorCode }
        return 'unknown'
    } finally {
        $client.Dispose()
        if ($null -ne $pending) { $pending.AsyncWaitHandle.Close() }
    }
}

# 只发送无 UUID/公钥的随机心跳，最高配置序号避免额外配置响应。
function New-UdpHeartbeat([string]$Nonce) {
    if ($Nonce -cnotmatch '^[0-9a-f]{32}$') { throw 'ERR-2394 UDP 随机标识无效' }
    $id = [Text.Encoding]::ASCII.GetBytes('controlled-udp-' + $Nonce)
    $body = [byte[]](@(10, $id.Length) + $id + @(16, 255, 255, 255, 255, 7))
    return ,([byte[]](@(50, $body.Length) + $body))
}

# 固定响应是 RegisterPeerResponse.request_pk=true，不代表已注册或获准远控。
function Test-UdpHeartbeatResponse([byte[]]$Response) {
    return $null -ne $Response -and [BitConverter]::ToString($Response) -ceq '3A-02-10-01'
}

# 使用已校验的 IPv4；连接式 UDP 及源地址检查排除其他来源的数据。
function Test-PublicUdp([string]$Address) {
    $ip = [Net.IPAddress]::Parse($Address)
    if ($ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or (Test-SyntheticDns @($Address))) { throw 'ERR-2394 UDP 地址无效' }
    $udp = [Net.Sockets.UdpClient]::new([Net.Sockets.AddressFamily]::InterNetwork)
    try {
        $udp.Client.ReceiveTimeout = 4000
        $udp.Client.SendTimeout = 4000
        $udp.Connect($ip, 22116)
        $payload = New-UdpHeartbeat ([Guid]::NewGuid().ToString('N'))
        $null = $udp.Send($payload, $payload.Length)
        $sender = [Net.IPEndPoint]::new([Net.IPAddress]::Any, 0)
        $response = $udp.Receive([ref]$sender)
        return $sender.Address.Equals($ip) -and $sender.Port -eq 22116 -and (Test-UdpHeartbeatResponse $response)
    } finally { $udp.Dispose() }
}

# 流式读取并限制大小及总时长，安装包只计算摘要，不落盘或执行。
function Read-ProbeBody([System.IO.Stream]$Stream, [int]$Limit, [bool]$KeepBody, [Diagnostics.Stopwatch]$Clock) {
    $hash = [Security.Cryptography.SHA256]::Create()
    $memory = [IO.MemoryStream]::new()
    $buffer = New-Object byte[] 16384
    $total = 0
    try {
        while ($true) {
            if ($Clock.Elapsed.TotalSeconds -gt 60) { throw 'ERR-2394 响应读取超时' }
            $count = $Stream.Read($buffer, 0, $buffer.Length)
            if ($count -eq 0) { break }
            $total += $count
            if ($total -gt $Limit) { throw 'ERR-2394 响应大小超过限制' }
            $null = $hash.TransformBlock($buffer, 0, $count, $buffer, 0)
            if ($KeepBody) { $memory.Write($buffer, 0, $count) }
        }
        $null = $hash.TransformFinalBlock($buffer, 0, 0)
        return @{ bytes = $total; sha256 = ([BitConverter]::ToString($hash.Hash)).Replace('-', '').ToLowerInvariant(); body = [Text.Encoding]::UTF8.GetString($memory.ToArray()) }
    } finally { $hash.Dispose(); $memory.Dispose() }
}

# 仅访问固定端点，无代理、凭据、Cookie、跳转或证书绕过。
function Get-PublicResponse([string]$Url, [int]$Limit = 65536, [bool]$KeepBody = $true) {
    $uri = [Uri]$Url
    if ($uri.Host -ne 'rustdesk.jtzxsoft.com' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or
        $uri.Scheme -notin @('http', 'https') -or $uri.Port -notin @(22345, 22346)) { throw 'ERR-2394 公开检查地址无效' }
    $request = [Net.HttpWebRequest]::Create($uri)
    $request.Proxy = $null
    $request.AllowAutoRedirect = $false
    $request.Timeout = 60000
    $request.ReadWriteTimeout = 5000
    $request.KeepAlive = $false
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $response = $null
    $stream = $null
    try {
        try { $response = $request.GetResponse() }
        catch [Net.WebException] {
            if ($null -eq $_.Exception.Response) { throw }
            $response = $_.Exception.Response
        }
        $stream = $response.GetResponseStream()
        $body = Read-ProbeBody $stream $Limit $KeepBody $clock
        $body.status = [int]$response.StatusCode
        return $body
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $response) { $response.Close() }
        $request.Abort()
    }
}

# 与 Linux 公网探针保持相同的 API JSON 契约。
function Test-PublicApi([string]$Name, [string]$Body) {
    try {
        $data = ConvertFrom-Json -InputObject $Body
        if ($Name -eq 'health') {
            return $null -ne $data -and $data.ok -is [bool] -and $data.ok -and $data.service -ceq 'rustdesk-api-server-pro'
        }
        if ($Name -ne 'login-options' -or -not $Body.TrimStart().StartsWith('[')) { return $false }
        # 包装数组以保留 PowerShell 7 管道原本会丢弃的 null 元素。
        $array = ConvertFrom-Json -InputObject ('{"items":' + $Body + '}')
        foreach ($item in $array.items) { if ($item -isnot [string]) { return $false } }
        return $true
    } catch { return $false }
}

# 自测不连接网络、不生成文件、不修改系统证书库。
function Test-ProbeSelf {
    $packet = New-UdpHeartbeat ('0' * 32)
    $expectedId = [Text.Encoding]::ASCII.GetBytes('controlled-udp-' + ('0' * 32))
    if ($packet.Length -ne 57 -or $packet[0] -ne 50 -or $packet[1] -ne 55 -or
        $packet[2] -ne 10 -or $packet[3] -ne 47 -or
        [BitConverter]::ToString($packet[4..50]) -ne [BitConverter]::ToString($expectedId) -or
        [BitConverter]::ToString($packet[51..56]) -ne '10-FF-FF-FF-FF-07') { throw 'ERR-2394 UDP 心跳编码自测失败' }
    if (-not (Test-UdpHeartbeatResponse ([byte[]]@(58, 2, 16, 1)))) { throw 'ERR-2394 UDP 响应自测失败' }
    foreach ($bad in @([byte[]]@(), [byte[]]@(58, 2, 16, 0), [byte[]]@(58, 2, 16), [byte[]]@(58, 2, 16, 1, 0), [byte[]]@(130, 1, 2, 8, 8))) {
        if (Test-UdpHeartbeatResponse $bad) { throw 'ERR-2394 UDP 错误响应未拒绝' }
    }
    $rejected = $false
    try { $null = New-UdpHeartbeat 'bad' } catch { $rejected = $true }
    if (-not $rejected) { throw 'ERR-2394 UDP 标识边界未拒绝' }
    if (-not (Test-SyntheticDns @('198.18.0.114')) -or -not (Test-SyntheticDns @('::ffff:198.19.255.254')) -or
        (Test-SyntheticDns @('171.217.92.118', '198.20.0.1'))) { throw 'ERR-2394 合成 DNS 识别自测失败' }
    foreach ($case in @(
        @('health', '{"ok":true,"service":"rustdesk-api-server-pro"}', $true),
        @('health', '{"ok":"true","service":"rustdesk-api-server-pro"}', $false),
        @('health', '{"ok":true,"service":"other"}', $false),
        @('health', '<html>login</html>', $false),
        @('login-options', '[]', $true),
        @('login-options', '["password","oidc"]', $true),
        @('login-options', '[null]', $false),
        @('login-options', '["password",null]', $false),
        @('login-options', '[["password"]]', $false),
        @('login-options', '{"data":[]}', $false),
        @('login-options', '[1]', $false)
    )) {
        if ((Test-PublicApi $case[0] $case[1]) -ne $case[2]) { throw 'ERR-2394 API 自测失败' }
    }
    foreach ($url in @('http://other.test:22345/', 'https://user:secret@rustdesk.jtzxsoft.com:22346/',
        'https://rustdesk.jtzxsoft.com:22346/?token=secret', 'https://rustdesk.jtzxsoft.com:22347/',
        'file:///windows/win.ini')) {
        $rejected = $false
        try { $null = Get-PublicResponse $url } catch { $rejected = $_.Exception.Message -eq 'ERR-2394 公开检查地址无效' }
        if (-not $rejected) { throw 'ERR-2394 地址边界自测失败' }
    }
    if ((Get-PortState ([Net.Sockets.SocketError]::Success)) -ne 'open' -or
        (Get-PortState ([Net.Sockets.SocketError]::ConnectionRefused)) -ne 'refused' -or
        (Get-PortState ([Net.Sockets.SocketError]::TimedOut)) -ne 'unknown' -or
        (Get-PortState ([Net.Sockets.SocketError]::HostNotFound)) -ne 'unknown') { throw 'ERR-2394 端口分类自测失败' }
    $memory = [IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes('abc'))
    try {
        $body = Read-ProbeBody $memory 3 $true ([Diagnostics.Stopwatch]::StartNew())
        if ($body.bytes -ne 3 -or $body.body -ne 'abc' -or $body.sha256 -ne 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad') { throw 'ERR-2394 摘要自测失败' }
        $memory.Position = 0
        $rejected = $false
        try { $null = Read-ProbeBody $memory 2 $false ([Diagnostics.Stopwatch]::StartNew()) } catch { $rejected = $true }
        if (-not $rejected) { throw 'ERR-2394 响应大小限制自测失败' }
        $memory.Position = 0
        if ((Read-ProbeBody $memory 3 $false ([Diagnostics.Stopwatch]::StartNew())).body -ne '') { throw 'ERR-2394 安装包正文意外保留' }
    } finally { $memory.Dispose() }
    Write-Output 'PASS self-test'
}

# 仅输出固定检查名称和状态，不记录响应正文、异常消息或请求头。
function Add-ProbeResult([string]$Name, [bool]$Passed, [string]$Detail) {
    $state = 'fail'
    if ($Passed) { $state = 'pass' }
    $script:checks.Add([ordered]@{ name = $Name; state = $state; detail = $Detail })
    if ($Passed) { Write-Output ('PASS ' + $Name) } else { Write-Output ('ERR-2394 ' + $Name + ': ' + $Detail) }
}

try {
    if ($SelfTest) { Test-ProbeSelf; exit 0 }
    if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) { throw 'ERR-2394 结果目录不存在' }
    $script:checks = [Collections.Generic.List[object]]::new()
    $started = [DateTime]::UtcNow.ToString('o')
    $addresses = @()
    $tcpUsable = $false
    try {
        $dns = [Net.Dns]::GetHostAddressesAsync('rustdesk.jtzxsoft.com')
        if (-not $dns.Wait(4000)) { throw 'ERR-2394 DNS 超时' }
        $addresses = @($dns.Result | ForEach-Object { $_.IPAddressToString })
        $tcpUsable = $addresses.Count -gt 0 -and -not (Test-SyntheticDns $addresses)
        Add-ProbeResult 'dns-no-synthetic-address' $tcpUsable 'synthetic-dns-invalidates-tcp-evidence'
    } catch { Add-ProbeResult 'dns-no-synthetic-address' $false 'dns-unconfirmed' }
    foreach ($port in @(22115, 22116, 22117, 22345, 22346)) {
        $state = 'unknown'
        if ($tcpUsable) { $state = Test-PublicPort $port }
        Add-ProbeResult "tcp-$port-open" ($state -eq 'open') $state
    }
    # 21115–21119 属于用户保留的独立正式服务，不要求关闭。
    foreach ($port in @(12345, 12346, 22347)) {
        $state = 'unknown'
        if ($tcpUsable) { $state = Test-PublicPort $port }
        Add-ProbeResult "tcp-$port-closed" ($state -eq 'refused') $state
    }
    $ipv4 = @($addresses | Where-Object { ([Net.IPAddress]::Parse($_)).AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork })
    foreach ($attempt in 1..3) {
        try {
            if (-not $tcpUsable -or $ipv4.Count -eq 0) { throw 'ERR-2394 UDP DNS 不可用' }
            Add-ProbeResult "udp-22116-heartbeat-$attempt" (Test-PublicUdp $ipv4[0]) 'request-public-key-response-required'
        } catch { Add-ProbeResult "udp-22116-heartbeat-$attempt" $false 'udp-response-unconfirmed' }
    }
    foreach ($name in @('health', 'login-options')) {
        try {
            $response = Get-PublicResponse "http://rustdesk.jtzxsoft.com:22345/api/$name"
            Add-ProbeResult "api-$name" ($response.status -eq 200 -and (Test-PublicApi $name $response.body)) 'http-json-contract'
        } catch { Add-ProbeResult "api-$name" $false 'connection-or-response-invalid' }
    }
    try {
        $response = Get-PublicResponse 'https://rustdesk.jtzxsoft.com:22346/' 2097152 $false
        Add-ProbeResult 'management-https' ($response.status -eq 200) 'system-certificate-validation'
    } catch { Add-ProbeResult 'management-https' $false 'connection-or-certificate-invalid' }
    try {
        $response = Get-PublicResponse 'http://rustdesk.jtzxsoft.com:22346/'
        Add-ProbeResult 'management-plaintext-denied' ($response.status -ge 400 -and $response.status -le 599) 'http-rejection-required'
    } catch { Add-ProbeResult 'management-plaintext-denied' $false 'rejection-unconfirmed' }
    $downloads = [ordered]@{
        'rustdesk.jtzxsoft.com.cert.cer' = 'f56a892ab90b0e85687403979d5f9901084b6e2657c74eff6dc9e93aede0d96d'
        'rustdesk-1.4.9-x86_64.exe' = 'eaedeb0088e687bf46f7c46a9c6ea5493ce51f3134dfd6acbedb47b5b9136274'
        'rustdesk-1.5.0-x86_64.exe' = '8555777215510d83d2d61c9dc984e4fcc838bd7e79f9d18a42585431f5e8bb47'
    }
    foreach ($name in $downloads.Keys) {
        try {
            $response = Get-PublicResponse "https://rustdesk.jtzxsoft.com:22346/downloads/$name" 33554432 $false
            Add-ProbeResult "download-$name" ($response.status -eq 200 -and $response.sha256 -eq $downloads[$name]) 'sha256-match-required'
        } catch { Add-ProbeResult "download-$name" $false 'connection-certificate-or-size-invalid' }
    }
    foreach ($port in @(22118, 22119)) {
        $socket = [Net.WebSockets.ClientWebSocket]::new()
        $socket.Options.Proxy = $null
        $cancel = [Threading.CancellationTokenSource]::new(10000)
        try {
            $null = $socket.ConnectAsync([Uri]"wss://rustdesk.jtzxsoft.com:$port/", $cancel.Token).GetAwaiter().GetResult()
            Add-ProbeResult "wss-$port" ($socket.State -eq [Net.WebSockets.WebSocketState]::Open) 'transport-only'
        } catch { Add-ProbeResult "wss-$port" $false 'connection-certificate-or-upgrade-invalid' }
        finally { $socket.Dispose(); $cancel.Dispose() }
    }
    $failed = @($checks | Where-Object { $_.state -eq 'fail' }).Count
    $report = [ordered]@{
        schema = 1; started_utc = $started; finished_utc = [DateTime]::UtcNow.ToString('o')
        host = 'rustdesk.jtzxsoft.com'; checks = @($checks.ToArray()); failed = $failed
        dns_addresses = $addresses; tcp_observation_usable = $tcpUsable
        excluded_tcp_ports = @(21115, 21116, 21117, 21118, 21119)
        exclusion_reason = 'user-confirmed-separate-official-production-server'
        external_network_human_confirmation = $false
        udp_probe = 'unregistered-heartbeat-no-device-write'
        not_verified = @('independent-network-origin', 'udp-authenticated-registration-and-nat-switch', 'internal-auth', 'client-login-and-remote', 'windows-install-and-launch', 'browser-remote')
    }
    $file = Join-Path $OutputDirectory ('controlled-public-result-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '.json')
    $report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $file -Encoding UTF8
    Write-Output ('RESULT ' + $file)
    Write-Output 'PARTIAL: UDP 仅验证心跳收发；独立来源、注册鉴权/切网、安装启动及客户端/浏览器远控仍需另验。'
    if ($failed -gt 0) { exit 1 }
} catch {
    [Console]::Error.WriteLine('ERR-2394 公网检查未完成，请检查路径、系统时间和证书信任；不要关闭证书校验。')
    exit 1
}
