import { http } from '@kit.NetworkKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

const TAG: string = 'RemoteConfig';
const DOMAIN: number = 0x0001;

/** 一个网页应用(对应后台「应用管理」一条) */
export interface RemoteApp {
  id: string;
  name: string;
  url: string;
  routes?: string[];
  swrDoc?: boolean;
  prerender?: boolean;
  codeCache?: boolean;
  bundle?: boolean;
  manifestUrl?: string; // 后台下发:启用离线包且已打包时才有,App 据此去服务器下载
}

export interface RemoteSettings {
  diskCapMB?: number;
  docCheckSec?: number;
  bytecodeCache?: boolean;
}

export interface RemoteConfigData {
  version: string;
  apps: RemoteApp[];
  blockHosts: string[];
  settings: RemoteSettings;
}

/** configure() 入参:由 WebAccel.init 传入,把后台地址 / 直供列表 / 黑名单 / 设置注入 SDK */
export interface ConfigureOptions {
  configServer?: string;     // admin 后台地址(如 https://admin.example.com);不填 = 不联网
  apps?: RemoteApp[];        // 直供应用列表(不依赖后台时用)
  blockHosts?: string[];     // 过滤黑名单(覆盖默认内置;不填用 SDK 内置)
  settings?: RemoteSettings; // 缓存上限 / 主文档校验节流 / 字节码开关
}

/** SDK 内置兜底:无后台、无缓存、未直供时也能跑(空列表;拉到/直供后即覆盖) */
function fallbackConfig(): RemoteConfigData {
  return {
    version: '',
    apps: [],
    blockHosts: [],
    settings: { diskCapMB: 64, docCheckSec: 60, bytecodeCache: true }
  };
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
  private cachePath: string = '';
  private server: string = '';   // 后台地址(运行时由 configure 注入;为空 = 不联网,纯直供/缓存/兜底)
  private onApps: ((apps: RemoteApp[]) => void) | null = null;

  /** 注入配置(在 load 之前调用)。configServer 为空时 SDK 走纯直供/本地模式,不联网 */
  configure(opt?: ConfigureOptions): void {
    if (!opt) {
      return;
    }
    if (typeof opt.configServer === 'string') {
      this.server = opt.configServer.replace(/\/+$/, ''); // 去尾部斜杠,避免拼出 //api/config
    }
    if (opt.apps && opt.apps.length > 0) {
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

  /** 异步拉服务器最新配置;成功返回 true。未配置 server 时直接返回 false(纯直供/本地模式) */
  async refresh(): Promise<boolean> {
    if (this.server.length === 0) {
      hilog.info(DOMAIN, TAG, 'refresh: no configServer, skip (direct/local mode)');
      return false;
    }
    const txt: string = await this.httpGetText(this.server + '/api/config');
    if (txt.length === 0) {
      hilog.warn(DOMAIN, TAG, 'refresh: server unreachable, keep cached');
      return false;
    }
    try {
      const next = JSON.parse(txt) as RemoteConfigData;
      if (!next || !Array.isArray(next.apps)) {
        return false;
      }
      this.data = next;
      this.saveCache(txt);
      this.publishApps();
      hilog.info(DOMAIN, TAG, 'refreshed apps=%{public}d block=%{public}d',
        this.data.apps.length, this.data.blockHosts ? this.data.blockHosts.length : 0);
      return true;
    } catch (e) {
      const er = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'refresh parse failed: %{public}s', er.message);
      return false;
    }
  }

  getApps(): RemoteApp[] { return this.data.apps || []; }
  getBlockHosts(): string[] { return this.data.blockHosts || []; }
  getSettings(): RemoteSettings { return this.data.settings || {}; }

  /** 注册 apps 更新回调(launcher 之外的消费者用) */
  setAppsHandler(cb: (apps: RemoteApp[]) => void): void {
    this.onApps = cb;
    this.onApps(this.getApps());
  }

  private publishApps(): void {
    // 全局状态,launcher 用 @StorageLink('apps') 自动响应
    AppStorage.setOrCreate<RemoteApp[]>('apps', this.getApps());
    if (this.onApps) {
      this.onApps(this.getApps());
    }
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

  private httpGetText(url: string): Promise<string> {
    return new Promise<string>((resolve) => {
      const client = http.createHttp();
      const header: Record<string, string> = { 'Accept': 'application/json,text/plain,*/*' };
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        header: header,
        connectTimeout: 15000,
        readTimeout: 30000
      };
      client.request(url, options, (err: BusinessError, data: http.HttpResponse) => {
        let out: string = '';
        if (!err && data && data.responseCode === 200 && typeof data.result === 'string') {
          out = data.result as string;
        }
        client.destroy();
        resolve(out);
      });
    });
  }
}

export const remoteConfig: RemoteConfigManager = new RemoteConfigManager();
