import { FormExtensionAbility, formBindingData, formInfo, formProvider } from '@kit.FormKit';
import { Want } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'WebAccelCard';

interface CardApp {
  name: string;
  url: string;
}

// 静态兜底:沙箱还没有缓存配置(首装 / 未联网)时用它,卡片不至于空白。
const FALLBACK: CardApp[] = [
  { name: '印尼海关 e-CD', url: 'https://ecd.beacukai.go.id/' },
  { name: '新加坡环球影城', url: 'https://www.rwsentosa.com/en/play/universal-studios-singapore/tickets' },
  { name: 'Booking.com', url: 'https://www.booking.com/?aid=376371' }
];

export default class EntryFormAbility extends FormExtensionAbility {
  // 读 SDK 缓存的远程配置(WebAccel 写到 filesDir/remote-config.json),取应用名 + URL 当卡片数据
  private loadApps(): CardApp[] {
    try {
      const p: string = this.context.filesDir + '/remote-config.json';
      if (!fs.accessSync(p)) {
        return FALLBACK;
      }
      const size: number = fs.statSync(p).size;
      const buf: ArrayBuffer = new ArrayBuffer(size);
      const f = fs.openSync(p, fs.OpenMode.READ_ONLY);
      fs.readSync(f.fd, buf);
      fs.closeSync(f);
      const txt: string = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf));
      const cfg = JSON.parse(txt) as Record<string, Object>;
      const rawApps = cfg.apps as Object;
      if (!Array.isArray(rawApps)) {
        return FALLBACK;
      }
      const out: CardApp[] = [];
      for (const item of rawApps as Object[]) {
        const a = item as Record<string, Object>;
        const name = a.name as string;
        const url = a.url as string;
        if (name && url) {
          out.push({ name: name, url: url });
        }
      }
      return out.length > 0 ? out.slice(0, 6) : FALLBACK; // 卡片最多展示 6 个
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'loadApps failed: %{public}s', (e as BusinessError).message);
      return FALLBACK;
    }
  }

  private buildData(): formBindingData.FormBindingData {
    const apps: CardApp[] = this.loadApps();
    const data: Record<string, Object> = { 'title': '网页应用', 'apps': apps };
    return formBindingData.createFormBindingData(data);
  }

  onAddForm(want: Want): formBindingData.FormBindingData {
    return this.buildData();
  }

  // 卡片刷新(系统定时 / formProvider 触发):重读缓存配置,跟随后台最新应用列表
  onUpdateForm(formId: string): void {
    try {
      formProvider.updateForm(formId, this.buildData());
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'updateForm failed: %{public}s', (e as BusinessError).message);
    }
  }

  onCastToNormalForm(formId: string): void {
  }

  onRemoveForm(formId: string): void {
  }

  onFormEvent(formId: string, message: string): void {
  }

  onAcquireFormState(want: Want): formInfo.FormState {
    return formInfo.FormState.READY;
  }
}
