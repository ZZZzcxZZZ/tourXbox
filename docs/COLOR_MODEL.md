# 同明度调色盘模型与修复依据

## 问题

旧版在 Lab 的固定 L* 平面生成 RGB，再在完整模式对 RGB 分量分别截断到 0…1。超出 sRGB 色域时，这会改变颜色实际的相对亮度。聚焦模式虽拒绝超色域点，却把不可选区域绘制成固定 0.6 灰；该灰与当前明度无关。显示缓存把 L* 按 0.5 取整，而点击计算使用原值，造成显示与选色偏差。明度条沿固定 a*/b* 到黑白端点时也会遇到超色域截断或不可选区域。

## 新模型

输入和输出为归一化 sRGB。先解码 sRGB 的传递函数，在**线性 RGB** 中约束 CIE 相对亮度 Y。CIELAB L* 只用于明度刻度与平面坐标，并非 HSL L 或 HSV V。

由 L* 求目标 Y，把 Lab 候选色转换为线性 RGB，减去其实际 Y 得到加权和为零的彩色偏移。以 (Y,Y,Y) 为中性起点，对三个偏移施加相同的最大可用缩放系数，使全部分量落入 RGB 立方体。最后编码回 sRGB。

这是一种保亮度的线性 RGB 中性射线投影，**不是** Lab 恒色相彩度压缩，也不是 CSS 推荐的通用色域映射算法。目标是优先严格保住绘画中的黑白关系；超色域时色相／彩度可能改变。逐通道硬截断仅用于最后的浮点舍入保护。

聚焦模式保留原有可选域；不可选区域用同一 Y 的中性灰表示。完整模式映射所有点。色板、命中测试、手柄调整与明度条共用 MappingCore 的计算。去除 L*、a*、b* 的缓存取整。缓存仍有 20 项上限。

## 验证与限制

7 个明度平面、每平面 33×33 点，共 7623 个测试点：旧逐通道截断的最大 Y 误差为 0.7317694842；新映射的最大误差为 4.44e-16（浮点数精度）。这些是浮点输出的误差，屏幕 8 位栅格量化会产生更小但非零的显示误差。

其他测试覆盖聚焦域、黑白端点、中性灰、原色往返和饱和色明度条的单调性。73 项自动测试通过。270×270 完整平面 Debug 核心计算约 53ms，独立 Release 优化测量约 10–15ms；该值包含逐点 Swift 调用，不代表 UI 帧率。

相等 Y 不保证不同饱和度在所有观察条件下主观同样明亮。当前模型以 sRGB / D65 为基准，不保证与 Photoshop 自定义黑白转换、HSL 去色或任意文档 ICC 变换相同；Photoshop 桥接已增加文档 ICC 到 sRGB 的双向 ColorSync 转换；Display P3、sRGB 已有自动回归，其他已安装且名称匹配的 RGB 配置文件可转换，但尚未逐一实测。未知配置文件会报错，避免静默按 sRGB 处理。P3 中超出 sRGB 的采样色会在保持 Y 的条件下映射回调色盘色域，不能保留完整 P3 彩度。本版本不声称复刻 TourBox 的私有公式。

## 官方资料

- [TourBox 动态调色盘介绍](https://www.tourboxtech.com/en/news/dynamic-color-picker-for-photoshop.html)：同明度及完整／聚焦模式的产品行为，没有公开数值算法。
- [W3C 相对亮度定义](https://www.w3.org/WAI/WCAG22/Understanding/non-text-contrast)：先线性化 sRGB 再求亮度；本实现沿用 CIE 矩阵的更精细权重并归一化。
- [CSS Color 4 色彩转换与色域映射讨论](https://www.w3.org/TR/css-color-4/)：区别 Lab、Oklab、亮度与色域裁剪的影响。本实现使用针对同明度约束的投影，不等同于 CSS 算法。
- [Apple SMAppService.mainApp](https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp)：注册主应用为登录项。
- [Apple register()](https://developer.apple.com/documentation/servicemanagement/smappservice/register())：注册后在之后登录时启动，受系统批准约束。

## 本机交互验收

固定安装路径 0.23.0 的 AX 与事件发送检查均为 true。开启后台运行后，从原生 File → Close 关闭主窗口：主窗口不可见，激活策略为 accessory，同一 PID 保留；重新打开可恢复窗口。关闭后台选项后关窗，固定版进程退出。测试后恢复后台选项开启、登录自启关闭，未实际注册系统登录项，也未注销／重启用户会话。

最终构建向 Photoshop 请求读取时，当前已无打开文档，应用正确显示“Photoshop 尚未打开文档”；本轮未对最终构建完成真实 RGB 文档写色、Wacom 绘画和手柄持续调色的端到端验收。Display P3 转换已通过系统 ColorSync 数值往返测试。
