<script setup>
import { ref, computed, onMounted } from 'vue';
import { useRouter } from 'vue-router';
import { storeToRefs } from 'pinia';
import { Grid, CircleClose, Box, Coin, Refresh, Link } from '@element-plus/icons-vue';
import api from '../api';
import { useConfigStore } from '../stores/config';

const router = useRouter();
const store = useConfigStore();
const { apps, blockHosts, settings, version, loading } = storeToRefs(store);

const bundles = ref([]);
const resourceTotal = computed(() => bundles.value.reduce((s, b) => s + (b.count || 0), 0));

const stats = computed(() => [
  { label: '网页应用', value: apps.value.length, icon: Grid, color: '#4f5bd5', to: '/apps' },
  { label: '过滤规则', value: blockHosts.value.length, icon: CircleClose, color: '#ef4444', to: '/blocklist' },
  { label: '离线包', value: bundles.value.length, icon: Box, color: '#10b981', to: '/bundles' },
  { label: '离线资源数', value: resourceTotal.value, icon: Coin, color: '#f59e0b', to: '/bundles' }
]);

const apiBase = location.origin;

async function loadBundles() {
  try { bundles.value = (await api.get('/api/admin/bundles')).data; } catch { /* ignore */ }
}
async function refresh() { await Promise.all([store.load(), loadBundles()]); }

onMounted(() => { if (!apps.value.length) store.load(); loadBundles(); });
</script>

<template>
  <div>
    <!-- 统计卡 -->
    <div class="stat-row">
      <div v-for="s in stats" :key="s.label" class="stat-card" @click="router.push(s.to)">
        <div class="stat-icon" :style="{ background: s.color + '1a', color: s.color }">
          <el-icon :size="22"><component :is="s.icon" /></el-icon>
        </div>
        <div>
          <div class="stat-value">{{ s.value }}</div>
          <div class="stat-label">{{ s.label }}</div>
        </div>
      </div>
    </div>

    <el-row :gutter="16" style="margin-top:16px">
      <!-- 应用速览 -->
      <el-col :span="15">
        <el-card>
          <template #header>
            <div class="card-head">
              <span>应用速览</span>
              <el-button text type="primary" @click="router.push('/apps')">管理 →</el-button>
            </div>
          </template>
          <el-table :data="apps" v-loading="loading" size="small">
            <el-table-column prop="name" label="名称" min-width="120" />
            <el-table-column prop="url" label="URL" show-overflow-tooltip min-width="160" />
            <el-table-column label="加速项" width="200">
              <template #default="{ row }">
                <el-tag v-if="row.bundle" size="small" type="success" effect="light">内置包</el-tag>
                <el-tag v-if="row.prerender" size="small" effect="light">预渲染</el-tag>
                <el-tag v-if="row.swrDoc" size="small" effect="light">SWR</el-tag>
                <el-tag v-if="row.codeCache" size="small" effect="light">字节码</el-tag>
              </template>
            </el-table-column>
            <template #empty>暂无应用,去「应用管理」添加</template>
          </el-table>
        </el-card>
      </el-col>

      <!-- 系统信息 -->
      <el-col :span="9">
        <el-card>
          <template #header>
            <div class="card-head">
              <span>系统信息</span>
              <el-button text :icon="Refresh" :loading="loading" @click="refresh">刷新</el-button>
            </div>
          </template>
          <div class="info-list">
            <div class="info-row">
              <span class="k">配置版本</span>
              <span class="v">{{ version ? version.slice(0, 19).replace('T', ' ') : '-' }}</span>
            </div>
            <div class="info-row">
              <span class="k">缓存上限</span>
              <span class="v">{{ settings.diskCapMB ?? '-' }} MB</span>
            </div>
            <div class="info-row">
              <span class="k">文档校验节流</span>
              <span class="v">{{ settings.docCheckSec ?? '-' }} 秒</span>
            </div>
            <div class="info-row">
              <span class="k">字节码缓存</span>
              <el-tag size="small" :type="settings.bytecodeCache ? 'success' : 'info'" effect="light">
                {{ settings.bytecodeCache ? '开启' : '关闭' }}
              </el-tag>
            </div>
          </div>
          <el-divider />
          <div class="endpoints">
            <div class="ep-title"><el-icon><Link /></el-icon> App 拉取接口</div>
            <a class="ep" :href="apiBase + '/api/config'" target="_blank">{{ apiBase }}/api/config</a>
          </div>
        </el-card>
      </el-col>
    </el-row>
  </div>
</template>

<style scoped>
.stat-row { display: grid; grid-template-columns: repeat(4, 1fr); gap: 16px; }
.stat-card {
  background: #fff; border-radius: var(--card-radius);
  box-shadow: 0 2px 12px rgba(31, 36, 51, .06);
  padding: 20px; display: flex; align-items: center; gap: 16px;
  cursor: pointer; transition: transform .15s ease, box-shadow .15s ease;
}
.stat-card:hover { transform: translateY(-2px); box-shadow: 0 6px 20px rgba(31, 36, 51, .1); }
.stat-icon {
  width: 50px; height: 50px; border-radius: 12px;
  display: flex; align-items: center; justify-content: center; flex-shrink: 0;
}
.stat-value { font-size: 26px; font-weight: 700; color: #1f2433; line-height: 1.1; }
.stat-label { font-size: 13px; color: #8a90a2; margin-top: 4px; }

.card-head { display: flex; align-items: center; justify-content: space-between; font-weight: 600; }

.info-list { display: flex; flex-direction: column; gap: 14px; }
.info-row { display: flex; align-items: center; justify-content: space-between; }
.info-row .k { color: #8a90a2; font-size: 13px; }
.info-row .v { font-weight: 600; color: #41475a; font-size: 14px; }

.endpoints .ep-title { font-size: 13px; color: #8a90a2; display: flex; align-items: center; gap: 6px; margin-bottom: 8px; }
.endpoints .ep { font-size: 13px; color: var(--brand-1); word-break: break-all; text-decoration: none; }
.endpoints .ep:hover { text-decoration: underline; }
</style>
