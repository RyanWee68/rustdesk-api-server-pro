import assert from 'node:assert/strict';
import { loadProjectIcons } from '../build/plugins/offline-icons';

const icons = loadProjectIcons(process.cwd(), 'mdi:menu');
for (const name of ['heroicons:language', 'material-symbols:sunny', 'mdi:menu', 'mdi:file-document-multiple-outline']) {
  assert.ok(icons[name]?.body, `ERR-1019: 缺少离线图标 ${name}`);
}
assert.ok(Object.keys(icons).length > 40, 'ERR-1019: 菜单和操作图标未完整提取');
assert.ok(JSON.stringify(icons).length < 150_000, 'ERR-1019: 不应打包完整图标集合');
console.log(`离线图标回归通过，共 ${Object.keys(icons).length} 个图标`);
