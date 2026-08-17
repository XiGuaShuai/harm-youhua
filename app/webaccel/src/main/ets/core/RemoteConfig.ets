import { http } from '@kit.NetworkKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import BuildProfile from '../../../../BuildProfile'; // SDK 自己的生成文件(build-profile 按 debug/release 注入 CONFIG_SERVER)

const TAG: string = 'RemoteConfig';
const DOMAIN: number = 0x0001;

/** 静态资源缓存策略:控制哪些运行时静态资源值得写入沙箱 */
export interface StaticCachePolicy {
  enabled?: boolean;       // false=不写运行时静态资源缓存(离线包资源仍按 manifest 处理)
  minSizeKB?: number;      // 大于等于该体积才缓存;0/不填=不按体积过滤
  minDurationMs?: number;  // 下载耗时大于等于该值才缓存;0/不填=不按耗时过滤
  maxSizeKB?: number;      // 大于该体积不缓存;0/不填=不设上限
  include?: string[];      // 命中即缓存(子串匹配;支持 * 通配)
  exclude?: string[];      // 命中即不缓存(子串匹配;支持 * 通配)
}

/** 一个网页应用(对应后台「应用管理」一条) */
export interface RemoteApp {
  id: string;
  name: string;
  url: string;
  scope?: string;            // top / region,用于入口页分组和端侧调度
  region?: string;           // 兼容旧版 SDK:regions 的第一个地区 ID
  regions?: string[];        // AtomicPlatform 地区 ID 列表;同一网址可属于多个地区
  appId?: string;            // 业务应用 ID,不下发时默认等于 id
  appVersion?: string;       // 业务应用版本,用于版本一致性判断
  priority?: number;         // 展示/下载优先级,数字越大越靠前
  localOnly?: boolean;        // 接入方本地测试卡片:远程配置未下发时仍追加到端侧列表,不写回后台
  routes?: string[];
  swrDoc?: boolean;
  prerender?: boolean;
  codeCache?: boolean;
  bundle?: boolean;
  bundleConfigured?: boolean; // true=后台配置了离线包但当前未 READY/未下发 manifest; bundle=true 才表示端侧可用
  manifestUrl?: string;  // 后台下发:启用离线包且已打包时才有,App 据此去服务器下载
  bundleVersion?: string; // 离线包清单指纹:后台下发,设备据此判断"要不要更新本地离线包"
  compressedManifestUrl?: string; // 新端优先使用:可压缩资源以 zlib 存沙箱,旧端忽略
  compressedBundleVersion?: string; // 压缩清单指纹:避免与旧端原始清单版本互相污染
  bundleExtraUrls?: string[]; // 后台构建离线包时手动纳入的固定静态资源 URL(如跨域固定背景图)
  bundleExcludeUrls?: string[]; // 后台构建离线包时排除的静态资源 URL(用于控制沙箱占用)
  configJson?: string;       // 该网址对应的 H5 配置 JSON。可随离线包一起下发,供宿主离线兜底注入
  configEnvironment?: string; // 服务端已按 test/pre/prod 选择 JSON；即使为空也不得回退到其它环境的旧 manifest JSON
  extraBlockHosts?: string[]; // 每应用额外黑名单:只对本应用生效,叠加在全局 blockHosts 之上
  prefetchChunks?: boolean;   // 每应用 chunk 预取开关:覆盖全局 settings.prefetchChunks(不下发=用全局)
  preconnectHosts?: string[]; // 每应用额外预连接域:开机提前对这些CDN/接口域做DNS+TLS握手,点进去时资源直连不等握手。
                              // 通用能力:动态/JS渲染站(如视频站)主文档空、资源在跨域CDN,预连其CDN域能压短白屏期。后台按站配置。
  userAgent?: string;         // 每应用自定义 UA:覆盖该应用 origin 下的 UA。某些站(如 bilibili.tv 国际版)按 UA 判断
                              // 手机/桌面分支,默认追加 Mobile 反而触发不适配/白屏 → 给它单独下发桌面 UA。
                              // 不下发=维持 SDK 默认"不含 Mobile 则追加 Mobile"的手机化逻辑。后台按站配置,不硬编码。
  staticCache?: StaticCachePolicy; // 每应用运行时静态资源缓存策略:优先缓存大资源/慢资源,排除低价值资源。
}

