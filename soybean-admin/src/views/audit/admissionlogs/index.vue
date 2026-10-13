<script setup lang="tsx">
import { onMounted, ref } from 'vue';
import { NButton, NCode, NDatePicker, NInput, NSelect, NSpace, NTag } from 'naive-ui';
import { $t } from '@/locales';
import { useAppStore } from '@/store/modules/app';
import { fetchAdmissionAuditLogList } from '@/service/api/audit';

defineOptions({
  name: 'AuditAdmissionLogs'
});

const appStore = useAppStore();
const loading = ref(false);
const data = ref<Api.Audit.AdmissionAuditLog[]>([]);
const total = ref(0);
const currentPage = ref(1);
const pageSize = ref(10);
const searchRustdeskId = ref('');
const searchAction = ref<string | null>(null);
const searchResult = ref<string | null>(null);
const searchCode = ref('');
const searchCreatedAt = ref<[string, string] | null>(null);

const actionOptions = [
  { label: 'auth', value: 'rustdesk_internal_auth' },
  { label: 'register', value: 'rustdesk_internal_device_register' },
  { label: 'heartbeat', value: 'rustdesk_internal_device_heartbeat' },
  { label: 'relay', value: 'rustdesk_internal_relay_check' },
  { label: 'connection', value: 'rustdesk_internal_connection_check' },
  { label: 'relay grant issue', value: 'rustdesk_internal_relay_grant_issue' },
  { label: 'relay grant consume', value: 'rustdesk_internal_relay_grant_consume' },
  { label: 'secret', value: 'rustdesk_internal_secret_check' }
];

const resultOptions = [
  { label: 'allow', value: 'allow' },
  { label: 'deny', value: 'deny' },
  { label: 'error', value: 'error' }
];

const resultTagMap: Record<string, any> = {
  allow: 'success',
  deny: 'warning',
  error: 'error'
};

const columns = [
  { key: 'id', title: 'ID', align: 'center' as const, width: 80 },
  { key: 'action', title: $t('dataMap.admissionAudit.action'), align: 'center' as const, minWidth: 180 },
  { key: 'rustdesk_id', title: $t('dataMap.audit.rustdesk_id'), align: 'center' as const, minWidth: 130 },
  {
    key: 'result',
    title: $t('dataMap.admissionAudit.result'),
    align: 'center' as const,
    width: 100,
    render: (row: Api.Audit.AdmissionAuditLog) => (
      <NTag bordered={false} type={resultTagMap[row.result] || 'default'} size="small">
        {row.result}
      </NTag>
    )
  },
  { key: 'code', title: $t('dataMap.admissionAudit.code'), align: 'center' as const, width: 120 },
  { key: 'ip', title: $t('dataMap.audit.ip'), align: 'center' as const, minWidth: 140 },
  {
    key: 'user_agent',
    title: $t('dataMap.loginLog.userAgent'),
    align: 'center' as const,
    minWidth: 180,
    ellipsis: { tooltip: true }
  },
  { key: 'created_at', title: $t('dataMap.audit.created_at'), align: 'center' as const, minWidth: 170 }
];

function parseJSONText(value: string) {
  if (!value) return {};
  try {
    return JSON.parse(value);
  } catch {
    return value;
  }
}

function renderExpanded(row: Api.Audit.AdmissionAuditLog) {
  return (
    <NSpace vertical>
      <NCode code={JSON.stringify(parseJSONText(row.request), null, 2)} language="json" wordWrap />
      <NCode code={JSON.stringify(parseJSONText(row.response), null, 2)} language="json" wordWrap />
    </NSpace>
  );
}

async function loadData() {
  loading.value = true;
  try {
    const params: Record<string, any> = { current: currentPage.value, size: pageSize.value };
    if (searchRustdeskId.value) params.rustdesk_id = searchRustdeskId.value;
    if (searchAction.value) params.action = searchAction.value;
    if (searchResult.value) params.result = searchResult.value;
    if (searchCode.value) params.code = searchCode.value;
    if (searchCreatedAt.value?.length === 2) params.created_at = searchCreatedAt.value;
    const { data: res, error } = await fetchAdmissionAuditLogList(params);
    if (!error && res) {
      data.value = res.records || [];
      total.value = res.total || 0;
    }
  } finally {
    loading.value = false;
  }
}

function handleSearch() {
  currentPage.value = 1;
  loadData();
}

function handleReset() {
  searchRustdeskId.value = '';
  searchAction.value = null;
  searchResult.value = null;
  searchCode.value = '';
  searchCreatedAt.value = null;
  handleSearch();
}

function handlePageChange(page: number) {
  currentPage.value = page;
  loadData();
}

function handlePageSizeChange(size: number) {
  pageSize.value = size;
  currentPage.value = 1;
  loadData();
}

onMounted(() => {
  loadData();
});
</script>

<template>
  <div class="min-h-500px flex-col-stretch gap-16px overflow-hidden lt-sm:overflow-auto">
    <NCard :bordered="false" size="small">
      <NSpace align="center">
        <NInput
          v-model:value="searchRustdeskId"
          :placeholder="$t('dataMap.audit.rustdesk_id')"
          clearable
          style="width: 180px"
          @keyup.enter="handleSearch"
        />
        <NSelect
          v-model:value="searchAction"
          :options="actionOptions"
          :placeholder="$t('dataMap.admissionAudit.action')"
          clearable
          style="width: 220px"
        />
        <NSelect
          v-model:value="searchResult"
          :options="resultOptions"
          :placeholder="$t('dataMap.admissionAudit.result')"
          clearable
          style="width: 140px"
        />
        <NInput
          v-model:value="searchCode"
          :placeholder="$t('dataMap.admissionAudit.code')"
          clearable
          style="width: 140px"
          @keyup.enter="handleSearch"
        />
        <NDatePicker
          v-model:formatted-value="searchCreatedAt"
          type="datetimerange"
          value-format="yyyy-MM-dd HH:mm:ss"
          clearable
        />
        <NButton type="primary" @click="handleSearch">{{ $t('common.search') }}</NButton>
        <NButton @click="handleReset">{{ $t('common.reset') }}</NButton>
      </NSpace>
    </NCard>

    <NCard :title="$t('route.audit_admissionlogs')" :bordered="false" size="small" class="sm:flex-1-hidden card-wrapper">
      <NDataTable
        :columns="columns"
        :data="data"
        size="small"
        :flex-height="!appStore.isMobile"
        :scroll-x="1220"
        :loading="loading"
        remote
        :row-key="row => row.id"
        :render-expand="renderExpanded"
        :pagination="{
          page: currentPage,
          pageSize: pageSize,
          itemCount: total,
          showSizePicker: true,
          pageSizes: [10, 20, 50],
          onChange: handlePageChange,
          onUpdatePageSize: handlePageSizeChange
        }"
        class="sm:h-full"
      />
    </NCard>
  </div>
</template>

<style scoped></style>
