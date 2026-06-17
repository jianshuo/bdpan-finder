# 百度网盘 Finder (BdpanFinder)

> 像 OneDrive 一样，在 Mac 的 Finder 里直接用百度网盘。

百度网盘会出现在 Finder 左侧边栏的「位置」里，和 iCloud 云盘、OneDrive 并排，可以直接浏览、下载、上传文件。

## 安装

1. 下载 `百度网盘.dmg`，双击打开。
2. 把「百度网盘」拖进「应用程序」文件夹。
3. 从「应用程序」启动「百度网盘」。

应用已用 Apple Developer ID 签名并经过 Apple 公证，正常双击即可打开，不会有「身份不明的开发者」提示。

> 不需要单独安装 bdpan 命令行工具 —— 它已经打包在应用里。

## 首次使用

第一次启动会弹出登录窗口：

1. 点「打开百度授权页」，用你的百度账号登录并同意授权。
2. 授权后页面会显示一段「授权码」，复制它。
3. 粘贴回窗口，点「完成登录」。

登录信息只保存在本机。登录成功后，「百度网盘」就出现在 Finder 边栏里了。

之后想换账号或重新登录，点菜单栏的网盘图标 →「登录 / 重新登录…」。

## 系统要求

- macOS 12.0（Monterey）或更新
- Apple Silicon（M 系列芯片）—— 当前打包的 bdpan 为 arm64

## 从源码构建（开发者）

需要 Xcode 和 [xcodegen](https://github.com/yonaskolb/XcodeGen)。

仅本地构建运行：

```bash
xcodegen generate
open BdpanFinder.xcodeproj   # 在 Xcode 里 ⌘R 运行
```

打出可分发、已签名并公证的 DMG（一条命令）：

```bash
export SIGN_IDENTITY="Developer ID Application: 你的名字 (TEAMID)"
export NOTARY_KEY=~/.appstoreconnect/private_keys/AuthKey_XXXX.p8
export NOTARY_KEY_ID=XXXX
export NOTARY_ISSUER=<App Store Connect Issuer ID>
./scripts/build-dmg.sh        # 产物在 dist/百度网盘.dmg
```

`NOTARY_*` 不设置时，脚本只构建+签名+打包，跳过公证（DMG 本机可用，但在别人 Mac 上 Gatekeeper 会拦）。

> ⚠️ 应用文件夹名必须是 `百度网盘.app`：`fileproviderd` 用 app 包文件夹名作为 Finder 边栏的标签。`build-dmg.sh` 和 GitHub Actions release 流程均已处理好。

## 架构

- **BdpanFinder**（主 App，非沙箱）：菜单栏图标，注册 File Provider Domain，处理首次登录引导。
- **BdpanFinderExt**（File Provider 扩展，沙箱）：响应 Finder 的文件请求，调用打包在内的 bdpan CLI。
- **共享登录态**：bdpan 的登录配置存放在扩展的数据容器里（`~/Library/Containers/com.wangjianshuo.BdpanFinder.Extension/Data/bdpan/`）。非沙箱的主 App 写入、沙箱扩展读取 —— 登录态共享不依赖 App Group 共享容器（两个 target 都含有 App Group 授权是 File Provider framework 的要求，用于 `NSExtensionFileProviderDocumentGroup`，不用于认证状态的传递）。

详见 [ARCHITECTURE.md](ARCHITECTURE.md)。

## 调试

用 `BDPAN_DEBUG=1` 启动可在扩展容器里写一份操作日志（默认关闭）：

```bash
BDPAN_DEBUG=1 open /Applications/百度网盘.app
```

## 已知限制

- 仅 Apple Silicon（bdpan 二进制为 arm64）。
- 仅挂载百度网盘应用空间 `/apps/bdpan/` 下的文件，不是整个百度网盘根目录。
- 大文件下载暂无进度条。