/** 读取应用的全部地区 ID。兼容只下发 region 的旧后台配置。 */
export function remoteAppRegions(app: RemoteApp): string[] {
  const result: string[] = new Array<string>();
  const seen: Set<string> = new Set<string>();
  if (app && app.regions && app.regions.length > 0) {
    for (let i = 0; i < app.regions.length; i++) {
      const id: string = app.regions[i] ? app.regions[i].trim() : '';
      if (id.length > 0 && !seen.has(id)) {
        seen.add(id);
        result.push(id);
      }
    }
  }
  const legacy: string = app && app.region ? app.region.trim() : '';
  if (legacy.length > 0 && !seen.has(legacy)) {
    result.push(legacy);
  }
  return result;
}

/** top 应用对任意地区可用;region 应用必须包含当前地区 ID。 */
export function remoteAppMatchesRegion(app: RemoteApp, region: string): boolean {
  if (!app || app.scope !== 'region') {
    return true;
  }
  const target: string = region ? region.trim() : '';
  if (target.length === 0) {
    return false;
  }
  const regions: string[] = remoteAppRegions(app);
  for (let i = 0; i < regions.length; i++) {
    if (regions[i] === target) {
      return true;
    }
  }
  return false;
}

export interface RemoteSettings {
  diskCapMB?: number;
  docCheckSec?: number;
  configRefreshSec?: number; // 端侧定时拉取 /api/config 的间隔;<=0 表示关闭,默认由 SDK 控制
  bundleConcurrency?: number;
  prefetchChunks?: boolean;  // 是否预取全站 chunk(Next.js 系站点有效;非 Next 站自动无操作)。默认 true
  bytecodeCache?: boolean;
  staticCache?: StaticCachePolicy; // 全局默认静态资源缓存策略;每应用 staticCache 可覆盖/叠加。
}

/** 任务派发:后台下发的待探索清单 + 共识阈值 K + 采样率 */
export interface ExploreDispatch {
  apps: string[];
  k: number;
  sample: number;
}

export interface RemoteConfigData {
  version: string;
  apps: RemoteApp[];
  blockHosts: string[];
  settings: RemoteSettings;
  explore?: ExploreDispatch; // 众包探索任务派发(后台 /api/config 下发)
}

/** configure() 入参:由 WebAccel.init 传入,把后台地址 / 直供列表 / 黑名单 / 设置注入 SDK */
export interface ConfigureOptions {
  configServer?: string;     // admin 后台地址(如 https://admin.example.com);不填 = 不联网
  apps?: RemoteApp[];        // 直供应用列表(不依赖后台时用)
  blockHosts?: string[];     // 过滤黑名单(覆盖默认内置;不填用 SDK 内置)
  settings?: RemoteSettings; // 缓存上限 / 主文档校验节流 / 字节码开关
}

type AppsHandler = (apps: RemoteApp[]) => void;

/** SDK 内置兜底:无后台、无缓存、未直供时也能跑(空列表;拉到/直供后即覆盖) */
function fallbackConfig(): RemoteConfigData {
  return {
    version: '',
    apps: [],
    blockHosts: [],
    settings: { diskCapMB: 160, docCheckSec: 60, bundleConcurrency: 3, bytecodeCache: true }
  };
}

export interface ConfigRefreshOptions {
  reason?: string;
}

export interface ConfigRefreshResult {
  requestId: number;
  status: string; // success / failed / cancelled / superseded
  success: boolean;
  message: string;
  startedAt: number;
  finishedAt: number;
}

