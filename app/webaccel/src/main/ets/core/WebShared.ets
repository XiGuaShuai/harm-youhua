import { webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { webCache } from './WebCacheManager';

const TAG: string = 'WebPerf';
const DOMAIN: number = 0x0001;
// 注:字节码注入(injectOfflineResources)在元服务中被平台禁用,已移除;
// 其余加速层(离线缓存拦截 / 主文档 SWR / 离屏预渲染 / chunk 预取 / 黑名单短路)照常工作。

interface XeResourcePayload {
  ok?: boolean;
  url?: string;
  mime?: string;
  status?: number;
  b64?: string;
  error?: string;
}

interface XeBridgeMessage {
  type?: string;
  id?: string;
  url?: string;
  mime?: string;
  status?: number;
  part?: string;
  error?: string;
  count?: number;
}

interface XeDumpPending {
  url: string;
  mime: string;
  status: number;
  chunks: string[];
  received: number;
}

class XeDumpBridge {
  private pending: Map<string, XeDumpPending> = new Map();

  push(message: string): void {
    try {
      const msg = JSON.parse(message) as XeBridgeMessage;
      const type: string = msg && msg.type ? msg.type : '';
      const id: string = msg && msg.id ? msg.id : '';
      if (type === 'list') {
        hilog.info(DOMAIN, TAG, 'XE_DUMP_LIST %{public}d', msg && typeof msg.count === 'number' ? msg.count : 0);
        return;
      }
      if (type === 'done') {
        hilog.info(DOMAIN, TAG, 'XE_DUMP_DONE %{public}d', msg && typeof msg.count === 'number' ? msg.count : 0);
        return;
      }
      if (id.length === 0) {
        return;
      }
      if (type === 'start') {
        const status: number = msg && typeof msg.status === 'number' ? msg.status : -1;
        this.pending.set(id, {
          url: msg && msg.url ? msg.url : '',
          mime: msg && msg.mime ? msg.mime : '',
          status: status,
          chunks: [],
          received: 0
        });
        hilog.info(DOMAIN, TAG, 'XE_DUMP_START status=%{public}d %{public}s', status, msg && msg.url ? msg.url : '');
        return;
      }
      if (type === 'chunk') {
        const pending: XeDumpPending | undefined = this.pending.get(id);
        if (!pending || !msg || !msg.part) {
          return;
        }
        pending.chunks.push(msg.part);
        pending.received += msg.part.length;
        return;
      }
      if (type === 'finish') {
        const pending: XeDumpPending | undefined = this.pending.get(id);
        if (!pending) {
          return;
        }
        this.pending.delete(id);
        const b64: string = pending.chunks.join('');
        if (pending.status === 200 && pending.url.length > 0 && b64.length > 0) {
          webCache.dumpBase64Resource(pending.url, pending.mime, b64);
        } else {
          hilog.warn(DOMAIN, TAG, 'XE_DUMP_SKIP status=%{public}d b64=%{public}d mime=%{public}s %{public}s',
            pending.status, b64.length, pending.mime, pending.url);
        }
        return;
      }
      if (type === 'error') {
        this.pending.delete(id);
        hilog.warn(DOMAIN, TAG, 'XE_DUMP_ERROR err=%{public}s %{public}s',
          msg && msg.error ? msg.error : '', msg && msg.url ? msg.url : '');
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'XE_DUMP_BRIDGE_PARSE');
    }
  }
}

const xeDumpBridge: XeDumpBridge = new XeDumpBridge();

/**
 * 一个网页实例的状态 + 配置。在离屏预渲染和页面展示之间共享同一个对象,
 * Web 的回调更新这里的字段,并通过 notify 通知正在展示它的页面刷新。
 */
export class WebViewModel {
  url: string;
  controller: webview.WebviewController;
  progress: number;
  firstPaint: boolean;
  loading: boolean;
  loadedAt: number;            // 最近一次加载完成时间(供"刚加载完才自动刷新"判断)
  notify: (() => void) | null; // 展示页注册:状态变化时刷新 UI

  constructor(url: string) {
    this.url = url;
    this.controller = new webview.WebviewController();
    this.progress = 0;
    this.firstPaint = false;
    this.loading = true;
    this.loadedAt = 0;
    this.notify = null;
  }

  private fire(): void {
    if (this.notify) {
      this.notify();
    }
  }

  onProgress(p: number): void {
    this.progress = p;
    this.fire();
  }

  onPainted(): void {
    if (!this.firstPaint) {
      this.firstPaint = true;
      hilog.info(DOMAIN, TAG, 'FCP %{public}s', this.url);
    }
    this.fire();
  }

  onBegin(): void {
    this.loading = true;
    this.fire();
  }

  onEnd(): void {
    this.loading = false;
    this.firstPaint = true;
    this.loadedAt = Date.now();
    hilog.info(DOMAIN, TAG, 'onPageEnd %{public}s', this.url);
    this.fire();
  }
}

/**
 * 全局 @Builder:所有网页统一的 Web 配置。
 * 离线缓存拦截、Google 短路、加载回调都集中在这里 —— 加新网页无需重复配置。
 */
@Builder
export function buildWeb(model: WebViewModel) {
  Web({ src: model.url, controller: model.controller })
    .cacheMode(CacheMode.Default)
    .domStorageAccess(true)
    .databaseAccess(true)
    .fileAccess(true)
    .imageAccess(true)
    .onlineImageAccess(true)
    .javaScriptAccess(true)
    .javaScriptProxy({
      object: xeDumpBridge,
      name: '__WebAccelXeDump',
      methodList: ['push'],
      controller: model.controller
    })
    .mixedMode(MixedMode.All)
    .zoomAccess(true)
    .geolocationAccess(true)
    .width('100%')
    .height('100%')
    // UA 策略:
    //  ① 该应用后台下发了自定义 UA(app.userAgent,如 bilibili.tv 要桌面 UA)→ 整体用它,不再追加 Mobile;
    //  ② 否则走默认手机化:不含 Mobile 则追加,让多数站返回移动版(避免被当非手机 → 不适配/白屏)。
    // 站点按 UA 分手机/桌面分支,个别站(国际版视频站)桌面分支才正常,故开放每应用覆盖,由后台按站配置。
    .onControllerAttached(() => {
      try {
        const customUa: string = webCache.userAgentFor(model.url);
        if (customUa.length > 0) {
          model.controller.setCustomUserAgent(customUa); // 每应用 UA:整体替换
        } else {
          const ua: string = model.controller.getUserAgent();
          if (ua.indexOf('Mobile') < 0) {
            model.controller.setCustomUserAgent(ua + ' Mobile Safari/537.36'); // 默认手机化
          }
        }
      } catch (e) {
        // 设 UA 失败不影响加载
      }
    })
    // 网页请求定位(如 Booking"当前位置搜索")时授权给网页 → 网页能拿到位置才能搜。
    // 元服务本身的系统定位权限在 EntryAbility 启动时申请(见 EntryAbility.ets)。
    .onGeolocationShow((event) => {
      if (event) {
        event.geolocation.invoke(event.origin, true, false); // 允许该 origin 使用定位,不永久保存
      }
    })
    .onInterceptRequest((event) => {
      try {
        const req = event.request;
        return webCache.intercept(req.getRequestUrl(), req.getRequestMethod(), req.getRequestHeader());
      } catch (e) {
        return null;
      }
    })
    .onProgressChange((event) => {
      if (event) {
        model.onProgress(event.newProgress);
        // 秒开关键:动态 SPA 站 FCP 触发晚甚至不触发,占位就会傻等到 onPageEnd 才消失(多停几秒)。
        // 进度到 85% 才主动消占位(留足 CSS 加载时间,避免过早露出无样式中间态);仍比傻等 onPageEnd 快很多。
        // onPainted 内部去重,不会重复触发。优先还是靠真实 FCP 回调消位(见下),这里只是兜底。
        if (event.newProgress >= 85 && !model.firstPaint) {
          model.onPainted();
        }
      }
    })
    .onFirstContentfulPaint(() => {
      model.onPainted();
      // 首屏内容已绘制 → 立即后台预取二级 chunk(比等 onPageEnd+3s 提前约 2.5s,翻页更跟手)。
      // prefetchSiteChunks 内部按 origin 去重,重复调用无副作用。
      webCache.prefetchSiteChunks(model.url);
    })
    .onPageBegin(() => {
      model.onBegin();
      // 注:曾在此注入脚本隐藏网站自身 loading 元素,但 [class*=loading]/[splash] 模糊匹配会误伤
      // 正常的大面积内容容器(轮播/banner/lazy-loading 包裹层)→ 三个站均出现排版错乱,故移除。
      // "loading 滞后"改由更安全的方式治理:占位绑 FCP / 进度阈值消位(见 onProgressChange),不碰页面 DOM。
    })
    .onPageEnd(() => {
      model.onEnd();
      if (model.url.indexOf('https://www.xe.com') === 0) {
        try {
          const cookie: string = webview.WebCookieManager.fetchCookieSync('https://www.xe.com/zh-cn/');
          hilog.info(DOMAIN, TAG, 'XE_COOKIE %{public}s', cookie);
        } catch (e) {
          hilog.warn(DOMAIN, TAG, 'XE_COOKIE unavailable');
        }
        dumpXeStaticResources(model);
      }
      webCache.flushPending();
      // 兜底:个别站不触发 FCP 时,页面稳定后短延迟再预取一次(已缓存的会被去重跳过)
      setTimeout(() => {
        webCache.prefetchSiteChunks(model.url);
      }, 800);
    })
}

function dumpXeStaticResources(model: WebViewModel): void {
  const script: string =
    `(function(){try{if(window.__xeDumpStarted){return 'running';}var bridge=window.__WebAccelXeDump;if(!bridge||!bridge.push){return 'no-bridge';}window.__xeDumpStarted=true;var urls=Array.from(new Set(performance.getEntriesByType('resource').map(function(e){return e.name;}))).filter(function(u){return /^https:\\/\\/www\\.xe\\.com\\/_next\\/static\\//.test(u);});function send(o){try{bridge.push(JSON.stringify(o));}catch(e){}}function sleep(ms){return new Promise(function(resolve){setTimeout(resolve,ms);});}async function dumpOne(u,idx){var id='xe-'+Date.now()+'-'+idx;try{var r=await fetch(u,{credentials:'include',cache:'force-cache'});var b=await r.arrayBuffer();var a=new Uint8Array(b);send({type:'start',id:id,url:u,mime:r.headers.get('content-type')||'',status:r.status});var bin='';var step=8192;var flush=24576;for(var i=0;i<a.length;i+=step){bin+=String.fromCharCode.apply(null,a.subarray(i,i+step));if(bin.length>=flush){send({type:'chunk',id:id,part:btoa(bin)});bin='';}}if(bin.length>0){send({type:'chunk',id:id,part:btoa(bin)});}send({type:'finish',id:id});}catch(e){send({type:'error',id:id,url:u,error:String(e)});}}async function run(){send({type:'list',id:'list',count:urls.length});for(var i=0;i<urls.length;i++){await dumpOne(urls[i],i);await sleep(20);}send({type:'done',id:'done',count:urls.length});}run();return 'queued:'+urls.length;}catch(e){return 'setup-error:'+String(e);}})()`;
  model.controller.runJavaScript(script)
    .then((result: string) => {
      hilog.info(DOMAIN, TAG, 'XE_DUMP_QUEUE %{public}s', result);
    })
    .catch(() => {
      hilog.warn(DOMAIN, TAG, 'XE_DUMP_QUEUE failed');
    });
}
