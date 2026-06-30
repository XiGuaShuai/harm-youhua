import { AbilityConstant, ConfigurationConstant, UIAbility, Want, abilityAccessCtrl, Permissions } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { WebAccel, RemoteApp } from 'webaccel';

const DOMAIN = 0x0000;

/**
 * 兜底应用列表:后台拉不到/不可达(或首装沙箱无缓存)时先用它,列表不至于空白。
 * 后台可达时以 /api/config 为准覆盖。这是「接入方/demo 自己的数据」,不进 SDK。
 */
const FALLBACK_APPS: RemoteApp[] = [
  {
    id: 'k11', name: 'K11 香港', url: 'https://hk.k11.com/zh-cn', routes: [],
    swrDoc: false, prerender: false, bundle: true, prefetchChunks: false,
    compressedManifestUrl: '/bundles/k11/manifest.zz.json',
    staticCache: {
      enabled: true,
      minSizeKB: 0,
      minDurationMs: 3000,
      maxSizeKB: 5120,
      include: ['/files/art/js/bundle.min.js'],
      exclude: ['/files/art/js/ga.js', 'googletagmanager', 'google-analytics',
        'dlswbr.baidu.com/heicha', 'fingerprintjs2', 'abclite']
    }
  }
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

    // 调试浮窗:打开后网页右上角显示「缓存命中 + 后台是否在偷偷缓存」。上线时关掉(或不调)。
    WebAccel.setDebug(true);

    // 服务卡片点击带来的 targetUrl:存全局,WebAccelLauncher 据此直达对应网页
    this.applyLaunchTarget(want);

    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  // 元服务已在运行时,卡片再次拉起走这里
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.applyLaunchTarget(want);
  }

  // 从 want 取卡片传来的 targetUrl,写入 AppStorage('launchTarget'),供 launcher 直达
  private applyLaunchTarget(want: Want): void {
    const params = want.parameters as Record<string, Object>;
    if (!params) {
      return;
    }
    const url = params.targetUrl as string;
    if (typeof url === 'string' && url.length > 0) {
      AppStorage.setOrCreate<string>('launchTarget', url);
    }
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
    // 申请定位权限:网页(如 Booking"当前位置搜索")要用定位,元服务自身先拿到系统定位授权,
    // 否则网页里 navigator.geolocation 拿不到位置 → 搜索失败。
    this.reqLocationPermission();
  }

  // 运行时弹系统授权框,申请定位权限(模糊定位即可满足"附近搜索")
  private reqLocationPermission(): void {
    try {
      const perms: Array<Permissions> = ['ohos.permission.APPROXIMATELY_LOCATION'];
      const atManager = abilityAccessCtrl.createAtManager();
      atManager.requestPermissionsFromUser(this.context, perms)
        .then((data) => {
          hilog.info(DOMAIN, 'testTag', 'location permission result: %{public}s', JSON.stringify(data.authResults));
        })
        .catch((err: BusinessError) => {
          hilog.error(DOMAIN, 'testTag', 'request location permission failed: %{public}s', err.message);
        });
    } catch (e) {
      const er = e as BusinessError;
      hilog.error(DOMAIN, 'testTag', 'reqLocationPermission err: %{public}s', er.message);
    }
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
