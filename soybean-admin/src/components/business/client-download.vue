<script setup lang="ts">
import { clientDownloads } from '@/constants/downloads';

withDefaults(defineProps<{ compact?: boolean }>(), { compact: false });
</script>

<template>
  <NPopover trigger="click" placement="bottom-end">
    <template #trigger>
      <NButton
        attr-type="button"
        :text="!compact"
        :quaternary="compact"
        :circle="compact"
        title="客户端下载"
        aria-label="客户端下载"
      >
        <template #icon><SvgIcon icon="mdi:download-outline" /></template>
        <template v-if="!compact">客户端下载</template>
      </NButton>
    </template>
    <div class="flex-col gap-8px">
      <NButton
        v-for="client in clientDownloads"
        :key="client.version"
        tag="a"
        :href="client.url"
        :title="`SHA-256: ${client.sha256}`"
        download
        quaternary
      >
        <template #icon><SvgIcon icon="mdi:microsoft-windows" /></template>
        RustDesk {{ client.version }} · Windows x64
      </NButton>
    </div>
  </NPopover>
</template>
