# Codex连续表达助手

在当前工作中边操作、边表达，把语音与选中的文字、链接、图片和文件整理为完整任务，编辑后发送到选定的 Codex 对话，减少在工作应用与 Codex 之间反复切换。

目前是 macOS 本地验证版本，支持 Chrome、Finder、语音与素材时间关联、可编辑 Prompt、固定目标对话和核对后的自动提交。右侧栏可自动隐藏。

## 使用流程

1. 下载安装用户请先按下方“试用版”说明安装；源码开发者打开 `build/Codex连续表达助手.app`。
2. 首次在 `chrome://extensions` 开启开发者模式，加载 `~/Library/Application Support/ContextCapturePrototype/BrowserExtension`；界面提供扩展管理和扩展文件夹入口。
3. 按系统提示允许麦克风、辅助功能与 Finder 自动化权限。已有固定签名身份的更新沿用该身份，不重置权限。
4. 按 **⌘⇧Return** 开始表达，边说边操作：网页文字直接拖选；链接与图片按住 **Option 点击**；Finder 中选择文件。
5. 再按 **⌘⇧Return** 结束表达。整理结果在侧栏中显示，可以编辑；有歧义的要求提供推荐选项与自行填写。
6. 选择目标 Codex 对话，点击“发送到 Codex”。目标按完整 ID 固定保存，只有主动更换才改变。

发送前核对当前对话 ID、输入框、正文和焦点。已有不同草稿时停止，不覆盖、不清空；发送结果不明确时不自动重试。收到与正文匹配的新消息后才显示成功并收起侧栏。正文没有明确用途的素材不发送。

## 试用版

可从 [GitHub Releases](https://github.com/superflusuperflu-JJJ/codex-continuous-expression-assistant/releases) 下载 **未经过 Apple 公证的预发布测试版**。支持 Apple Silicon、macOS 26+、Chrome 和已登录的 Codex 桌面端；不需要 Python、Swift、Node 或 Homebrew。

安装包内含完整功能、运行组件与首次设置向导。首次打开可能需要你亲自在“系统设置 → 隐私与安全性”中选择“仍要打开”，并按向导允许麦克风、辅助功能、Finder 和扩展权限。此版本没有 Developer ID 签名和 Apple 公证，另一台 Mac 的完整实测尚未完成；公司管理的 Mac 可能无法放行。请先阅读[安装与试用说明](docs/trial-installation.md)，再自行决定是否参与测试。

开发者可使用 `python3 tools/release.py prepare` 准备独立暂存包；该命令不安装应用、不注册本机桥接，也不使用本机原型签名身份。

## 环境与构建

- Apple Silicon、macOS 26+、Swift 6.2+。
- Python 3、Node 22 或以上用于工具和检查。
- 已登录的 Codex 桌面端与 Codex CLI、Chrome。
- 本机独立的代码签名身份；证书、私钥、钥匙串和真实配置不随源码分发。

构建脚本要求先配置本机签名身份；具体机制见 [架构与权限](docs/architecture.md) 和 `tools/local_signing.py`。不要复制其他机器的私钥或签名配置。仓库提供源码及未公证的早期测试安装包，尚未提供经过公证的通用安装包。

```sh
python3 tools/build.py
zsh tools/check.sh
```

`tools/build.py` 构建应用并注册用户级 Chrome Native Messaging 宿主；不会自动批准系统权限或自动加载扩展。`--stage-only` 只输出暂存应用。

## 数据与隐私

- 只在用户开始表达后采集，没有全天录屏。
- 录音、转写、所选文件副本和网页截图存于 `~/Library/Application Support/ContextCapturePrototype/Sessions/`。
- 默认使用本地中文 SpeechTranscriber。结束后的语义整理调用已登录的 Codex CLI，使用网络和账号额度；输入包括转写、选中文字、链接、素材名称与相对路径，整理阶段不上传附件字节。
- 用户点击发送后，明确引用的文件和图片通过本机素材副本路径交给 Codex。远程设备不能直接使用这些本机路径。
- 网页采集需要较广的网页权限；扩展和本机桥接仍以表达是否开启为采集条件。
- 仓库只包含源码、合成测试样例和公开说明；不包含真实会话、个人实测记录、签名私钥或本机授权配置。测试对话 ID 为人工构造的样例。

## 当前边界

复杂网页、Canvas、应用权限与 Codex 桌面版本变化可能影响兼容性。网页图片可能是页面截图而非原图；文件夹不递归复制，较大的文件可能仅保留来源。语音与语义整理可能出错，应核对最终 Prompt。

[检查说明](docs/testing.md) 区分自动化检查与人工验证。检查通过不等于任意口音、网页和桌面状态下都能准确处理。

## 历史说明

公开历史从经过隐私清理的源码快照开始。早期开发历史和个人实测文档保留在私有开发归档，不进入公开仓库。
