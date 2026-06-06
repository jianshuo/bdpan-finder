# 百度网盘 Finder (BdpanFinder)
> 像 OneDrive 一样在 Finder 中直接使用百度网盘

## 效果
- 百度网盘出现在 Finder 左侧边栏「位置」下
- 可以直接浏览、下载、上传文件
- 通过菜单栏图标管理

## 前置条件
- macOS 12.0+ (Monterey 或更新)
- Xcode 14+
- bdpan 已安装并登录（运行 `bdpan whoami` 确认）
- 路径: `/Users/jianshuo/.local/bin/bdpan`

## 构建步骤
1. 打开 Xcode：`open /Users/jianshuo/code/bdpan-finder/BdpanFinder.xcodeproj`
2. 在 Project Settings 中设置你的 Team（签名）
3. 同时为 BdpanFinder 和 BdpanFinderExt 两个 target 设置 Team
4. Product → Build (⌘B)
5. Product → Run (⌘R)

## 使用方法
1. 运行 BdpanFinder app
2. 等待几秒，Finder 左侧出现「百度网盘」
3. 点击即可浏览文件
4. 下载：双击文件
5. 上传：拖拽文件到文件夹

## 架构
- **BdpanFinder**（主 App）：注册 File Provider Domain，菜单栏图标
- **BdpanFinderExt**（File Provider Extension）：处理 Finder 的文件请求，调用 bdpan CLI

## 已知限制
- 需要手动设置代码签名（Xcode 中设置 Team）
- 大文件下载无进度条（Future TODO）
- 暂不支持移动/重命名（Future TODO）

## 当前构建状态

⚠️ 需要在 Xcode 中手动修复以下问题：

- `"BdpanFinderExt"` requires a provisioning profile — 需要在 Signing & Capabilities 中为该 target 选择开发团队和 provisioning profile
- `"BdpanFinder"` requires a provisioning profile — 需要在 Signing & Capabilities 中为该 target 选择开发团队和 provisioning profile

**修复方法：** 在 Xcode 中打开项目，选中每个 target（BdpanFinder 和 BdpanFinderExt），进入 Signing & Capabilities，勾选 "Automatically manage signing"，并在 Team 下拉框中选择你的 Apple 开发者账号。设置完成后即可正常构建运行。
