import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { WebAccel, RemoteApp } from 'webaccel';

const DOMAIN = 0x0000;

/**
 * 兜底应用列表:后台拉不到/不可达(或首装沙箱无缓存)时先用它,列表不至于空白。
 * 后台可达时以 /api/config 为准覆盖。这是「接入方/demo 自己的数据」,不进 SDK。
 */
const FALLBACK_APPS: RemoteApp[] = [
  { id: 'beacukai', name: '印尼海关 e-CD', url: 'https://ecd.beacukai.go.id/', swrDoc: true, prerender: true, bundle: true },
  { id: 'rwsentosa', name: '圣淘沙名胜世界 RWS', url: 'https://www.rwsentosa.com/', swrDoc: true, prerender: false }
];

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }

    // —— 一行接入网页加速 SDK ——
    // 后台地址由 SDK 自带(webaccel/build-profile.json5 按 debug/release 注入),接入方无需再写。
    // apps 为兜底:后台可达时以 /api/config 覆盖;不可达时也有列表可显示。
    WebAccel.init(this.context, { apps: FALLBACK_APPS });

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