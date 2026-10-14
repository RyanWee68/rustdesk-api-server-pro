<script setup lang="tsx">
import { computed, ref } from 'vue';
import { NButton, NPopconfirm, NSpace, NSwitch, NTag } from 'naive-ui';
import { approveDevice, disableDevice, enableDevice, fetchDevicesList, rejectDevice, updateDeviceRelay } from '@/service/api/devices';
import { $t } from '@/locales';
import { useAppStore } from '@/store/modules/app';
import { useAuthStore } from '@/store/modules/auth';
import { useTable } from '@/hooks/common/table';
import TableHeader from './components/table-header.vue';
import AuditBaseLogsSearch from './components/search.vue';

const appStore = useAppStore();
const authStore = useAuthStore();
const isAdmin = computed(() => authStore.userInfo.roles.includes('R_SUPER'));
const actionLoading = ref<Record<number, string>>({});

const approvalTagMap: Record<string, 'default' | 'success' | 'warning' | 'error'> = {
  pending: 'warning',
  approved: 'success',
  rejected: 'error',
  disabled: 'default'
};

const approvalTextMap: Record<string, string> = {
  pending: '待审批',
  approved: '已通过',
  rejected: '已拒绝',
  disabled: '已禁用'
};

function deviceActionPayload(row: Api.Devices.Device) {
  return { id: row.id, rustdesk_id: row.rustdesk_id };
}

async function runDeviceAction(row: Api.Devices.Device, action: string, requestFn: () => Promise<{ error: unknown }>) {
  if (actionLoading.value[row.id]) return;
  actionLoading.value[row.id] = action;
  try {
    const { error } = await requestFn();
    if (!error) {
      window.$message?.success('操作成功');
      await getData();
    }
  } finally {
    delete actionLoading.value[row.id];
  }
}

async function handleRelayChange(row: Api.Devices.Device, allowRelay: boolean) {
  await runDeviceAction(row, 'relay', () =>
    updateDeviceRelay({ ...deviceActionPayload(row), allow_relay: allowRelay })
  );
}

function approvalStatus(row: Api.Devices.Device) {
  return row.disabled ? 'disabled' : row.approval_status || 'pending';
}

