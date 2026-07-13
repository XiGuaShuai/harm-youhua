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
const PREMIER_INN_UA: string =
  'Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1';

const BRITISH_MUSEUM_UA: string =
  'Mozilla/5.0 (Linux; Android 14; Pixel 8 Build/UQ1A.240205.002) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/132.0.0.0 Mobile Safari/537.36';

const BURJ_KHALIFA_UA: string =
  'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Mobile Safari/537.36';

const GETYOURGUIDE_UA: string =
  'Mozilla/5.0 (Phone; OpenHarmony 6.0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/132.0.0.0 Safari/537.36  ArkWeb/6.0.0.130 Mobile';

const SURIA_KLCC_UA: string =
  'Mozilla/5.0 (Phone; OpenHarmony 5.0) AppleWebKit/537.36 (KHTML,like Gecko) Chrome/114.0.0.0 Safari/537.36 ArkWeb/4.1.6.1 Mobile HuaweiBrowser/1.2.10.310';

const TMB_UA: string =
  'Mozilla/5.0 (Phone; OpenHarmony 6.0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/132.0.0.0 Safari/537.36  ArkWeb/6.0.0.130 Mobile';

const VEXERE_UA: string =
  'Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1';

const HANCHAO_SUBWAY_UA: string =
  'Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1';

const XE_UA: string =
  'Mozilla/5.0 (Phone; OpenHarmony 6.0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/132.0.0.0 Safari/537.36  ArkWeb/6.0.0.130 Mobile';

