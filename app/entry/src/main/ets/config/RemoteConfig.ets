import { http } from '@kit.NetworkKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

const TAG: string = 'RemoteConfig';
const DOMAIN: number = 0x0001;

/**
 * ★★★ 改成你的后台服务器地址 ★★★
 *  - 真机/模拟器调试:填运行 server 的电脑局域网 IP(如 http://192.168.1.100:8787),不能用 localhost;
 *  - 生产:填你的域名(如 https://admin.example.com)。
 */
export const CONFIG_SERVER: string = 'http://192.168.20.133:8787';

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

/** App 内置兜底:服务器首次不可达时也能跑(开机拉到后即覆盖) */
function fallbackConfig(): RemoteConfigData {
  return {
    version: '',
    apps: [{ id: 'beacukai', name: '印尼海关 e-CD', url: 'https://ecd.beacukai.go.id/', bundle: true }],
    blockHosts: [],
    settings: { diskCapMB: 64, docCheckSec: 60, bytecodeCache: true }
  };
}

/**
 * 远程配置管理器(单例)。
 *  load():开机同步读沙箱里的上次配置(秒返回,不阻塞首屏);
 *  refresh():异步拉服务器最新配置,成功后写沙箱 + 更新内存 + 回调通知。
 * apps 同步写入 AppStorage('apps'),launcher 用 @StorageLink 自动响应更新。
 */
class RemoteConfigManager {
  private data: RemoteConfigData = fallbackConfig();
  private cachePath: string = '';
  private onApps: ((apps: RemoteApp[]) => void) | null = null;

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

  /** 异步拉服务器最新配置;成功返回 true */
  async refresh(): Promise<boolean> {
    const txt: string = await this.httpGetText(CONFIG_SERVER + '/api/config');
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
