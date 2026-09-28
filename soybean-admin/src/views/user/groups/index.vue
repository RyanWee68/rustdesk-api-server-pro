<script setup lang="tsx">
import { computed, onMounted, ref } from 'vue';
import { NButton, NCard, NDataTable, NForm, NFormItem, NInput, NModal, NPopconfirm, NSpace, NTransfer, type DataTableColumns } from 'naive-ui';
import {
  deleteUserGroup,
  fetchUserGroupList,
  fetchUserGroupMembers,
  fetchUserList,
  saveUserGroup,
  saveUserGroupMembers
} from '@/service/api/user_management';
import { useAppStore } from '@/store/modules/app';

const appStore = useAppStore();
const loading = ref(false);
const saving = ref(false);
const memberLoading = ref(false);
const groups = ref<Api.UserManagement.UserGroup[]>([]);
const total = ref(0);
const page = ref(1);
const pageSize = ref(10);
const keyword = ref('');

const editVisible = ref(false);
const memberVisible = ref(false);
const editingGroup = ref<Api.UserManagement.UserGroup | null>(null);
const groupName = ref('');
const allUsers = ref<Api.UserManagement.User[]>([]);
const selectedUserIds = ref<string[]>([]);

const userOptions = computed(() =>
  allUsers.value.map(user => ({
    label: `${user.username}${user.name ? ` / ${user.name}` : ''}`,
    value: String(user.id),
    disabled: user.id === undefined
  }))
);

const pagination = computed(() => ({
  page: page.value,
  pageSize: pageSize.value,
  itemCount: total.value,
  showSizePicker: true,
  pageSizes: [10, 20, 50],
  onUpdatePage: (value: number) => {
    page.value = value;
    loadGroups();
  },
  onUpdatePageSize: (value: number) => {
    pageSize.value = value;
    page.value = 1;
    loadGroups();
  }
}));

const columns: DataTableColumns<Api.UserManagement.UserGroup> = [
  { key: 'name', title: '用户组', align: 'center' },
  { key: 'guid', title: 'GUID', align: 'center', ellipsis: { tooltip: true } },
  { key: 'member_count', title: '成员数', align: 'center' },
  { key: 'created_at', title: '创建时间', align: 'center' },
  {
    key: 'operate',
    title: '操作',
    align: 'center',
    render: row => (
      <NSpace justify="center">
        <NButton size="small" type="primary" onClick={() => openMembers(row)}>
          成员
        </NButton>
        <NButton size="small" type="success" onClick={() => openEdit(row)}>
          编辑
        </NButton>
        <NPopconfirm onPositiveClick={() => handleDelete(row)}>
          {{
            default: () => '确认删除该用户组吗？',
            trigger: () => (
              <NButton size="small" type="error">
                删除
              </NButton>
            )
          }}
        </NPopconfirm>
      </NSpace>
    )
  }
];

async function loadGroups() {
  loading.value = true;
  const { data, error } = await fetchUserGroupList({ current: page.value, size: pageSize.value, name: keyword.value || null });
  loading.value = false;
  if (error || !data) return;
  groups.value = data.records || [];
  total.value = data.total || 0;
}

async function loadUsers() {
  const { data, error } = await fetchUserList({ current: 1, size: 1000 });
  if (!error && data) {
    allUsers.value = data.records || [];
  }
}

function openAdd() {
  editingGroup.value = null;
  groupName.value = '';
  editVisible.value = true;
}

function openEdit(row: Api.UserManagement.UserGroup) {
  editingGroup.value = row;
  groupName.value = row.name;
  editVisible.value = true;
}

async function handleSaveGroup() {
  const name = groupName.value.trim();
  if (!name) {
    window.$message?.warning('请输入用户组名称');
    return;
  }
  saving.value = true;
  const { error } = await saveUserGroup({ guid: editingGroup.value?.guid, name });
  saving.value = false;
  if (!error) {
    editVisible.value = false;
    window.$message?.success('用户组已保存');
    await loadGroups();
  }
}

async function handleDelete(row: Api.UserManagement.UserGroup) {
  const { error } = await deleteUserGroup(row.guid);
  if (!error) {
    window.$message?.success('用户组已删除');
    await loadGroups();
  }
}

async function openMembers(row: Api.UserManagement.UserGroup) {
  editingGroup.value = row;
  memberVisible.value = true;
  memberLoading.value = true;
  await loadUsers();
  const { data, error } = await fetchUserGroupMembers(row.guid);
  memberLoading.value = false;
  if (!error && data) {
    selectedUserIds.value = (data.records || []).map(item => String(item.id));
  }
}

async function handleSaveMembers() {
  if (!editingGroup.value) return;
  saving.value = true;
  const userIds = selectedUserIds.value.map(Number).filter(Boolean);
  const { error } = await saveUserGroupMembers({ guid: editingGroup.value.guid, userIds });
  saving.value = false;
  if (!error) {
    memberVisible.value = false;
    window.$message?.success('成员已保存');
    await loadGroups();
  }
}

function handleSearch() {
  page.value = 1;
  loadGroups();
}

onMounted(loadGroups);
</script>

<template>
  <div class="min-h-500px flex-col-stretch gap-16px overflow-hidden lt-sm:overflow-auto">
    <NCard title="用户分组" :bordered="false" size="small" class="sm:flex-1-hidden card-wrapper">
      <template #header-extra>
        <NSpace>
          <NInput v-model:value="keyword" clearable placeholder="搜索用户组" @keyup.enter="handleSearch" />
          <NButton :loading="loading" @click="handleSearch">搜索</NButton>
          <NButton @click="keyword = ''; handleSearch()">重置</NButton>
          <NButton type="primary" @click="openAdd">新增用户组</NButton>
        </NSpace>
      </template>

      <NDataTable
        :columns="columns"
        :data="groups"
        size="small"
        :flex-height="!appStore.isMobile"
        :scroll-x="880"
        :loading="loading"
        remote
        :row-key="row => row.guid"
        :pagination="pagination"
        class="sm:h-full"
      />
    </NCard>

    <NModal v-model:show="editVisible" preset="card" :title="editingGroup ? '编辑用户组' : '新增用户组'" class="max-w-520px">
      <NForm label-placement="left" label-width="90">
        <NFormItem label="名称">
          <NInput v-model:value="groupName" placeholder="例如：运维部、财务部、外包只读" />
        </NFormItem>
      </NForm>
      <template #footer>
        <NSpace justify="end">
          <NButton @click="editVisible = false">取消</NButton>
          <NButton type="primary" :loading="saving" @click="handleSaveGroup">保存</NButton>
        </NSpace>
      </template>
    </NModal>

    <NModal v-model:show="memberVisible" preset="card" :title="`维护成员：${editingGroup?.name || ''}`" class="max-w-860px">
      <NTransfer
        v-model:value="selectedUserIds"
        :options="userOptions"
        source-title="可选用户"
        target-title="组内成员"
        filterable
        :loading="memberLoading"
      />
      <template #footer>
        <NSpace justify="end">
          <NButton @click="memberVisible = false">取消</NButton>
          <NButton type="primary" :loading="saving" @click="handleSaveMembers">保存成员</NButton>
        </NSpace>
      </template>
    </NModal>
  </div>
</template>
