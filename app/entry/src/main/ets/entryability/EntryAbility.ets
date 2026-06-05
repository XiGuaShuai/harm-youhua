import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { BusinessError } from '@kit.BasicServicesKit';
import { webCache } from '../cache/WebCacheManager';
import { remoteConfig } from '../config/RemoteConfig';

const DOMAIN = 0x0000;

/** 需要"秒开"的目标网页 */
export const TARGET_URL: string = 'https://ecd.beacukai.go.id/';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }

    // —— 秒开优化 ① 提前初始化 Web 内核 ——
    // 把 Web 内核的初始化提前到 Ability 创建阶段,首屏创建 Web 组件时无需再等内核冷启动。
    try {
      webview.WebviewController.initializeWebEngine();
      hilog.info(DOMAIN, 'testTag', '%{public}s', 'Web engine initialized');
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(DOMAIN, 'testTag', 'initializeWebEngine failed: %{public}d %{public}s', e.code, e.message);
    }

    // —— 秒开优化 ② 初始化离线缓存(同步加载磁盘索引)——
    // 拦截 _next/static 等不可变资源,二次启动直接走本地,绕过 No-Store 的跨境慢链路。
    // 注意:每个网页的"预连接 + 主文档 SWR + 离屏预渲染"现在统一在 WebPool.prewarm() 里按 URL 处理。
    webCache.init(this.context);

    // —— 接入后台远程配置:只拉「配置」(应用列表/黑名单/设置);离线包不在这里下,改为打开网页应用时按需下载 ——
    // ① 同步:先用上次缓存(或内置兜底),不阻塞首屏
    remoteConfig.load(this.context);
    webCache.setBlockHosts(remoteConfig.getBlockHosts());
    webCache.applySettings(remoteConfig.getSettings());
    // ② 异步:拉服务器最新配置,成功后注入黑名单/设置(离线包由 WebPool.obtain 在打开某 app 时按需拉)
    remoteConfig.refresh().then((ok: boolean) => {
      if (ok) {
        webCache.setBlockHosts(remoteConfig.getBlockHosts());
        webCache.applySettings(remoteConfig.getSettings());
      }
    });

    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}