export interface ConfigRefreshState {
  requestId: number;
  status: string; // idle / running / success / failed / cancelled / superseded
  running: boolean;
  reason: string;
  startedAt: number;
  finishedAt: number;
}

interface HttpTextResult {
  status: string;
  text: string;
  message: string;
}

interface ActiveHttpRequest {
  requestId: number;
  client: http.HttpRequest;
  settled: boolean;
  resolve: (result: HttpTextResult) => void;
}

/**
 * 远程配置管理器(单例)。
 *  configure():由 WebAccel.init 注入后台地址 / 直供列表 / 黑名单 / 设置(在 load 之前调用);
 *  load():开机同步读沙箱里的上次配置(秒返回,不阻塞首屏);
 *  refresh():异步拉服务器最新配置,成功后写沙箱 + 更新内存 + 回调通知(未配置 server 则直接跳过)。
 * apps 同步写入 AppStorage('apps'),launcher 用 @StorageLink 自动响应更新。
 */
class RemoteConfigManager {
  private data: RemoteConfigData = fallbackConfig();
  private directApps: RemoteApp[] = [];
  private cachePath: string = '';
  // 后台地址默认值 = SDK 自带(build-profile 按 debug/release 注入的 BuildProfile.CONFIG_SERVER);
  // 接入方通常无需再传,init({ configServer }) 可覆盖。为空字符串 = 不联网(纯直供/缓存/兜底)。
  private server: string = (BuildProfile.CONFIG_SERVER || '').replace(/\/+$/, '');
  private source: string = 'fallback'; // 当前配置来源:server / cache / fallback(调试用)
  private appHandlers: AppsHandler[] = [];
  private latestRequestId: number = 0;
  private activeHttpRequest: ActiveHttpRequest | null = null;

  /** 注入配置(在 load 之前调用)。默认用 SDK 自带后台地址;传 configServer 可覆盖 */
  configure(opt?: ConfigureOptions): void {
    if (!opt) {
      return;
    }
    if (typeof opt.configServer === 'string' && opt.configServer.length > 0) {
      this.server = opt.configServer.replace(/\/+$/, ''); // 去尾部斜杠,避免拼出 //api/config
    }
    if (opt.apps && opt.apps.length > 0) {
      this.directApps = opt.apps;
      this.data.apps = opt.apps; // 直供列表(作为默认;后续缓存/服务器配置会覆盖)
    }
    if (opt.blockHosts && opt.blockHosts.length > 0) {
      this.data.blockHosts = opt.blockHosts;
    }
    if (opt.settings) {
      this.data.settings = opt.settings;
    }
  }

  /** 后台地址(供 WebPreRender 拼离线包 manifest 用;为空表示未配置后台) */
  getServer(): string {
    return this.server;
  }

  /** 运行时直接喂应用列表(不依赖后台;会写入 AppStorage 并触发回调) */
  setApps(apps: RemoteApp[]): void {
    this.data.apps = apps || [];
    this.publishApps();
  }

