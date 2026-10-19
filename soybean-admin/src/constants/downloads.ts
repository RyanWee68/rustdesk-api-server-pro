export const clientDownloads = [
  {
    version: '1.5.0',
    url: '/downloads/rustdesk-1.5.0-x86_64.exe',
    sha256: '8555777215510D83D2D61C9DC984E4FCC838BD7E79F9D18A42585431F5E8BB47'
  },
  {
    version: '1.4.9',
    url: '/downloads/rustdesk-1.4.9-x86_64.exe',
    sha256: 'EAEDEB0088E687BF46F7C46A9C6EA5493CE51F3134DFD6ACBEDB47B5B9136274'
  }
];

export const certificateDownload = {
  url: '/downloads/rustdesk.jtzxsoft.com.cert.cer',
  sha256: 'F56A892AB90B0E85687403979D5F9901084B6E2657C74EFF6DC9E93AEDE0D96D'
};

export const certificateInstallCommand = `$certPath = Join-Path $env:USERPROFILE 'Downloads\\rustdesk.jtzxsoft.com.cert.cer'
if (-not (Test-Path -LiteralPath $certPath -PathType Leaf)) {
    throw 'ERR-1019: 请先将证书保存到当前用户的下载文件夹'
}
if ((Get-FileHash -LiteralPath $certPath -Algorithm SHA256).Hash -ne '${certificateDownload.sha256}') {
    throw 'ERR-1019: 证书指纹不匹配，已停止导入'
}
certutil.exe -user -addstore -f Root "$certPath"
if ($LASTEXITCODE -ne 0) {
    throw 'ERR-1019: 证书导入失败，请检查上述输出'
}`;
