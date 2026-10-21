# Codex连续表达助手 · 小范围试用

## 安装前

需要 Apple Silicon Mac、macOS 26 或以上、Chrome，以及自己的 Codex 桌面端与可用账号。无需安装 Python、Node、Swift 或 Homebrew。语义整理使用你的 Codex 账号与额度。

正式安装包需要 Developer ID 签名、Apple 公证及另一台 Mac 验收。名称带 STAGING-NOT-FOR-DISTRIBUTION 的文件是开发暂存产物，尚不适合普通下载安装；不要关闭 Gatekeeper 或删除隔离属性来绕过这个发布条件。

## 安装与首次设置

1. 下载已标注通过分发验证的 DMG，打开后将应用拖到 Applications。
2. 推出安装磁盘，从「应用程序」打开 Codex连续表达助手。首次出现「安装与连接」窗口。
3. 安装或更新 Codex 桌面端，并登录自己的账号。向导自动发现组件；如果未发现，可以用「其他操作」手动选择 Codex 可执行文件。
4. 在向导中打开扩展管理，开启 Chrome 的「开发者模式」，点击「加载已解压的扩展程序」，选择向导打开的「扩展文件夹」。确认网页读取权限，再点「打开试用页面」，等待向导显示真实连接。
5. 分别点「允许」启用辅助功能、麦克风和 Finder 文件选择。系统授权必须由你亲自确认。若之前拒绝，可从向导打开相应系统设置再开启。
6. 点「准备模型」，等待系统中文语音模型下载完成。
7. 全部检查就绪后点「完成设置，开始使用」。可随时从菜单栏重新打开「安装与连接向导」。

语音、浏览器文字/链接/图片、Finder 文件、时间关联、Prompt 整理与编辑、推荐选项、固定目标对话、自动发送与接收核对、侧栏自动隐藏、会话重开和素材导出均保留。

## 第一次完整试用

按 ⌘⇧Return 开始表达。在 Chrome 拖选文字并说「把这段精简一下」，Option 点击图片或链接说明用途，在 Finder 选择一个文件说明用途。再次按快捷键结束，核对并编辑 Prompt。选定专用试用对话，再点击「发送到 Codex」。确认目标正确、素材用途正确、Codex 开始处理且侧栏收起。

再做一次中途编辑 Prompt 的发送，检查没有光标跳转、没有重复提交、已有不同草稿不会被覆盖。最后重启应用，检查目标与侧栏设置仍保留。

## 更新与支持

退出当前副本后再替换应用。两个副本不会同时占用采集连接。首次更换签名身份可能需要一次重新授权；保持后续正式签名身份稳定可避免开发阶段临时签名造成的问题。

个人录音、素材、目标对话及诊断都保存在自己的用户目录中，不随应用或源码上传。反馈时先描述现象；需要日志时请先检查并移除个人内容，不要提交整个会话目录。

## 发布者操作

```sh
python3 tools/release.py prepare
python3 tools/release.py sign --identity 'Developer ID Application: YOUR NAME (TEAMID)'
python3 tools/release.py notarize --keychain-profile YOUR_EXISTING_PROFILE
python3 tools/release.py package
```

内置 Python 的标准库、pip 及原生依赖许可证随应用保留；原生依赖声明来自固定版本的上游完整构建，清单与摘要位于 `Resources/PythonLicenses/inventory.json`。

签名与公证使用发布者自己在本机配置的身份及钥匙串凭据；不得把账号密码、私钥、钥匙串文件或 profile 内容提交到源码。需要 Apple Developer Program 会员，官方入口：https://developer.apple.com/programs/enroll/

发布前需对已公证的候选包在另一台 Mac 完成上述整轮验收。验收后用 `python3 tools/release.py accept-clean-mac --acceptance-report REPORT.json` 记录结果。报告包含候选版本、整个应用包的规范化 SHA256（`release.py status` 可查看） 和 `tools/release.py` 中全部 `ACCEPTANCE_CHECKS` 的真实完成结果；版本、摘要或功能检查不符会拒绝。未完成时包仍标注暂存，不上传公开 Release。即使签名/公证通过，也不等于采集及 Codex 兼容性已经通过另一台 Mac 验证。
