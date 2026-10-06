# 划词谷歌翻译卸载工具 1.0

这是专门清理“划词谷歌翻译”的独立 macOS 应用，无需安装浏览器扩展。支持 Apple Silicon、macOS 13 或更新版本。

## 使用

1. 解压并打开“划词谷歌翻译卸载工具.app”。无需放进“应用程序”。随 1.5.2 及以后构建的版本使用固定个人签名，尚未经过苹果公证；系统阻止打开时，可在“系统设置 → 隐私与安全性”允许打开。
2. 检查找到的项目，并勾选要移除的内容。默认勾选所有已找到的项目。
3. 如果应用在下载文件夹或其他位置，点击“选择应用…”手动添加。工具只接受身份标识为 `local.quickgoogletranslate.mac` 的应用，不接受其他软件或应用的符号链接。
4. 点击“卸载所选项目…”，查看确认信息，再点击“卸载”。程序会先退出翻译应用及它专用资料目录对应的 Chrome 进程，再清理所选项目。文件移入废纸篓，不自动清空废纸篓；如选择了 Google Cloud 密钥，该密钥将永久删除。
5. 点击“打开辅助功能设置”，手动移除“划词谷歌翻译”及旧的 QuickGoogleTranslate 条目。若曾安装 1.3 的配套 Chrome 扩展，请在 Chrome 的扩展管理中移除它。浏览器扩展安装状态不由此工具修改。

清理完成后可关闭并删除卸载工具及下载的安装包。需要彻底删除已移入废纸篓的文件时，请自行检查后清空废纸篓。

## 查找范围

自动检查 `/Applications`、`~/Applications` 中的应用以及当前运行的应用位置。不会递归搜索整个磁盘，也不会扫描同步的项目源文件、下载包和备份；其他位置的应用需手动添加。

仅在存在时列出这些确切的应用资料路径：

- `~/Library/Application Support/QuickGoogleTranslate`：专用 Chrome 资料（包含 Google 登录状态、网站记录和缓存）及旧版扩展副本。
- `~/Library/Preferences/local.quickgoogletranslate.mac.plist`：快捷键、语言、连接设置。清理时同步移除系统缓存的该应用设置。
- `~/Library/Caches/local.quickgoogletranslate.mac`：网络缓存。
- `~/Library/HTTPStorages/local.quickgoogletranslate.mac` 及同名 `.binarycookies` 文件：网络资料。
- `~/Library/Cookies/local.quickgoogletranslate.mac.binarycookies`：可能存在的旧版 Cookie。
- `~/Library/WebKit/local.quickgoogletranslate.mac`：可能存在的网页资料。
- `~/Library/Saved Application State/local.quickgoogletranslate.mac.savedState`：窗口状态。

钥匙串仅检查并删除服务为 `local.quickgoogletranslate.mac`、账号为 `google-cloud-key` 的通用密码条目，不读取密钥内容。钥匙串锁定或权限不足时，操作可能失败；结果会注明未删除项目。

不会清理日常 Chrome 个人资料、Chrome 本体及浏览器共用钥匙串项目。结束浏览器前必须匹配完整的专用资料参数；不使用按浏览器名称批量结束进程的方式。文件清理前复核应用身份和固定路径；不能写入的项目会保留，并在结果中说明。

## 验证范围

已完成编译、签名校验、原生界面预览和临时目录中的清理测试。测试覆盖应用去重、拒绝其他应用、路径替换、身份变化、日常 Chrome 保留、专用浏览器参数匹配、未选密钥保留、符号链接、权限错误及可恢复文件移动。清理测试关闭真实设置同步、禁用真实钥匙串访问，使用单独的模拟废纸篓。另已检查测试进程自身参数的实际读取。

没有为了测试而卸载现有软件。真实机器上的受保护目录权限、钥匙串访问及完整 Chrome 进程退出流程仍需实际使用确认。遇到未删除项目，可调整对应文件权限或关闭相关窗口后重新扫描重试。

## 构建

需要 Apple Command Line Tools，执行 `zsh build.sh`。无第三方依赖、无需网络连接。输出原生 arm64 应用及包含使用说明的安装包。
