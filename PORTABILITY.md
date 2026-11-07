# 跨平台边界

本版本按未来 Windows 开发拆分，但尚未在 Windows 编译或测试，不能保证已经可直接发布 Windows 应用。

## 已经共享的代码

`Sources/MappingCore` 不导入 AppKit、SwiftUI、GameController 或 Carbon。包含映射配置／释放账本、输入门控、HSV／HSL／Lab 近似转换、HSL 三角命中、相对旋钮识别和版本化 Photoshop 请求／响应。

`Package.swift` 在非 macOS 平台只构建 MappingCore 和测试，不构建 Mac 应用。将来可在安装 Swift 6 工具链的 Windows／Linux 上执行 `swift test`；目前仅在此 Mac 执行成功。

## 平台适配层

| 能力 | macOS 当前实现 | Windows 后续实现边界 |
|---|---|---|
| 控制器 | GameController，规范化为按键与 X/Y | Windows.Gaming.Input／GameInput 等适配到同样数值约定，Y 向上 |
| 临时浮窗 | SwiftUI＋非激活 NSPanel | Windows 原生非激活工具窗，单独验证笔输入与 DPI |
| 键盘输出 | CGEvent＋持有者账本 | SendInput 等适配；同样遵守所有者与释放规则 |
| Photoshop | MacPhotoshopTransport：Apple Events＋公开脚本接口 | 实现 PaletteHostTransport；建议共用 UXP 插件的 JSON 协议，不依赖 Mac 脚本机制 |
| 权限 | 辅助功能／事件发送／自动化 | 根据 Windows 的权限与目标进程完整性层级处理，不照搬 TCC |

`PhotoshopColorBridge` 负责队列合并、会话过期与文档检查；`MacPhotoshopTransport` 才生成和发送 Apple Events。替换连接方式不需要改颜色或摇杆算法。原生窗口、权限、系统输入和性能仍须各平台分别实现与验收。

## 跨语言连接协议

`PaletteHostRequest`／`PaletteHostReply` 使用 JSON，版本 1，字段为 `version`、`session`、`sequence`、`operation`、`documentID`、`color`，响应另含 `status` 和 `profile`。write 要求有效文档 ID 和有限、合法的 RGB 分量；响应必须回显会话与序号。进程 ID、NSColor、窗口句柄和快捷键虚拟码不跨这个接口。

配置 schema 3 以按键、手势和组合成员构成独立绑定身份。同一物理按键可同时配置多个手势，路由输出绑定 ID，再由各平台输出层处理；不能退回以物理按键作唯一键。

映射文件的 Shortcut 另有明确 `encoding`：旧文件缺失时按 `macOSVirtualKey` 解码；`usbHID` 留作平台中立的物理键编码。Mac 输出层会拒绝尚未转换的 USB HID 绑定，避免把同一个数字误当 macOS 虚拟键。未来 Windows 输入适配器也必须显式转换，不能把现有 Mac 键码直接交给 SendInput。

RGB 当前为归一化三分量，色彩算法以 sRGB 为基准。Photoshop 文档配置文件随响应返回，但本版本没有实现任意 ICC／CMYK／HDR 的完整色彩管理；不能把 RGB 标签当作所有颜色空间通用的保证。Lab 平面为 D65 自研近似，不声称等于 TourBox 私有算法。

未来 Windows 界面若用 C#／C++，可实现同一 JSON 协议；若要直接复用 Swift 核心二进制，需要再提供并验证稳定 C ABI 包装。当前没有交付该包装，不承诺能直接从 WinUI 调用 Swift 内部类型。

## 一致性验收

共享测试覆盖 HSV／HSL 往返、Lab 往返、色域掩码、三角域反变换、协议编解码与拒绝非法请求、静止摇杆不重复、回中重建、旧映射保持。Windows 应首先跑这些测试，再做输入、窗口、压感和宿主连接实测。

Mac UI 的面板宽度为 270×size＋32 逻辑点，高度为 270×size＋116（色轮）或＋154（同明度）逻辑点；Windows 采用等价的独立像素与 DPI 缩放，不能直接照抄屏幕物理像素。截图的细微字体／阴影差异不应改变命中域和动作语义。
