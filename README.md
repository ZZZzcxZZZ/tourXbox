# tourXbox

用 Xbox 手柄辅助 macOS 绘画的原生 Swift / SwiftUI 工具。支持按键映射、保持快捷键、双击、双击后长按、组合键和动态调色盘。

## 下载与使用

![调色盘设置](docs/images/palette-settings.png)

从 [Releases](https://github.com/ZZZzcxZZZ/tourXbox/releases) 下载 DMG，将 tourXbox 拖入 Applications，再启动应用。0.22.0 提供 Apple Silicon（arm64）构建，部署目标为 macOS 14；Liquid Glass 界面需要 macOS 26 或更高版本。其他系统版本尚未完成本机验收。

当前发布包使用临时签名，未通过 Developer ID 签名与 Apple 公证。构建更新后，系统可能要求重新确认辅助功能授权。已有用户应继续使用同一个安装路径并退出旧副本。

1. 通过系统蓝牙连接受 macOS 支持的 Xbox 手柄。
2. 在“设备与权限”中检查当前构建的事件发送许可，并启用映射。
3. 点击手柄图上的按键可配置动作；设置面板内可编辑手势和组合键。设备页只保留连接、发送权限和数位笔兼容设置。
4. 默认 **LT 长按保持 Option 吸色；双击后长按**：按一下松开，再次按下并保持，呼出动态调色盘；松开结束。左摇杆转圈调色，X 切主模式，Y 切子模式。
同一个按键可以保留多个手势功能，通过“当前功能”选择要编辑的条目，“添加功能”添加独立手势或组合。LT 首次长按等待180毫秒后吸色；第一次短按不发送 Option，第二次按住仅进入调色盘。

Photoshop 调色需要在调色盘设置中连接宿主，并允许相应自动化访问。

调色盘样式与完整／聚焦范围均提供可点击图例。预览可用右上角关闭按钮、Esc 或再次点击预览按钮结束。

调色盘提供 HSV / HSL 色轮、三角形与方形选择、同明度近似平面、固定与预览。当前 Photoshop 连接支持 RGB 文档；同明度基于 CIELAB 近似，不等同于 TourBox 的私有算法。

## 开发

使用支持 Swift 6 的 Xcode 工具链及包含 Liquid Glass API 的 macOS SDK。打开 `tourXbox.xcodeproj`，或使用：

```sh
swift test
./scripts/build-release.sh
./scripts/package-dmg.sh
```

`build-release.sh` 默认构建 arm64；需要其他架构时显式设置 `ARCHS` 并完成对应机器验收。发布脚本也可以接收已经验证的应用包路径，避免重新签名已授权构建：

```sh
./scripts/package-dmg.sh /path/to/tourXbox.app
```

- `Sources/MappingCore`：配置、长按持有者账本、手势、颜色算法、摇杆旋钮与宿主协议。
- `Sources/BrushPad`：GameController、CGEvent、AppKit / SwiftUI 和 Photoshop macOS 适配。
- `Tests`：核心与原生事件状态测试。
- [PORTABILITY.md](PORTABILITY.md)：Windows 迁移边界；尚未提供 Windows 应用。

## 0.22.0 验证范围

59 项自动测试通过。新增测试覆盖同键手势互斥、旧配置迁移、1000次保持与同键独立释放。本机验证了设置面板尺寸适配、分类切换、动画及本地 F18 按下 / 释放；修复了事件监听停用通知反馈循环。映射启用、无手柄输入的短时空闲采样 0.21 版本 CPU 为 0.0%、0.1%、0.1%、2.1%，内存约 79 MB；0.22 的最终记录保留在本地验证目录。短时空闲采样不能代表实际绘画性能。

本轮未完成真实 Xbox 持续输入、Wacom 高频绘画、Photoshop 选色与断连、长时内存稳定性和其他硬件 / 系统组合验收。原始本机日志保留在本地，不纳入公开仓库。

## 素材说明

控制器照片来自 Microsoft / Xbox 官方产品素材，原始链接和校验值见 [SOURCES.json](Sources/BrushPad/Resources/SOURCES.json)。相关照片与商标归其各自权利人所有；本项目与 Microsoft、Xbox、TourBox 或 Adobe 无隶属或官方背书关系。
