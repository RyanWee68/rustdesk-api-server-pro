import { addIcon } from '@iconify/vue/offline';
import icons from 'virtual:offline-icons';

/** 注册构建时提取的本地图标。 */
export function setupIconifyOffline() {
  Object.entries(icons).forEach(([name, icon]) => addIcon(name, icon));
}
