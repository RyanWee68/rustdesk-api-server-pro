<script setup lang="ts">
const certificateUrl = '/downloads/rustdesk.jtzxsoft.com.cert.cer';
const installerUrl = '/downloads/rustdesk-1.5.0-x86_64.exe';
const legacyInstallerUrl = '/downloads/rustdesk-1.4.9-x86_64.exe';
const certificateFingerprint =
  'F5:6A:89:2A:B9:0B:0E:85:68:74:03:97:9D:5F:99:01:08:4B:6E:26:57:C7:4E:FF:6D:C9:E9:3A:ED:E0:D9:6D';
const installerSha256 = '8555777215510D83D2D61C9DC984E4FCC838BD7E79F9D18A42585431F5E8BB47';
const legacyInstallerSha256 = 'EAEDEB0088E687BF46F7C46A9C6EA5493CE51F3134DFD6ACBEDB47B5B9136274';
</script>

<template>
  <div class="downloads-page mt-16px">
    <NAlert type="info" :bordered="false">
      公网管理地址为 https://rustdesk.jtzxsoft.com:22346；局域网可使用 http://192.168.0.211:22347。
    </NAlert>

    <div class="downloads-grid mt-16px">
      <NCard title="管理页证书" :bordered="false" size="small">
        <NDescriptions :column="1" label-placement="left" bordered size="small">
          <NDescriptionsItem label="域名">rustdesk.jtzxsoft.com</NDescriptionsItem>
          <NDescriptionsItem label="有效期">2026-10-16 至 2036-10-13</NDescriptionsItem>
          <NDescriptionsItem label="SHA-256 指纹">
            <NText code class="break-all">{{ certificateFingerprint }}</NText>
          </NDescriptionsItem>
        </NDescriptions>
        <NButton tag="a" :href="certificateUrl" type="primary" class="mt-16px">
          <template #icon><SvgIcon icon="mdi:certificate-outline" /></template>
          下载证书
        </NButton>
      </NCard>

      <NCard title="RustDesk 客户端" :bordered="false" size="small">
        <NDescriptions :column="1" label-placement="left" bordered size="small">
          <NDescriptionsItem label="版本">1.5.0 x86_64</NDescriptionsItem>
          <NDescriptionsItem label="文件大小">24.69 MiB</NDescriptionsItem>
          <NDescriptionsItem label="SHA-256">
            <NText code class="break-all">{{ installerSha256 }}</NText>
          </NDescriptionsItem>
        </NDescriptions>
        <NButton tag="a" :href="installerUrl" type="primary" class="mt-16px">
          <template #icon><SvgIcon icon="mdi:download-outline" /></template>
          下载 1.5.0 安装包
        </NButton>
        <NButton tag="a" :href="legacyInstallerUrl" :title="legacyInstallerSha256" text class="ml-16px mt-16px">
          <template #icon><SvgIcon icon="mdi:download-outline" /></template>
          下载 1.4.9 安装包
        </NButton>
      </NCard>
    </div>

    <NCard title="Windows 安装证书" :bordered="false" size="small" class="mt-16px">
      <NSteps vertical :current="1" status="process">
        <NStep title="下载证书" description="点击上方“下载证书”，保存 .cer 文件。" />
        <NStep title="打开证书导入向导" description="双击证书，选择“安装证书”，存储位置选择“当前用户”。" />
        <NStep title="选择受信任的根证书颁发机构" description="选择“将所有的证书都放入下列存储”，指定“受信任的根证书颁发机构”。" />
        <NStep title="确认并重启浏览器" description="完成导入并确认安全警告，然后完全关闭并重新打开浏览器。" />
      </NSteps>
      <NAlert type="warning" :bordered="false" class="mt-16px">
        自签名证书需要在每台访问公网管理页的 Windows 电脑上分别安装。只安装公开证书，不要导入任何 .key 文件。
      </NAlert>
    </NCard>
  </div>
</template>

<style scoped>
.downloads-page {
  max-width: 1120px;
  margin-right: auto;
  margin-left: auto;
}

.downloads-grid {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 16px;
}

@media (max-width: 760px) {
  .downloads-grid {
    grid-template-columns: 1fr;
  }
}
</style>