  /** 开机同步初始化:读沙箱缓存(没有就用兜底),并写入 AppStorage */
  load(context: common.UIAbilityContext): void {
    this.cachePath = context.filesDir + '/remote-config.json';
    try {
      if (fs.accessSync(this.cachePath)) {
        const size: number = fs.statSync(this.cachePath).size;
        const buf: ArrayBuffer = new ArrayBuffer(size);
        const f = fs.openSync(this.cachePath, fs.OpenMode.READ_ONLY);
        fs.readSync(f.fd, buf);
        fs.closeSync(f);
        const txt: string = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf));
        if (txt.length > 0) {
          const parsed = JSON.parse(txt) as RemoteConfigData;
          if (parsed && Array.isArray(parsed.apps)) {
            this.data = parsed;
            this.mergeDirectAppMetadata();
            this.source = 'cache'; // 来自上次服务器写入的沙箱缓存
          }
        }
      }
    } catch (e) {
      const er = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'load cache failed: %{public}s', er.message);
    }
    this.publishApps();
    hilog.info(DOMAIN, TAG, 'loaded (cached) apps=%{public}d', this.data.apps.length);
  }

  /** 异步拉服务器最新配置；requestId 用于阻止被取消/被替代的旧请求写入全局状态。 */
  async refresh(requestId: number, startedAt: number): Promise<ConfigRefreshResult> {
    this.latestRequestId = requestId;
    if (this.server.length === 0) {
      hilog.info(DOMAIN, TAG, 'refresh: no configServer, skip (direct/local mode)');
      return this.refreshResult(requestId, 'failed', 'configServer is empty', startedAt);
    }
    const response: HttpTextResult = await this.httpGetText(this.server + '/api/config', requestId);
    if (response.status !== 'success') {
      return this.refreshResult(requestId, response.status, response.message, startedAt);
    }
    if (requestId !== this.latestRequestId) {
      return this.refreshResult(requestId, 'superseded', 'newer refresh exists', startedAt);
    }
    try {
      const next = JSON.parse(response.text) as RemoteConfigData;
      if (!next || !Array.isArray(next.apps)) {
        return this.refreshResult(requestId, 'failed', 'invalid config response', startedAt);
      }
      if (requestId !== this.latestRequestId) {
        return this.refreshResult(requestId, 'superseded', 'newer refresh exists', startedAt);
      }
      this.data = next;
      this.mergeDirectAppMetadata();
      this.source = 'server'; // 本次成功从后台拉到
      this.saveCache(response.text);
      this.publishApps();
      hilog.info(DOMAIN, TAG, 'refreshed apps=%{public}d block=%{public}d',
        this.data.apps.length, this.data.blockHosts ? this.data.blockHosts.length : 0);
      return this.refreshResult(requestId, 'success', '', startedAt);
    } catch (e) {
      const er = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'refresh parse failed: %{public}s', er.message);
      return this.refreshResult(requestId, 'failed', er.message, startedAt);
    }
  }

  /** 真正终止当前 HTTP 请求，并让等待中的 Promise 立即得到取消/替代结果。 */
  cancelRefresh(requestId: number, status: string = 'cancelled'): boolean {
    if (requestId === this.latestRequestId) {
      this.latestRequestId = requestId + 1;
    }
    const active: ActiveHttpRequest | null = this.activeHttpRequest;
    if (!active || active.requestId !== requestId || active.settled) {
      return false;
    }
    active.settled = true;
    this.activeHttpRequest = null;
    try {
      active.client.destroy();
    } catch (_e) {
    }
    active.resolve({ status, text: '', message: status });
    return true;
  }

  getApps(): RemoteApp[] { return this.data.apps || []; }
  getBlockHosts(): string[] { return this.data.blockHosts || []; }
  getSettings(): RemoteSettings { return this.data.settings || {}; }
  getExplore(): ExploreDispatch { const e = this.data.explore; return e ? e : { apps: new Array<string>(), k: 3, sample: 0 }; }
  getSource(): string { return this.source; }        // server / cache / fallback
  getVersion(): string { return this.data.version || ''; }

  /** 注册 apps 更新回调(launcher 之外的消费者用) */
  setAppsHandler(cb: (apps: RemoteApp[]) => void): void {
    this.appHandlers.push(cb);
    cb(this.getApps());
  }

  private publishApps(): void {
    // 全局状态,launcher 用 @StorageLink('apps') 自动响应
    AppStorage.setOrCreate<RemoteApp[]>('apps', this.getApps());
    // 配置来源 / 版本也发布到 AppStorage,调试浮窗用 @StorageLink 订阅 → 拉到配置即自动刷新(不用点)
    AppStorage.setOrCreate<string>('configSource', this.source);
    AppStorage.setOrCreate<string>('configVersion', this.getVersion());
    const apps: RemoteApp[] = this.getApps();
    for (let i = 0; i < this.appHandlers.length; i++) {
      this.appHandlers[i](apps);
    }
  }

  // 兼容旧缓存/旧后台:如果服务端配置缺少 region/scope 等新字段,从接入方直供兜底列表按 id/url 补齐。
  private mergeDirectAppMetadata(): void {
    if (!this.directApps || this.directApps.length === 0 || !this.data.apps || this.data.apps.length === 0) {
      return;
    }
    for (let i = 0; i < this.data.apps.length; i++) {
      const app: RemoteApp = this.data.apps[i];
      const fallback: RemoteApp | undefined = this.findDirectApp(app);
      if (!fallback) {
        continue;
      }
      if ((!app.scope || app.scope.length === 0) && fallback.scope) app.scope = fallback.scope;
      if ((!app.region || app.region.length === 0) && fallback.region) app.region = fallback.region;
      if ((!app.regions || app.regions.length === 0) && fallback.regions) app.regions = fallback.regions.slice();
      if ((!app.region || app.region.length === 0) && app.regions && app.regions.length > 0) app.region = app.regions[0];
      if ((!app.appId || app.appId.length === 0) && fallback.appId) app.appId = fallback.appId;
      if ((!app.appVersion || app.appVersion.length === 0) && fallback.appVersion) app.appVersion = fallback.appVersion;
      if (app.priority === undefined && fallback.priority !== undefined) app.priority = fallback.priority;
    }
    for (let i = 0; i < this.directApps.length; i++) {
      const pinned: RemoteApp = this.directApps[i];
      if (!pinned || pinned.localOnly !== true) {
        continue;
      }
      let exists: boolean = false;
      for (let j = 0; j < this.data.apps.length; j++) {
        const app: RemoteApp = this.data.apps[j];
        if (app && (app.id === pinned.id || app.url === pinned.url)) {
          exists = true;
          break;
        }
      }
      if (!exists) {
        this.data.apps.push(pinned);
      }
    }
  }

  private findDirectApp(app: RemoteApp): RemoteApp | undefined {
    for (let i = 0; i < this.directApps.length; i++) {
      const candidate: RemoteApp = this.directApps[i];
      if (candidate.id === app.id || candidate.url === app.url) {
        return candidate;
      }
    }
    return undefined;
  }

  private saveCache(txt: string): void {
    try {
      const f = fs.openSync(this.cachePath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(f.fd, txt);
      fs.closeSync(f);
    } catch (e) {
      const er = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'saveCache failed: %{public}s', er.message);
    }
  }

  private refreshResult(requestId: number, status: string, message: string,
    startedAt: number): ConfigRefreshResult {
    return {
      requestId,
      status,
      success: status === 'success',
      message,
      startedAt,
      finishedAt: Date.now()
    };
  }

  private httpGetText(url: string, requestId: number): Promise<HttpTextResult> {
    return new Promise<HttpTextResult>((resolve) => {
      const client = http.createHttp();
      const active: ActiveHttpRequest = { requestId, client, settled: false, resolve };
      this.activeHttpRequest = active;
      const header: Record<string, string> = { 'Accept': 'application/json,text/plain,*/*' };
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        header: header,
        connectTimeout: 15000,
        readTimeout: 30000
      };
      client.request(url, options, (err: BusinessError, data: http.HttpResponse) => {
        if (active.settled) {
          return;
        }
        active.settled = true;
        if (this.activeHttpRequest === active) {
          this.activeHttpRequest = null;
        }
        let result: HttpTextResult = { status: 'failed', text: '', message: '' };
        if (!err && data && data.responseCode === 200 && typeof data.result === 'string') {
          result = { status: 'success', text: data.result as string, message: '' };
        } else if (err) {
          result.message = err.message;
        } else if (data) {
          result.message = `HTTP ${data.responseCode}`;
        }
        client.destroy();
        resolve(result);
      });
    });
  }
}

export const remoteConfig: RemoteConfigManager = new RemoteConfigManager();
