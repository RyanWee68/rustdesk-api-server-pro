<script setup lang="ts">
import { useClipboard } from '@vueuse/core';
import { certificateDownload, certificateInstallCommand } from '@/constants/downloads';

const certificateFingerprint = certificateDownload.sha256.match(/.{2}/g)?.join(':');
const { copy, copied } = useClipboard({ legacy: true });

/** 复制命令，兼容局域网 HTTP 页面的剪贴板限制。 */
async function copyInstallCommand() {
  try {
    await copy(certificateInstallCommand);
  } catch {
    window.$message?.error('ERR-1019: 复制失败，请手动选择并复制命令');
  }
}
</script>

<template>
  <div class="certificate-page">
    <h2 class="mb-16px text-20px font-medium">证书管理</h2>
    <NAlert type="info" :bordered="false">
      公网管理地址为 https://rustdesk.jtzxsoft.com:22346；局域网可使用 http://192.168.0.211:22347。
    </NAlert>

    <section class="certificate-section">
      <h3 class="mb-12px text-16px font-medium">管理页证书</h3>
      <NDescriptions :column="1" label-placement="left" bordered size="small">
        <NDescriptionsItem label="域名">rustdesk.jtzxsoft.com</NDescriptionsItem>
        <NDescriptionsItem label="有效期">2026-10-16 至 2036-10-13</NDescriptionsItem>
        <NDescriptionsItem label="SHA-256 指纹">
          <NText code class="break-all">{{ certificateFingerprint }}</NText>
        </NDescriptionsItem>
      </NDescriptions>
      <NButton tag="a" :href="certificateDownload.url" download type="primary" class="mt-16px">
        <template #icon><SvgIcon icon="mdi:certificate-outline" /></template>
        下载证书
      </NButton>
    </section>

    <section class="certificate-section">
      <div class="mb-12px flex items-center justify-between gap-12px">
        <h3 class="text-16px font-medium">PowerShell 安装证书</h3>
        <NButton size="small" @click="copyInstallCommand">
          <template #icon><SvgIcon icon="mdi:content-copy" /></template>
          {{ copied ? '已复制' : '复制命令' }}
        </NButton>
      </div>
      <p class="mb-12px">
        先将证书保存到当前用户的“下载”文件夹，再在需要访问管理页的 Windows 电脑上打开 PowerShell 执行以下命令。
        命令会核对 SHA-256 指纹，并导入当前用户的“受信任的根证书颁发机构”，无需管理员权限。
      </p>
      <pre class="certificate-command"><code>{{ certificateInstallCommand }}</code></pre>
      <NAlert type="warning" :bordered="false" class="mt-16px">
        导入后完全关闭并重新打开浏览器。信任仅对执行命令的 Windows 用户生效，每台电脑需分别安装。
        仅在核对指纹后信任此公开证书，不要导入任何 .key 文件；使用独立证书库的浏览器可能还需单独设置。
      </NAlert>
    </section>
  </div>
</template>

<style scoped>
.certificate-page {
  width: 100%;
  max-width: 1120px;
  margin: 0 auto;
}

.certificate-section {
  padding: 24px 0;
  border-bottom: 1px solid rgb(128 128 128 / 18%);
}

.certificate-command {
  margin: 0;
  padding: 16px;
  overflow-x: auto;
  border: 1px solid rgb(128 128 128 / 24%);
  border-radius: 4px;
  background: rgb(var(--container-bg-color));
  font-size: 13px;
  line-height: 1.7;
}
</style>
