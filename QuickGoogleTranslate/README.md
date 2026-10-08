# 翻译应用开发说明

用户功能与安装方法见 [仓库首页](https://github.com/Foolishgod/quick-google-translate#readme)，构建与检查方法见 [构建说明](https://github.com/Foolishgod/quick-google-translate/blob/main/docs/BUILDING.zh-CN.md)。

- 普通翻译与专用后台浏览器高级翻译，不使用 Google Cloud 接口或 API 密钥。
- 两组独立全局快捷键：普通翻译与中文 → 英文；注册失败保留原组合，两组不能重复。
- 原文区支持手动输入、编辑与粘贴；⌘ Return 翻译，Return 换行。输入变化会取消旧请求并关闭旧结果的复制按钮。
- 单词向 Google 请求词典释义，按词性分组；缺少释义或可选查询失败不影响已获得的译文。
- 原文与译文保留段落、列表、缩进和代码结构，浮窗支持置顶和外部点击隐藏。
- 卸载工具只将用户选择的文件移到废纸篓。仍可选择清理旧版本遗留的连接密钥；翻译应用不读取该密钥。

构建入口为 `build.sh`。发布前递增版本与构建号，保留历史归档，运行 `release.sh` 校验完整包、差分还原及更新签名。`publish.py` 为每个版本创建独立 `v版本号` Release，只上传当前版本的文件，上传完成后公开发布并更新签名更新源。首页 README 介绍功能和使用方法，变化记录放在对应 Release。

后台浏览器使用独立 Chrome 资料，登录在专用窗口完成。真实 Google 账号下的高级模型完整流程仍待验证，不应把模拟页面检查当成账号验证结果。
