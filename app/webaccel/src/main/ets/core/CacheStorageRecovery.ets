import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { CacheFile, CacheWriteResult } from './CacheFile';

/** A single cold-start recovery, before ArkWeb opens its cache files. */
export class CacheStorageRecovery {
  private static checked: boolean = false;

  static prepare(context: common.UIAbilityContext): void {
    if (CacheStorageRecovery.checked) {
      return;
    }
    CacheStorageRecovery.checked = true;
    const probe: string = context.filesDir + '/.webaccel-storage-probe';
    // A 64 KiB probe passed on the affected device while its 5 MiB config
    // still failed. Check headroom for config, temporary replacement files
    // and a regional bundle before ArkWeb opens its disposable caches.
    // This is a temporary write test, not an assumed system quota limit.
    const bytes: ArrayBuffer = new ArrayBuffer(32 * 1024 * 1024);
    const first: CacheWriteResult = CacheFile.write(probe, bytes);
    CacheFile.remove(probe);
    if (first.ok || !CacheFile.isStoragePressure(first.code)) {
      hilog.info(0x0001, 'WebCacheStorage', 'startup writable=%{public}s code=%{public}d',
        first.ok ? 'true' : 'false', first.code);
      return;
    }

    const appCache: string = context.getApplicationContext().cacheDir;
    // Only disposable HTTP/compiled-JS caches. Never traverse web storage,
    // Cookies, Preferences, databases, filesDir, or user-selected directories.
    const directories: string[] = [
      appCache + '/web/Code Cache/js/index-dir',
      appCache + '/web/Code Cache/js',
      appCache + '/web/Cache/Cache_Data/index-dir',
      appCache + '/web/Cache/Cache_Data'
    ];
    let released: number = 0;
    for (let i = 0; i < directories.length; i++) {
      released += CacheStorageRecovery.clearFlatCache(directories[i]);
    }
    const retry: CacheWriteResult = CacheFile.write(probe, bytes);
    CacheFile.remove(probe);
    hilog.warn(0x0001, 'WebCacheStorage',
      'startup recovery released=%{public}d writable=%{public}s beforeCode=%{public}d afterCode=%{public}d',
      released, retry.ok ? 'true' : 'false', first.code, retry.code);
  }

  private static clearFlatCache(directory: string): number {
    let released: number = 0;
    try {
      if (!fs.accessSync(directory)) {
        return 0;
      }
      const names: string[] = fs.listFileSync(directory);
      for (let i = 0; i < names.length; i++) {
        const name: string = names[i];
        if (name === '.' || name === '..' || name.indexOf('/') >= 0 || name.indexOf('\\') >= 0) {
          continue;
        }
        const file: string = directory + '/' + name;
        try {
          const stat: fs.Stat = fs.statSync(file);
          if (stat.isFile()) {
            fs.unlinkSync(file);
            released += stat.size;
          }
        } catch (error) {
          const failure = error as BusinessError;
          hilog.warn(0x0001, 'WebCacheStorage', 'cache cleanup failed code=%{public}d', failure.code);
        }
      }
    } catch (error) {
      const failure = error as BusinessError;
      hilog.warn(0x0001, 'WebCacheStorage', 'cache directory unavailable code=%{public}d', failure.code);
    }
    return released;
  }
}