const FALLBACK_APPS: RemoteApp[] = [
  {
    id: 'xe',
    name: 'Xe',
    localOnly: true,
    scope: 'region',
    region: 'FX',
    appId: 'xe',
    appVersion: '2026.07',
    priority: 1000,
    url: 'https://www.xe.com/zh-cn/',
    routes: ['/zh-cn/'],
    swrDoc: false,
    prerender: false,
    codeCache: false,
    bundle: true,
    manifestUrl: 'http://192.168.20.197:8787/bundles/xe/manifest.json',
    bundleVersion: '85ba1a8f0d24acda',
    compressedManifestUrl: 'http://192.168.20.197:8787/bundles/xe/manifest.zz.json',
    compressedBundleVersion: 'e5761f97b02d7f41',
    prefetchChunks: false,
    userAgent: XE_UA,
    preconnectHosts: [
      'https://www.xe.com',
      'https://356ac961549f.9e641471.eu-central-1.token.awswaf.com'
    ]
  },
  {
    id: 'premierinn',
    name: 'Premier Inn Hotels',
    scope: 'region',
    region: 'GB',
    appId: 'premierinn',
    appVersion: '2026.07',
    priority: 100,
    url: 'https://www.premierinn.com/gb/en/home.html?isFirst=1',
    routes: ['/gb/en/home.html?isFirst=1', '/gb/en/home.html'],
    swrDoc: false,
    prerender: false,
    codeCache: false,
    bundle: true,
    prefetchChunks: false,
    userAgent: PREMIER_INN_UA,
    manifestUrl: '/bundles/premierinn/manifest.json',
    bundleVersion: '30a511b9d0cc4b25',
    compressedManifestUrl: '/bundles/premierinn/manifest.zz.json',
    compressedBundleVersion: '6dbd117d03c507a1',
    extraBlockHosts: [
      'https://api.whitbread.co.uk/content/cookiepolicies',
      'https://assets.adobedtm.com',
      'https://js-cdn.dynatrace.com',
      'https://target.premierinn.com',
      'https://gateway.foresee.com',
      'https://d2oh4tlt9mrke9.cloudfront.net',
      'https://p.typekit.net'
    ],
    preconnectHosts: ['https://www.premierinn.com', 'https://use.typekit.net']
  },
  {
    id: 'britishmuseum',
    name: 'British Museum',
    scope: 'region',
    region: 'GB',
    appId: 'britishmuseum',
    appVersion: '2026.07',
    priority: 95,
    url: 'https://www.britishmuseum.org/',
    routes: ['/', '/visit', '/exhibitions-events'],
    swrDoc: false,
    prerender: false,
    codeCache: false,
    bundle: true,
    prefetchChunks: false,
    userAgent: BRITISH_MUSEUM_UA,
    manifestUrl: '/bundles/britishmuseum/manifest.json',
    bundleVersion: 'b53d91d03f3326a6',
    compressedManifestUrl: '/bundles/britishmuseum/manifest.zz.json',
    compressedBundleVersion: '59e9b9bc357850aa',
    extraBlockHosts: [
      'https://consent.cookiebot.com',
      'https://consentcdn.cookiebot.com',
      'https://www.googletagmanager.com',
      'https://googletagmanager.com',
      'https://www.google-analytics.com',
      'https://google-analytics.com',
      'https://googleads.g.doubleclick.net',
      'https://www.googleadservices.com'
    ],
    preconnectHosts: ['https://www.britishmuseum.org', 'https://challenges.cloudflare.com']
  },
  {
    id: 'burjkhalifa',
    name: '\u54c8\u5229\u6cd5\u5854',
    scope: 'region',
    region: 'AE',
    appId: 'burjkhalifa',
    appVersion: '2026.07',
    priority: 100,
    url: 'https://www.burjkhalifa.ae/zh-hans/',
    routes: ['/zh-hans/'],
    swrDoc: false,
    prerender: false,
    codeCache: false,
    bundle: true,
    prefetchChunks: false,
    userAgent: BURJ_KHALIFA_UA,
    manifestUrl: '/bundles/burjkhalifa/manifest.json',
    bundleVersion: '5c25c79a05ec20de',
    compressedManifestUrl: '/bundles/burjkhalifa/manifest.zz.json',
    compressedBundleVersion: 'cc811315a8bee359',
    extraBlockHosts: [
      'https://www.googletagmanager.com',
      'https://googletagmanager.com',
      'https://www.google-analytics.com',
      'https://google-analytics.com',
      'https://connect.facebook.net',
      'https://www.facebook.com/tr',
      'https://snap.licdn.com',
      'https://sc-static.net',
      'https://analytics.tiktok.com',
      'https://dev.visualwebsiteoptimizer.com'
    ],
    preconnectHosts: ['https://www.burjkhalifa.ae', 'https://ticket.atthetop.ae']
  },
  {
    id: 'getyourguide_burj',
    name: 'GetYourGuide',
    scope: 'region',
    region: 'AE',
    appId: 'getyourguide_burj',
    appVersion: '2026.07',
    priority: 90,
    url: 'https://www.getyourguide.com/zh-cn/?visitor-id=CX728L4F9H1IKHG7O6YFWTSGRD5JCVL7&locale_autoredirect_optout=true',
    routes: ['/zh-cn/'],
    swrDoc: false,
    prerender: false,
    codeCache: false,
    bundle: true,
    prefetchChunks: false,
    userAgent: GETYOURGUIDE_UA,
    manifestUrl: '/bundles/getyourguide_burj/manifest.json',
    bundleVersion: '0d145826c536042a',
    compressedManifestUrl: '/bundles/getyourguide_burj/manifest.zz.json',
    compressedBundleVersion: '4d5f061c8a872398',
    extraBlockHosts: [
      'https://www.googletagmanager.com',
      'https://googletagmanager.com',
      'https://www.google-analytics.com',
      'https://google-analytics.com',
      'https://connect.facebook.net',
      'https://www.facebook.com/tr',
      'https://bat.bing.com',
      'https://analytics.tiktok.com',
      'https://static.ads-twitter.com'
    ],
    preconnectHosts: [
      'https://www.getyourguide.com',
      'https://cdn.getyourguide.com',
      'https://challenges.cloudflare.com'
    ]
  },
  {
    id: 'suriaklcc',
    name: 'Suria KLCC',
    scope: 'region',
    region: 'MY',
    appId: 'suriaklcc',
    appVersion: '2026.07',
    priority: 100,
    url: 'https://www.suriaklcc.com.my?isFirst=1',
    routes: ['/', '/?isFirst=1'],
    swrDoc: false,
    prerender: false,
    codeCache: false,
    bundle: true,
    prefetchChunks: false,
    userAgent: SURIA_KLCC_UA,
    manifestUrl: '/bundles/suriaklcc/manifest.json',
    bundleVersion: '6be394908243d204',
    compressedManifestUrl: '/bundles/suriaklcc/manifest.zz.json',
    compressedBundleVersion: '2f8684f35d977bec',
    bundleExcludeUrls: [
      '*.png',
      '*.jpg',
      '*.jpeg',
      '*.webp',
      '*.gif',
      '*.svg',
      '*.ico',
      '*.mp4',
      '*.webm',
      '*.m3u8',
      '*.ts'
    ],
    extraBlockHosts: [
      'https://www.googletagmanager.com',
      'https://googletagmanager.com',
      'https://www.google-analytics.com',
      'https://google-analytics.com',
      'https://connect.facebook.net',
      'https://www.facebook.com/tr',
      'https://googleads.g.doubleclick.net',
      'https://www.googleadservices.com'
    ],
    preconnectHosts: [
      'https://www.suriaklcc.com.my',
      'https://addtocalendar.com'
    ]
  },
  {
    id: 'tmb',
    name: 'TMB',
    scope: 'region',
    region: 'ES',
    appId: 'tmb',
    appVersion: '2026.07',
    priority: 100,
    url: 'https://www.tmb.cat/en/home',
    routes: ['/en/home'],
    swrDoc: false,
    prerender: false,
    codeCache: false,
    bundle: true,
    prefetchChunks: false,
    userAgent: TMB_UA,
    manifestUrl: '/bundles/tmb/manifest.json',
    bundleVersion: '13d7f3e1c686f53c',
    compressedManifestUrl: '/bundles/tmb/manifest.zz.json',
    compressedBundleVersion: '96ca10e087206e3f',
    bundleExcludeUrls: [
      '*.png',
      '*.jpg',
      '*.jpeg',
      '*.webp',
      '*.gif',
      '*.svg',
      '*.ico',
      '*.mp4',
      '*.webm',
      '*.m3u8',
      '*.ts'
    ],
    extraBlockHosts: [
      'https://www.googletagmanager.com',
      'https://googletagmanager.com',
      'https://www.google-analytics.com',
      'https://google-analytics.com',
      'https://consent.cookiebot.com'
    ],
    preconnectHosts: [
      'https://www.tmb.cat',
      'https://static-web.tmb.cat',
      'https://w4.tmb.cat'
    ]
  },
  {
    id: 'vexere',
    name: 'Vexere',
    scope: 'region',
    region: 'VN',
    appId: 'vexere',
    appVersion: '2026.07',
    priority: 100,
    url: 'https://vexere.com/en-US',
    routes: ['/en-US'],
    swrDoc: false,
    prerender: false,
    codeCache: false,
    bundle: true,
    prefetchChunks: false,
    userAgent: VEXERE_UA,
    manifestUrl: '/bundles/vexere/manifest.json',
    bundleVersion: 'a5771cba481195e2',
    compressedManifestUrl: '/bundles/vexere/manifest.zz.json',
    compressedBundleVersion: '425fa6938f05d271',
    bundleExcludeUrls: [
      '*.png',
      '*.jpg',
      '*.jpeg',
      '*.webp',
      '*.gif',
      '*.svg',
      '*.ico',
      '*.avif',
      '*.mp4',
      '*.webm',
      '*.m3u8',
      '*.ts',
      '*.mov',
      '*.woff',
      '*.woff2',
      '*.ttf',
      '*.otf',
      'https://fonts.googleapis.com/*',
      'https://fonts.gstatic.com/*'
    ],
    extraBlockHosts: [
      'https://www.googletagmanager.com',
      'https://googletagmanager.com',
      'https://www.google-analytics.com',
      'https://google-analytics.com',
      'https://connect.facebook.net',
      'https://www.facebook.com/tr',
      'https://analytics.tiktok.com',
      'https://cdn.segment.com',
      'https://cdnt.netcoresmartech.com',
      'https://229a2c9fe669f7b.cmccloud.com.vn'
    ],
    preconnectHosts: [
      'https://vexere.com',
      'https://storage.googleapis.com',
      'https://cdnjs.cloudflare.com',
      'https://fonts.googleapis.com',
      'https://fonts.gstatic.com'
    ]
  },
  {
    id: 'hanchao_subway',
    name: '\u97e9\u5de2\u97e9\u56fd\u5730\u94c1',
    scope: 'region',
    region: 'KR',
    appId: 'hanchao_subway',
    appVersion: '2026.07',
    priority: 100,
    url: 'https://map.hanchao.com/psubway',
    routes: ['/psubway'],
    swrDoc: false,
    prerender: false,
    codeCache: false,
    bundle: true,
    prefetchChunks: false,
    userAgent: HANCHAO_SUBWAY_UA,
    manifestUrl: '/bundles/hanchao_subway/manifest.json',
    bundleVersion: '6c5c5b05bb86a077',
    compressedManifestUrl: '/bundles/hanchao_subway/manifest.zz.json',
    compressedBundleVersion: '799f6d761f5b9d7d',
    bundleExcludeUrls: [
      '*.png',
      '*.jpg',
      '*.jpeg',
      '*.webp',
      '*.gif',
      '*.svg',
      '*.ico',
      '*.avif',
      '*.mp4',
      '*.webm',
      '*.m3u8',
      '*.ts',
      '*.mov',
      '*.woff',
      '*.woff2',
      '*.ttf',
      '*.otf',
      '*.eot'
    ],
    extraBlockHosts: [
      'https://www.googletagmanager.com',
      'https://googletagmanager.com',
      'https://www.google-analytics.com',
      'https://google-analytics.com'
    ],
    preconnectHosts: ['https://map.hanchao.com']
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
      AppStorage.setOrCreate<string>('launchTarget', '');
      return;
    }
    const rawUrl = params.targetUrl;
    const url = typeof rawUrl === 'string' ? rawUrl.trim() : '';
    if (typeof url === 'string' && url.length > 0) {
      AppStorage.setOrCreate<string>('launchTarget', url);
      return;
    }
    AppStorage.setOrCreate<string>('launchTarget', '');
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
