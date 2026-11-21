# PocketPad

将 iPhone 变成 Mac 的无线触控板、键盘、媒体/PPT 遥控器与手柄式摇杆。

采用 **原生 Swift macOS 菜单栏服务端 + iPhone 全屏 PWA** 架构：零第三方依赖、无需 Apple Developer 付费账号重签、扫码即连、添加到主屏幕即可全屏长期使用。

## 核心功能

- **多点触控板**
  - 单指加速光标移动、轻点左键、双击/三击、轻点两下按住拖拽、拖拽锁定
  - 双指平滑像素级惯性滚动（支持自然滚动开关）、双指轻点右键、双指捏合缩放（`⌘+` / `⌘−`）
  - 三指上滑调度中心、下滑应用窗口、左右滑切换桌面空间
  - 支持**自动横屏**与竖屏锁定下的**一键旋转横屏**宽幅触控板模式
- **Apple 风格触控轮盘 & Xbox 风格模拟摇杆**
  - 环形触控轮盘支持 4 种模式切换：**快进**（视频/PPT 步进）、**滚动**（带飞轮惯性）、**音量**（旋钮调音量）、**摇杆**（双手手柄式 360° 模拟摇杆控鼠标）
  - 摇杆支持动态落指零点、径向死区、±5° 软轴向微辅助、EMA 低通平滑、外圈渐进加速及 **精准 / 平衡 / 敏捷** 3 档曲线，右侧同步切换左键/拖拽/右键扳机区
  - 方向轻点 + 长按连发、媒体播放、音量/亮度胶囊条、调度中心/搜索/放映/锁屏快捷按钮
- **中文与快捷键输入**
  - 原生支持 iOS 拼音输入法与语音听写，Mac 端通过无损剪贴板原子粘贴（`⌘V` 并自动还原原剪贴板），稳定兼容 Electron、浏览器与中文输入法
  - 粘滞修饰键（`⌘` `⌥` `⌃` `⇧`）、基础功能键、高频 Mac 快捷键与方向键
- **体验与安全**
  - Apple 极简毛玻璃界面（深色玻璃 / 浅色玻璃两套外观）
  - 通过 iOS Safari 原生 `checkbox switch` 调用 **Taptic Engine 线性马达** 触感反馈
  - 单端口 HTTP（自动 `gzip` 压缩）+ RFC 6455 WebSocket（`TCP_NODELAY`），支持 4 位配对码保护与前端页面热加载（`~/Library/Application Support/PocketPad/index.html`）

## 编译与运行

需要 macOS 13+ 与 Xcode Command Line Tools（内置 `swiftc`）。

```bash
chmod +x build.sh
./build.sh
open build/PocketPad.app
```

如需同时安装到指定目录（例如 `/Applications`）：

```bash
./build.sh --install /Applications
```

## 首次使用

1. 启动 `PocketPad.app`，点击顶部菜单栏触控板图标。
2. 点击弹窗内的 **「打开辅助功能设置」**，在「系统设置 → 隐私与安全性 → 辅助功能」中开启 `PocketPad`。
3. 确保 iPhone 与 Mac 处于同一局域网，用 iPhone 相机扫描菜单栏弹窗中的二维码即可自动配对连接；在 Safari 中点「分享 → 添加到主屏幕」即可获得无地址栏全屏体验。

## 目录结构

```text
PocketPad/
├── Sources/
│   ├── main.swift             # 程序入口
│   ├── AppDelegate.swift      # 菜单栏状态项、SwiftUI 弹窗、二维码与权限检测
│   ├── WebSocketServer.swift  # 单端口 NWListener HTTP(gzip) + RFC 6455 WebSocket 服务
│   ├── InputController.swift  # CoreGraphics 鼠标/滚动/剪贴板粘贴/媒体键/Mission Control
│   └── NetworkUtils.swift     # 局域网 IPv4 发现与 CoreImage 二维码生成
├── Resources/
│   └── index.html             # iPhone 全屏触控板、轮盘摇杆与键盘 PWA 前端
├── Info.plist
└── build.sh                   # 一键生成图标、编译、打包并 ad-hoc 签名
```
