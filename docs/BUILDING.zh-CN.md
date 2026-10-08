# 从源码构建

目标环境：Apple Silicon Mac、macOS 13 或更新版本。需要 Apple Command Line Tools、Python 3；JavaScript 和浏览器模拟测试另需 Node.js 与 npm。无需完整 Xcode。以下命令均从仓库根目录开始。

## 准备依赖与个人签名

```sh
cd QuickGoogleTranslate
python3 setup-dependencies.py
mkdir -p .build/module-cache
swiftc -O -module-cache-path .build/module-cache Signing/CreateIdentity.swift -o .build/create-signing-identity -framework Security
.build/create-signing-identity --create Signing
zsh build.sh
```

下载脚本只获取 Sparkle 2.10.0 官方发行包，并核对固定 SHA256。下载内容保存在被 Git 忽略的 `Vendor/`，许可随应用复制。网络无法访问 GitHub 时需先解决连接问题；脚本不跳过校验。

签名设置会在你的登录钥匙串中建立或复用个人代码签名身份；文件只保存公开证书与指纹，个人配置不会提交到仓库。私钥不导出。以后在同一台构建机器上继续使用这份身份，不要每次生成新的证书，否则仍可能需要重新授予辅助功能权限。这个身份不是 Developer ID，也没有苹果公证。

构建产物是 `QuickGoogleTranslate/dist/划词谷歌翻译.app`，同时生成安装 ZIP，并编译相邻模块的卸载工具。首次打开和取词仍需在系统设置中允许打开、授予辅助功能权限。

你自行编译的版本使用自己的签名，和发布页里的维护者版本身份不同。切换版本时可能需要重新授权。原始更新源指向维护者的公开发布页；如果你制作并分发自己的改版，应配置自己的更新源和更新签名身份。

## 运行检查

回到仓库根目录执行：

```sh
zsh scripts/checks.sh
```

它检查翻译解析、权限判断、临时目录中的卸载清单、页面模拟、普通翻译服务的多释义与取消流程，以及按版本发布的失败恢复、文件防覆盖和历史更新链接保留。发布检查使用模拟 GitHub 与签名工具，不创建真实 Release 或访问签名密钥。测试使用临时或模拟数据；不登录 Google、不卸载已安装的软件，也不修改系统辅助功能权限。

键盘界面测试和浏览器控制模拟需要当前 Mac 可运行原生图形应用，本机执行：

```sh
npm ci
zsh scripts/checks.sh --native
```

这会增加快捷键录入/注册检查、签名身份兼容检查和本机模拟浏览器通信。快捷键测试可能显示一个临时窗口；不会更改你保存的快捷键或系统快捷键。如果部分组合被其他软件占用，会报告实际占用情况。

已构建应用时还会启动一个独立临时前台窗口，检查翻译浮窗的实际显示顺序、源应用焦点、自动隐藏、置顶、选区、无选区手动输入与中译英行为。完成后关闭临时窗口并恢复原前台应用。HTML 格式检查使用本地结构解析，不依赖系统 HTML 转换服务。

模拟检查通过不代表真实 Chrome 登录、高级翻译和辅助功能授权在所有 Mac 上均已验证。这些行为仍需实际应用测试。

双快捷键测试会通过 Carbon 事件验证两个方向分别触发；手动输入检查涵盖空文本、长度限制、修改后的迟到结果、重试和方向切换。所有这些回归检查均使用固定或模拟内容。

已安装 Google Chrome 时，还可运行真实浏览器的本地页面检查：

```sh
zsh scripts/checks.sh --chrome
```

使用独立临时浏览器资料，所有页面请求由本地测试内容拦截，不登录 Google 或使用日常 Chrome 资料。验证输入事件、模型切换、多行文字、连续翻译无额外加载以及取消旧脚本。

## 发布与更新

个人构建不需要运行 `release.sh` 或 `publish.py`。这两个脚本供原仓库维护者使用，需要钥匙串中的更新签名身份，以及有权访问对应 GitHub 仓库的 `gh` 登录。

每个新版本以 `v版本号`（如 `v1.5.7`）创建独立 Release，仅上传该版本的完整包和增量包，版本变化写在对应的 Release 说明里。先上传到草稿，完整上传后公开发布，最后更新签名更新源。旧 `updates` Release 及历史下载链接保留。README 只介绍功能、安装和使用，不写版本更新日志。

发布新应用时必须递增 `CFBundleVersion` 与版本号，保留历史发布归档，验证完整包和增量包，再发布签名更新源。已发布的同版本资产不能被覆盖。发布应用更新默认不会重写仓库首页 README，需要同步首页时显式传入 `--sync-readme`。应用源码同步另行提交，不包含构建产物和个人签名资料。

## 目录对应什么

- `QuickGoogleTranslate/Sources`：翻译应用、快捷键、权限、后台浏览器和更新逻辑。
- `QuickGoogleTranslate/BrowserTranslate.js`：从专用翻译页面读取结果。
- `QuickGoogleTranslate/Tests`：应用与页面的回归检查。
- `QuickGoogleTranslate/Signing`：个人签名工具源码；个人证书配置被忽略。
- `QuickGoogleTranslate/ChromeExtension`：旧版扩展参考与测试；当前应用不需要安装它。
- `QuickGoogleTranslateUninstaller`：内置卸载工具的源码与测试。
- `docs`：源码构建与验证说明。
- `licenses`：第三方 Sparkle 许可说明。
