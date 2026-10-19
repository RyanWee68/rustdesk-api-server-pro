import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import type { Plugin } from 'vite';
import { getIconData } from '@iconify/utils';
import type { IconifyIcon, IconifyJSON } from '@iconify/vue/offline';

const require = createRequire(import.meta.url);
const moduleId = 'virtual:offline-icons';

/** 按源码中的图标名提取已安装图标，避免浏览器等待外部图标服务。 */
export function loadProjectIcons(root: string, menuIcon: string) {
  const names = new Set<string>([menuIcon]);
  function scan(directory: string) {
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      const filename = path.join(directory, entry.name);
      if (entry.isDirectory()) scan(filename);
      else if (/\.(vue|ts|tsx)$/.test(entry.name)) {
        const source = fs.readFileSync(filename, 'utf8');
        for (const match of source.matchAll(/['"`]([a-z][a-z0-9-]*:[a-z0-9]+(?:-[a-z0-9]+)*)['"`]/g)) {
          names.add(match[1]);
        }
      }
    }
  }
  scan(path.join(root, 'src'));
  const collections = new Map<string, IconifyJSON>();
  const icons: Record<string, IconifyIcon> = {};
  for (const name of [...names].sort()) {
    const [prefix, iconName] = name.split(':');
    if (!collections.has(prefix)) {
      try {
        collections.set(prefix, require(`@iconify-json/${prefix}/icons.json`) as IconifyJSON);
      } catch {
        try {
          collections.set(prefix, require(`@iconify/json/json/${prefix}.json`) as IconifyJSON);
        } catch {
          continue;
        }
      }
    }
    const icon = getIconData(collections.get(prefix)!, iconName);
    if (!icon) throw new Error(`ERR-1019: 本地图标不存在 ${name}`);
    icons[name] = icon;
  }
  return icons;
}

/** 将实际使用的图标注入构建产物，不打包完整图标库。 */
export function setupOfflineIcons(menuIcon: string): Plugin {
  return {
    name: 'offline-icons',
    resolveId(id) {
      return id === moduleId ? `\0${moduleId}` : undefined;
    },
    load(id) {
      if (id === `\0${moduleId}`) {
        return `export default ${JSON.stringify(loadProjectIcons(process.cwd(), menuIcon))}`;
      }
      return undefined;
    }
  };
}