const {
  columns,
  columnChecks,
  data,
  getData,
  getDataByPage,
  loading,
  mobilePagination,
  searchParams,
  resetSearchParams
} = useTable({
  apiFn: fetchDevicesList,
  showTotal: true,
  apiParams: {
    current: 1,
    size: 10,
    // if you want to use the searchParams in Form, you need to define the following properties, and the value is null
    // the value can not be undefined, otherwise the property in Form will not be reactive
    hostname: null,
    username: null,
    rustdesk_id: null
  },
  columns: () => [
    {
      key: 'id',
      title: 'ID',
      align: 'center'
    },
    {
      key: 'rustdesk_id',
      title: $t('dataMap.device.rustdesk_id'),
      align: 'center'
    },
    {
      key: 'hostname',
      title: $t('dataMap.device.hostname'),
      align: 'center'
    },
    {
      key: 'username',
      title: '系统登录名',
      align: 'center'
    },
    {
      key: 'rustdesk_username',
      title: 'RustDesk 客户端登录用户名',
      align: 'center',
      minWidth: 240,
      render: (row: Api.Devices.Device) => {
        const username = row.rustdesk_username;
        const nickname = row.rustdesk_nickname?.trim();
        return username ? (nickname ? `${username}（${nickname}）` : username) : '-';
      }
    },
    {
      key: 'version',
      title: $t('dataMap.device.version'),
      align: 'center'
    },
    {
      key: 'approval_status',
      title: '准入状态',
      align: 'center',
      render: (row: Api.Devices.Device) => {
        const status = approvalStatus(row);
        return (
          <NTag type={approvalTagMap[status] || 'default'} size="small">
            {approvalTextMap[status] || status}
          </NTag>
        );
      }
    },
    {
      key: 'is_online',
      title: '在线',
      align: 'center',
      render: (row: Api.Devices.Device) => (
        <NTag type={row.is_online ? 'success' : 'default'} size="small">
          {row.is_online ? '在线' : '离线'}
        </NTag>
      )
    },
    {
      key: 'allow_relay',
      title: '中继',
      align: 'center',
      render: (row: Api.Devices.Device) => (
        <NSwitch
          value={Boolean(row.allow_relay)}
          size="small"
          disabled={!isAdmin.value || actionLoading.value[row.id] === 'relay'}
          loading={actionLoading.value[row.id] === 'relay'}
          onUpdateValue={value => handleRelayChange(row, value)}
        />
      )
    },
    {
      key: 'os',
      title: $t('dataMap.device.os'),
      align: 'center'
    },
    {
      key: 'memory',
      title: $t('dataMap.device.memory'),
      align: 'center'
    },
    {
      key: 'last_seen_at',
      title: '最近心跳',
      align: 'center',
      render: (row: Api.Devices.Device) => row.last_seen_at || '-'
    },
    {
      key: 'last_source_ip',
      title: '来源 IP',
      align: 'center',
      render: (row: Api.Devices.Device) => row.last_source_ip || '-'
    },
    {
      key: 'created_at',
      title: $t('dataMap.audit.created_at'),
      align: 'center'
    },
    {
      key: 'operate',
      title: $t('common.action'),
      align: 'center',
      render: (row: Api.Devices.Device) =>
        isAdmin.value ? (
          <NSpace size="small" justify="center">
            {approvalStatus(row) !== 'approved' && (
              <NPopconfirm onPositiveClick={() => runDeviceAction(row, 'approve', () => approveDevice(deviceActionPayload(row)))}>
                {{
                  default: () => '确认通过该设备？',
                  trigger: () => (
                    <NButton size="small" quaternary type="primary" loading={actionLoading.value[row.id] === 'approve'}>
                      通过
                    </NButton>
                  )
                }}
              </NPopconfirm>
            )}
            {approvalStatus(row) !== 'rejected' && (
              <NPopconfirm onPositiveClick={() => runDeviceAction(row, 'reject', () => rejectDevice(deviceActionPayload(row)))}>
                {{
                  default: () => '确认拒绝该设备？',
                  trigger: () => (
                    <NButton size="small" quaternary type="warning" loading={actionLoading.value[row.id] === 'reject'}>
                      拒绝
                    </NButton>
                  )
                }}
              </NPopconfirm>
            )}
            {approvalStatus(row) === 'disabled' ? (
              <NPopconfirm onPositiveClick={() => runDeviceAction(row, 'enable', () => enableDevice(deviceActionPayload(row)))}>
                {{
                  default: () => '确认启用该设备？',
                  trigger: () => (
                    <NButton size="small" quaternary type="success" loading={actionLoading.value[row.id] === 'enable'}>
                      启用
                    </NButton>
                  )
                }}
              </NPopconfirm>
            ) : (
              <NPopconfirm onPositiveClick={() => runDeviceAction(row, 'disable', () => disableDevice(deviceActionPayload(row)))}>
                {{
                  default: () => '确认禁用该设备？',
                  trigger: () => (
                    <NButton size="small" quaternary type="error" loading={actionLoading.value[row.id] === 'disable'}>
                      禁用
                    </NButton>
                  )
                }}
              </NPopconfirm>
            )}
          </NSpace>
        ) : (
          '-'
        )
    }
  ]
});
</script>

<template>
  <div class="min-h-500px flex-col-stretch gap-16px overflow-hidden lt-sm:overflow-auto">
    <AuditBaseLogsSearch v-model:model="searchParams" @reset="resetSearchParams" @search="getDataByPage" />

    <NCard :title="$t('route.devices')" :bordered="false" size="small" class="sm:flex-1-hidden card-wrapper">
      <template #header-extra>
        <TableHeader v-model:columns="columnChecks" :loading="loading" @refresh="getData" />
      </template>
      <NDataTable
        :columns="columns"
        :data="data"
        size="small"
        :flex-height="!appStore.isMobile"
        :scroll-x="1680"
        :loading="loading"
        remote
        :row-key="row => row.id"
        :pagination="mobilePagination"
        class="sm:h-full"
      />
    </NCard>
  </div>
</template>

<style scoped></style>
