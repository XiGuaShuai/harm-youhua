import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

export class CacheWriteResult {
  ok: boolean = false;
  code: number = 0;
  message: string = '';
  phase: string = 'open';
}

/** File operations shared by resources, the index and remote configuration. */
export class CacheFile {
  static write(path: string, bytes: ArrayBuffer): CacheWriteResult {
    const result: CacheWriteResult = new CacheWriteResult();
    const temporary: string = path + '.pending';
    let fd: number = -1;
    try {
      fd = fs.openSync(temporary, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC).fd;
      result.phase = 'write';
      let offset: number = 0;
      while (offset < bytes.byteLength) {
        const chunk: ArrayBuffer = offset === 0 ? bytes : bytes.slice(offset);
        const written: number = fs.writeSync(fd, chunk);
        if (written <= 0 || written > chunk.byteLength) {
          throw new Error('incomplete file write');
        }
        offset += written;
      }
      result.ok = true;
    } catch (error) {
      const failure = error as BusinessError;
      result.code = typeof failure.code === 'number' ? failure.code : 0;
      result.message = failure.message;
    } finally {
      if (fd >= 0) {
        try {
          fs.closeSync(fd);
        } catch (error) {
          const failure = error as BusinessError;
          result.ok = false;
          result.phase = 'close';
          result.code = typeof failure.code === 'number' ? failure.code : 0;
          result.message = failure.message;
        }
      }
    }
    if (result.ok) {
      try {
        result.phase = 'verify';
        if (!CacheFile.hasSize(temporary, bytes.byteLength)) {
          throw new Error('saved file length mismatch');
        }
        result.phase = 'rename';
        fs.renameSync(temporary, path);
        return result;
      } catch (error) {
        const failure = error as BusinessError;
        result.ok = false;
        result.code = typeof failure.code === 'number' ? failure.code : 0;
        result.message = failure.message;
      }
    }
    CacheFile.remove(temporary);
    hilog.error(0x0001, 'WebCacheFile',
      'write rejected phase=%{public}s code=%{public}d expected=%{public}d path=%{public}s message=%{public}s',
      result.phase, result.code, bytes.byteLength, path, result.message);
    return result;
  }

  static writeText(path: string, text: string): boolean {
    const encoded: Uint8Array = new util.TextEncoder().encodeInto(text);
    return CacheFile.write(path, encoded.buffer.slice(encoded.byteOffset,
      encoded.byteOffset + encoded.byteLength)).ok;
  }

  static read(path: string): ArrayBuffer | null {
    let fd: number = -1;
    let result: ArrayBuffer | null = null;
    try {
      const size: number = fs.statSync(path).size;
      const bytes: ArrayBuffer = new ArrayBuffer(size);
      fd = fs.openSync(path, fs.OpenMode.READ_ONLY).fd;
      let offset: number = 0;
      while (offset < size) {
        const chunk: ArrayBuffer = offset === 0 ? bytes : new ArrayBuffer(size - offset);
        const received: number = fs.readSync(fd, chunk);
        if (received <= 0 || received > chunk.byteLength) {
          throw new Error('incomplete file read');
        }
        if (offset > 0) {
          new Uint8Array(bytes).set(new Uint8Array(chunk, 0, received), offset);
        }
        offset += received;
      }
      result = bytes;
    } catch (error) {
      result = null;
    } finally {
      if (fd >= 0) {
        try {
          fs.closeSync(fd);
        } catch (error) {
          result = null;
        }
      }
    }
    return result;
  }

  static hasSize(path: string, expected: number): boolean {
    try {
      const stat: fs.Stat = fs.statSync(path);
      return expected >= 0 && stat.isFile() && stat.size === expected;
    } catch (error) {
      return false;
    }
  }

  static remove(path: string): void {
    try {
      if (fs.accessSync(path)) {
        fs.unlinkSync(path);
      }
    } catch (error) {
      // Cleanup must not hide the original write failure.
    }
  }

  static isStoragePressure(code: number): boolean {
    // Some device FileIO builds map native EDQUOT (-122) to Unknown error.
    return code === 13900041 || code === 13900025 || code === 13900042 || code === 122 || code === -122;
  }
}
