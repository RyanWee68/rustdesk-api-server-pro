import type { PluginOption } from 'vite';
import vue from '@vitejs/plugin-vue';
import vueJsx from '@vitejs/plugin-vue-jsx';
import VueDevtools from 'vite-plugin-vue-devtools';
import progress from 'vite-plugin-progress';
import { setupElegantRouter } from './router';
import { setupUnocss } from './unocss';
import { setupUnplugin } from './unplugin';
import { setupHtmlPlugin } from './html';
import { setupOfflineIcons } from './offline-icons';

export function setupVitePlugins(viteEnv: Env.ImportMeta, buildTime: string) {
  const plugins: PluginOption = [
    vue({
      script: {
        defineModel: true
      }
    }),
    vueJsx(),
    VueDevtools(),
    setupElegantRouter(),
    setupUnocss(viteEnv),
    setupOfflineIcons(viteEnv.VITE_MENU_ICON),
    ...setupUnplugin(viteEnv),
    progress(),
    setupHtmlPlugin(buildTime)
  ];

  return plugins;
}
