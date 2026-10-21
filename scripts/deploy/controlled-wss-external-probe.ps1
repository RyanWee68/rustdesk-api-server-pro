# Windows PowerShell 5.1 与 PowerShell 7 共用；UTF-8 BOM 避免中文在旧版解释器中被误解析。
param([string]$Config, [switch]$SelfTest)
$ErrorActionPreference = 'Stop'

try {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;
using System.Threading;

public static class ControlledWssProbe {
    // 所有网络读写均有界；不设置证书验证回调，也不接受配置指定其他主机。
    /// <summary>以固定错误码拒绝无效测试状态。</summary>
    static void Need(bool ok, string message) { if (!ok) throw new Exception("ERR-239D " + message); }
    /// <summary>编码协议使用的 UTF-8 文本。</summary>
    static byte[] Text(string s) { return Encoding.UTF8.GetBytes(s); }
    /// <summary>连接有界协议字段。</summary>
    static byte[] Join(params byte[][] parts) { return parts.SelectMany(v => v).ToArray(); }
    /// <summary>编码 protobuf 无符号整数。</summary>
    static byte[] Varint(ulong value) {
        var b = new List<byte>();
        while (value > 127) { b.Add((byte)((value & 127) | 128)); value >>= 7; }
        b.Add((byte)value); return b.ToArray();
    }
    /// <summary>读取整数并拒绝截断或溢出。</summary>
    static ulong Integer(byte[] b, ref int i) {
        ulong n = 0;
        for (int shift = 0; shift < 64; shift += 7) {
            Need(i < b.Length, "协议整数被截断"); byte v = b[i++];
            Need(shift != 63 || v <= 1, "协议整数溢出"); n |= (ulong)(v & 127) << shift;
            if ((v & 128) == 0) return n;
        }
        throw new Exception("ERR-239D 协议整数溢出");
    }
    /// <summary>编码长度受限的字节字段。</summary>
    static byte[] Field(int n, byte[] b) { Need(n > 0 && b.Length <= 4096, "协议字段无效"); return Join(Varint((ulong)n * 8 + 2), Varint((ulong)b.Length), b); }
    /// <summary>解析探针契约中的整数和字节字段，拒绝重复字段。</summary>
    static Dictionary<int,object> Fields(byte[] b) {
        Need(b != null && b.Length <= 4096, "协议消息无效");
        var d = new Dictionary<int,object>(); int i = 0;
        while (i < b.Length) {
            ulong t = Integer(b, ref i); Need(t >> 3 > 0 && t >> 3 <= 536870911, "协议字段编号无效");
            int n = (int)(t >> 3); Need(!d.ContainsKey(n), "协议字段重复");
            if ((t & 7) == 0) d.Add(n, Integer(b, ref i));
            else {
                Need((t & 7) == 2, "协议字段类型无效"); ulong size = Integer(b, ref i);
                Need(size <= (ulong)(b.Length - i), "协议字段被截断");
                d.Add(n, b.Skip(i).Take((int)size).ToArray()); i += (int)size;
            }
        }
        return d;
    }
    /// <summary>严格读取必需的字节字段。</summary>
    static byte[] Bytes(Dictionary<int,object> d, int n) {
        Need(d.ContainsKey(n) && d[n] is byte[], "缺少协议字节字段"); return (byte[])d[n];
    }
    /// <summary>检查外层消息类型后解析消息体。</summary>
    static Dictionary<int,object> Body(byte[] b, int n) {
        var d = Fields(b); Need(d.Count == 1 && d.ContainsKey(n), "业务响应类型不符"); return Fields(Bytes(d,n));
    }
    /// <summary>仅接受服务端契约中的规范 UUID v4。</summary>
    static string Session(Dictionary<int,object> d) {
        string s = Encoding.UTF8.GetString(Bytes(d,2)); Guid g;
        Need(Guid.TryParseExact(s,"D",out g) && g.ToString("D") == s && s[14] == '4', "中继会话编号无效"); return s;
    }
    /// <summary>直连受控入口，避免系统代理混淆独立外网来源证据。</summary>
    static ClientWebSocket DirectSocket() {
        var w = new ClientWebSocket(); w.Options.Proxy = null; return w;
    }
    /// <summary>使用默认系统证书验证连接固定的受控 WSS 入口。</summary>
    static ClientWebSocket Connect(int port) {
        var w = DirectSocket();
        try { using (var c = new CancellationTokenSource(10000)) w.ConnectAsync(new Uri("wss://rustdesk.jtzxsoft.com:" + port + "/"), c.Token).GetAwaiter().GetResult(); return w; }
        catch { w.Dispose(); throw; }
    }
    /// <summary>在超时限制内发送二进制消息。</summary>
    static void Send(ClientWebSocket w, byte[] b) {
        Need(b.Length > 0 && b.Length <= 4096, "待发送消息越界");
        using (var c = new CancellationTokenSource(10000)) w.SendAsync(new ArraySegment<byte>(b),WebSocketMessageType.Binary,true,c.Token).GetAwaiter().GetResult();
    }
    /// <summary>重组有界二进制消息，关闭帧返回空值。</summary>
    static byte[] Read(ClientWebSocket w) {
        using (var c = new CancellationTokenSource(10000)) using (var m = new MemoryStream()) {
            var b = new byte[4096];
            while (true) {
                var r = w.ReceiveAsync(new ArraySegment<byte>(b),c.Token).GetAwaiter().GetResult();
                if (r.MessageType == WebSocketMessageType.Close) return null;
                Need(r.MessageType == WebSocketMessageType.Binary && m.Length + r.Count <= 4096,"中继数据类型或长度错误");
                m.Write(b,0,r.Count); if (r.EndOfMessage) return m.ToArray();
            }
        }
    }
    /// <summary>计算随机挑战的摘要。</summary>
    static byte[] Hash(byte[] b) { Need(b != null, "中继连接提前关闭"); using (var h = SHA256.Create()) return h.ComputeHash(b); }
    /// <summary>比较非凭据测试数据。</summary>
    static bool Same(byte[] a, byte[] b) { return a != null && b != null && a.SequenceEqual(b); }
    /// <summary>验证已核销会话关闭，最终拒绝审计仍须服务端核对。</summary>
    static void Replay(byte[] payload) {
        using (var w = Connect(22119)) {
            Send(w,payload);
            try { Need(Read(w) == null,"重放未关闭"); }
            catch (WebSocketException e) { if (e.WebSocketErrorCode != WebSocketError.ConnectionClosedPrematurely) throw; }
        }
    }
    /// <summary>禁止过期后继续申请或核销会话。</summary>
    static void Alive(DateTime expires) {
        Need(DateTime.UtcNow < expires,"测试窗口已过期，请申请新窗口");
        Need(expires <= DateTime.UtcNow.AddMinutes(45),"测试有效期无效");
    }
    /// <summary>执行源端或目标端的三次授权数据往返与重放探针。</summary>
    public static string[] Run(string role, string target, string key, string credential, DateTime expires) {
        Need(role == "source" || role == "target", "测试角色无效");
        Need(System.Text.RegularExpressions.Regex.IsMatch(target,@"^[1-9][0-9]{8}$"),"目标编号无效");
        Alive(expires);
        var sessions = new List<string>();
        if (role == "source") {
            Need(Convert.FromBase64String(key).Length == 32 && System.Text.RegularExpressions.Regex.IsMatch(credential,@"^[A-Za-z0-9_-]{64}$"),"测试凭据格式无效");
            for (int i=0; i<3; i++) {
                Alive(expires); string session;
                byte[] request = Field(8,Join(Field(1,Text(target)),Field(3,Text(key)),Field(5,Text(credential)),Field(6,Text("1.5.0")),new byte[]{64,1}));
                using (var w = Connect(22118)) { Send(w,request); var d = Body(Read(w),19); session = Session(d); Need(Bytes(d,3).Length > 0 && Bytes(d,5).Length > 0,"签发响应不完整"); }
                Need(!sessions.Contains(session),"中继会话被重复签发");
                byte[] payload = Field(18,Field(2,Text(session)));
                using (var w = Connect(22119)) {
                    Send(w,payload); var challenge = new byte[256]; using(var rng=RandomNumberGenerator.Create()) rng.GetBytes(challenge);
                    Send(w,challenge); byte[] answer = Read(w); Need(Same(answer,Hash(challenge)),"双向数据校验失败"); Send(w,Hash(answer));
                }
                Replay(payload); sessions.Add(session); Console.WriteLine("PASS source " + (i+1) + " " + DateTime.Now.ToString("HH:mm:ss"));
            }
        } else {
            byte[] registration = Field(15,Join(Field(1,Text(target)),Field(2,Convert.FromBase64String(key)),Field(3,Convert.FromBase64String(credential))));
            Need(Convert.FromBase64String(key).Length == 16 && Convert.FromBase64String(credential).Length == 32,"注册身份格式无效");
            var ip = Dns.GetHostAddresses("rustdesk.jtzxsoft.com").First(v => v.AddressFamily == AddressFamily.InterNetwork);
            var endpoint = new IPEndPoint(ip,22116); bool ready = false;
            using (var udp = new UdpClient(AddressFamily.InterNetwork)) {
                udp.Client.ReceiveTimeout=1000; DateTime next=DateTime.MinValue;
                while (sessions.Count<3) {
                    Alive(expires);
                    if (DateTime.UtcNow>=next) { udp.Send(registration,registration.Length,endpoint); next=DateTime.UtcNow.AddSeconds(10); }
                    IPEndPoint from = new IPEndPoint(IPAddress.Any,0); byte[] packet;
                    try { packet=udp.Receive(ref from); }
                    catch(SocketException e) { if (e.SocketErrorCode==SocketError.TimedOut) continue; throw; }
                    Need(from.Address.Equals(ip) && from.Port==22116,"注册消息来源不匹配");
                    var outer=Fields(packet);
                    if (outer.ContainsKey(16)) {
                        var d=Body(packet,16);
                        Need(!d.ContainsKey(1) || d[1] is ulong,"注册状态类型错误");
                        ulong status=d.ContainsKey(1) ? (ulong)d[1] : 0;
                        Need(status==0,"测试设备注册被拒绝，协议状态码：" + status);
                        if (!ready) { Console.WriteLine("READY target"); ready=true; } continue;
                    }
                    var relay=Body(packet,18); Need(Encoding.UTF8.GetString(Bytes(relay,1))==target,"通知目标不匹配"); string session=Session(relay);
                    Need(ready && !sessions.Contains(session),"注册未完成或通知重复");
                    byte[] payload=Field(18,Field(2,Text(session)));
                    using(var w=Connect(22119)) {
                        Send(w,payload); byte[] challenge=Read(w); Need(challenge!=null && challenge.Length==256,"挑战消息长度错误");
                        byte[] answer=Hash(challenge); Send(w,answer); Need(Same(Read(w),Hash(answer)),"源端未确认双向数据");
                    }
                    Replay(payload); sessions.Add(session); Console.WriteLine("PASS target " + sessions.Count + " " + DateTime.Now.ToString("HH:mm:ss"));
                }
            }
        }
        return sessions.ToArray();
    }
    /// <summary>离线覆盖字段边界、畸形消息和过期窗口。</summary>
    public static void SelfTest() {
        Need(BitConverter.ToString(Field(25,Field(1,Text("x"))))=="CA-01-03-0A-01-78","固定协议字节错误");
        foreach(int size in new int[]{1,125,126,256,4090}) Need(Bytes(Fields(Field(18,new byte[size])),18).Length==size,"字段往返错误");
        foreach(byte[] bad in new byte[][]{new byte[]{0},new byte[]{10,2,1},new byte[]{10,0,10,0},new byte[]{15},new byte[]{255,255,255,255,255,255,255,255,255,2}}) {
            bool failed=false; try{Fields(bad);}catch{failed=true;} Need(failed,"畸形协议未拒绝");
        }
        string session = "12345678-1234-4234-8234-123456789abc";
        Need(Session(Fields(Field(2,Text(session)))) == session,"UUID v4 会话往返错误");
        foreach(string s in new string[]{"bad","00000000000000000000000000000000","00000000-0000-0000-0000-00000000000Z","00000000-0000-0000-0000-000000000000","12345678-1234-1234-8234-123456789abc","12345678-1234-5234-8234-123456789abc",session.ToUpperInvariant()}) {
            bool failed=false; try{Session(Fields(Field(2,Text(s))));}catch{failed=true;} Need(failed,"会话编号未拒绝");
        }
        using (var w = DirectSocket()) Need(w.Options.Proxy == null && w.State == WebSocketState.None,"直连 WSS 配置错误");
        bool expired=false; try{Alive(DateTime.UtcNow.AddSeconds(-1));}catch{expired=true;} Need(expired,"过期窗口未拒绝");
        foreach (int minutes in new int[]{30,44}) Alive(DateTime.UtcNow.AddMinutes(minutes));
        bool excessive=false; try{Alive(DateTime.UtcNow.AddMinutes(46));}catch{excessive=true;} Need(excessive,"超长窗口未拒绝");
        Need(Hash(new byte[]{1}).Length==32,"随机消息摘要错误");
    }
}
'@
    if ($SelfTest) { [ControlledWssProbe]::SelfTest(); Write-Output 'PASS self-test'; exit 0 }
    if (-not $Config -or -not (Test-Path -LiteralPath $Config -PathType Leaf)) { throw 'ERR-239D 缺少本轮私有配置文件' }
    $file = Get-Item -LiteralPath $Config
    if ($file.Length -gt 4096 -or $file.LinkType) { throw 'ERR-239D 配置文件大小或类型无效' }
    $data = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
    if ($data.run -notmatch '^[0-9a-f]{32}$') { throw 'ERR-239D 测试标识无效' }
    $expires = [DateTimeOffset]::Parse($data.expires_utc).UtcDateTime
    if ($data.role -eq 'source') { $key = $data.public_key; $credential = $data.token }
    elseif ($data.role -eq 'target') { $key = $data.device_uuid; $credential = $data.fingerprint }
    else { throw 'ERR-239D 配置角色无效' }
    $sessions = [ControlledWssProbe]::Run($data.role, $data.target, $key, $credential, $expires)
    $result = [ordered]@{ run = $data.run; role = $data.role; time_utc = [DateTime]::UtcNow.ToString('o'); sessions = @($sessions); bidirectional = $true; replays_rejected = 3 }
    $output = Join-Path $file.DirectoryName ('wss-' + $data.role + '-result-' + $data.run + '.json')
    $result | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $output -Encoding UTF8
    Write-Output ('PASS complete: ' + $output)
} catch {
    $cause = $_.Exception.GetBaseException()
    if ($cause.Message.StartsWith('ERR-239D ')) { [Console]::Error.WriteLine($cause.Message) }
    elseif ($cause -is [System.Net.Sockets.SocketException]) { [Console]::Error.WriteLine('ERR-239D 网络套接字错误：' + $cause.SocketErrorCode) }
    else { [Console]::Error.WriteLine('ERR-239D WSS 验收失败：' + $cause.GetType().Name + '；请核对本轮配置、系统时间及证书信任，不要关闭证书校验。') }
    exit 1
}
