import { WebAccel, RemoteApp } from 'webaccel';

@Entry
@Component
struct Index {
  // 应用列表来自加速 SDK(EntryAbility 开机 WebAccel.init 后写入 AppStorage('apps'));拉到新配置会自动刷新。
  // 这里的默认值仅作服务器首次不可达时的兜底。
  @StorageLink('apps') apps: RemoteApp[] = [
    { id: 'beacukai', name: '印尼海关 e-CD', url: 'https://ecd.beacukai.go.id/' }
  ];

  aboutToAppear(): void {
    // 进 launcher 就把这些网页离屏预渲染好,点开时秒显
    WebAccel.attach(this.getUIContext());
    for (let i = 0; i < this.apps.length; i++) {
      WebAccel.prewarm(this.apps[i].url, true);
    }
  }

  build() {
    Column({ space: 14 }) {
      Text('网页应用')
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .margin({ top: 48, bottom: 16 })
      ForEach(this.apps, (a: RemoteApp) => {
        Button(a.name)
          .width('80%')
          .height(50)
          .fontSize(16)
          .backgroundColor('#0A59F7')
          .onClick(() => {
            const p: Record<string, string> = { 'url': a.url };
            this.getUIContext().getRouter().pushUrl({ url: 'pages/WebPage', params: p });
          })
      }, (a: RemoteApp) => a.url)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F0F2F5')
  }
}
