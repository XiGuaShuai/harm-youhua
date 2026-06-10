// ArkTS 服务卡片:列出网页应用,点一项直达元服务对应网页。
// 数据由 EntryFormAbility 通过 formBindingData 注入('title' / 'apps')。
let storage = new LocalStorage();

interface CardApp {
  name: string;
  url: string;
}

@Entry(storage)
@Component
struct WidgetCard {
  @LocalStorageProp('title') title: string = '网页应用';
  @LocalStorageProp('apps') apps: CardApp[] = [];

  // 点卡片打开元服务;带 targetUrl 则直达该网页,空串则到列表
  private open(url: string): void {
    const action: Record<string, Object> = {
      'action': 'router',
      'abilityName': 'EntryAbility',
      'params': { 'targetUrl': url } as Record<string, Object>
    };
    postCardAction(this, action);
  }

  build() {
    Column() {
      Text(this.title)
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
        .width('100%')
        .margin({ bottom: 8 })

      ForEach(this.apps, (a: CardApp) => {
        Row() {
          Text(a.name)
            .fontSize(13)
            .fontColor('#FFFFFF')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Text('›')
            .fontSize(15)
            .fontColor('#FFFFFFCC')
        }
        .width('100%')
        .padding({ top: 7, bottom: 7, left: 10, right: 10 })
        .backgroundColor('#33FFFFFF')
        .borderRadius(8)
        .margin({ bottom: 6 })
        .onClick(() => {
          this.open(a.url);
        })
      }, (a: CardApp) => a.url)
    }
    .width('100%')
    .height('100%')
    .padding(12)
    .alignItems(HorizontalAlign.Start)
    .justifyContent(FlexAlign.Start)
    .backgroundColor('#0A59F7')
    .onClick(() => {
      this.open(''); // 点空白处:打开元服务到列表
    })
  }
}
