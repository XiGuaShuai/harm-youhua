import { FormExtensionAbility, formBindingData, formInfo } from '@kit.FormKit';
import { Want } from '@kit.AbilityKit';

// 简洁启动卡:卡片只显示「网页加速」+ 提示,点击打开元服务。不罗列具体应用。
export default class EntryFormAbility extends FormExtensionAbility {
  private buildData(): formBindingData.FormBindingData {
    const data: Record<string, Object> = { 'title': '网页加速', 'subtitle': '点击打开网页应用' };
    return formBindingData.createFormBindingData(data);
  }

  onAddForm(want: Want): formBindingData.FormBindingData {
    return this.buildData();
  }

  onUpdateForm(formId: string): void {
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
