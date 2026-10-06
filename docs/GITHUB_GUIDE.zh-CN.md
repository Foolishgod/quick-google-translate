# 用这个项目学习 GitHub

仓库地址：[Foolishgod/quick-google-translate](https://github.com/Foolishgod/quick-google-translate)。你可以先在网页上练习，再学习本地开发。

## 先认识你现在看到的内容

| 入口 | 用途 | 在这个项目里可以看什么 |
| --- | --- | --- |
| 顶部 Code 页签 | 查看源码和说明文件 | QuickGoogleTranslate、QuickGoogleTranslateUninstaller、docs |
| README | 仓库首页说明 | 安装方法、构建方法、学习指南 |
| 文件页面的 History | 查看某个文件的修改记录 | 谁改了哪些行、什么时候改的 |
| Commits | 查看整个项目的一次次修改 | 一条提交代表保存了一次修改记录 |
| main 分支 | 主版本 | 当前供大家查看和使用的源码 |
| Pull requests | 比较并讨论分支上的修改，然后合并 | 先在分支上练习，再合并到 main |
| Releases | 下载已经编译好的软件 | QuickGoogleTranslate-1.5.2.zip 和更新包 |

顶部的 Code 页签用来浏览文件；绿色的 Code 按钮用来下载或克隆仓库。它们名字一样，但作用不同。

Releases 中的应用安装包用于直接运行软件。GitHub 自动提供的 Source code (zip) 是仓库源码快照，需要按构建说明编译后才能生成应用。

## 第一次练习：改一行学习笔记

这个练习只改文档，不影响翻译功能和在线更新。

1. 登录你的 GitHub 账号，打开仓库。
2. 进入 `docs`，点击 `LEARNING_NOTES.md`。
3. 点击编辑图标（铅笔），在文末加一行：`我已经学会在 GitHub 上修改一个文件。`
4. 点击 `Commit changes`，提交说明填写“补充第一次 GitHub 学习笔记”。
5. 选择创建新分支，分支名填写 `learn-notes`，提交修改。
6. 按页面提示创建 Pull request。标题可写“添加学习笔记”，确认目标分支是 `main`。
7. 在 Files changed 查看新增的那一行。确认后点击 Merge pull request，再确认合并。
8. 回到 Code 页签并选择 main，打开学习笔记，检查新内容。点击 History 看刚才的修改记录。

你在这个练习中经历了：创建分支 → 修改文件 → 提交 → 比较修改 → 合并。以后修复软件问题也可以用同一套流程。

## 想把源码下载到电脑

只想阅读：点击绿色 Code → Download ZIP，解压后查看文件。

想持续修改、同步和保存历史：可以使用 [GitHub Desktop](https://desktop.github.com/)，登录后选择克隆这个仓库。完整源码需要两个模块保持并列，构建步骤见 [BUILDING.zh-CN.md](BUILDING.zh-CN.md)。

| 操作 | 含义 |
| --- | --- |
| Clone | 将仓库和修改历史复制到电脑 |
| Commit | 在本地保存一次修改记录，并写清改了什么 |
| Push | 把本地提交上传到 GitHub |
| Pull | 把 GitHub 上的新提交同步到本地 |

如果你在网页上改过文件，回到本地修改前先同步，避免两边内容不同。学习阶段可以先只用网页完成文档练习。

## 这个仓库中不要误改的文件

`appcast.xml` 是应用检查更新时读取的签名配置，由发布脚本生成。不要拿它做编辑练习，手动改动会使签名失效。

`.gitignore` 告诉 Git 忽略本地缓存、安装包和个人签名配置。源码仓库不保存你的 Google 登录资料、API 密钥或签名私钥。

提交前查看修改清单和差异；每次修改尽量有一个明确目的，例如“修复空格快捷键”或“补充安装说明”。本地编译出新版应用不会自动发布给用户，安装包发布是另一个步骤。

官方入门练习：[GitHub Hello World](https://docs.github.com/en/get-started/start-your-journey/hello-world)。
