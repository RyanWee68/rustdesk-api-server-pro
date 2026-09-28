<script setup lang="ts">
import { onMounted, reactive, ref } from 'vue';
import { NButton, NCard, NDynamicTags, NForm, NFormItem, NRadioButton, NRadioGroup, NSpace, NSwitch, NTag } from 'naive-ui';
import { fetchAccessPolicy, fetchSaveAccessPolicy } from '@/service/api/home';

const loading = ref(false);
const saving = ref(false);

const form = reactive<Api.Home.AccessPolicy>({
  registrationMode: 'admin_only',
  allowedEmailDomains: [],
  allowOAuthAutoCreate: false
});

const modeOptions: { label: string; value: Api.Home.AccessPolicy['registrationMode']; tip: string }[] = [
  { label: '仅管理员创建', value: 'admin_only', tip: '关闭公开注册，账号由管理员维护。' },
  { label: '公司邮箱', value: 'company_email', tip: '仅允许白名单邮箱域名成为自动建号来源。' },
  { label: '第三方登录', value: 'oauth_only', tip: '通过已配置的 OAuth/OIDC Provider 进入。' },
  { label: '邀请码预留', value: 'invite_only', tip: '为后续邀请码注册保留策略，不会开放公开注册。' }
];

function normalizeDomain(value: string) {
  return value.trim().replace(/^@/, '').toLowerCase();
}

async function loadData() {
  loading.value = true;
  const { data, error } = await fetchAccessPolicy();
  loading.value = false;
  if (error || !data) return;
  form.registrationMode = data.registrationMode || 'admin_only';
  form.allowedEmailDomains = (data.allowedEmailDomains || []).map(normalizeDomain).filter(Boolean);
  form.allowOAuthAutoCreate = Boolean(data.allowOAuthAutoCreate);
}

async function handleSave() {
  saving.value = true;
  const payload: Api.Home.AccessPolicy = {
    registrationMode: form.registrationMode,
    allowedEmailDomains: Array.from(new Set(form.allowedEmailDomains.map(normalizeDomain).filter(Boolean))),
    allowOAuthAutoCreate: form.allowOAuthAutoCreate
  };
  const { error } = await fetchSaveAccessPolicy(payload);
  saving.value = false;
  if (!error) {
    window.$message?.success('准入策略已保存');
    await loadData();
  }
}

onMounted(loadData);
</script>

<template>
  <div class="min-h-500px flex-col-stretch gap-16px overflow-hidden lt-sm:overflow-auto">
    <NCard title="公司准入策略" :bordered="false" size="small" class="card-wrapper">
      <template #header-extra>
        <NSpace>
          <NButton :loading="loading" @click="loadData">刷新</NButton>
          <NButton type="primary" :loading="saving" @click="handleSave">保存策略</NButton>
        </NSpace>
      </template>

      <NForm label-placement="left" label-width="140" class="max-w-920px">
        <NFormItem label="注册策略">
          <NRadioGroup v-model:value="form.registrationMode">
            <NSpace>
              <NRadioButton v-for="item in modeOptions" :key="item.value" :value="item.value">
                {{ item.label }}
              </NRadioButton>
            </NSpace>
          </NRadioGroup>
        </NFormItem>

        <NFormItem label="策略说明">
          <NSpace vertical>
            <NTag v-for="item in modeOptions" :key="item.value" :type="form.registrationMode === item.value ? 'success' : 'default'">
              {{ item.label }}：{{ item.tip }}
            </NTag>
          </NSpace>
        </NFormItem>

        <NFormItem label="公司邮箱域名">
          <NDynamicTags v-model:value="form.allowedEmailDomains" />
        </NFormItem>

        <NFormItem label="OAuth 自动建号">
          <NSwitch v-model:value="form.allowOAuthAutoCreate" />
        </NFormItem>
      </NForm>
    </NCard>
  </div>
</template>
