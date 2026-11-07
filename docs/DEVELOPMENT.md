# 开发

使用支持 Swift 6、包含 Liquid Glass API 的 macOS SDK 的 Xcode。原生应用部署目标为 macOS 14；Liquid Glass 界面需要 macOS 26+。

打开 `tourXbox.xcodeproj`，或在项目根目录执行：

```sh
swift test
./scripts/build-release.sh
./scripts/package-dmg.sh
```

发布构建默认使用 arm64。其他架构可通过 `ARCHS` 显式指定，但仍需在对应设备验收。脚本生成的应用使用临时签名，未公证。

已有经过验证的应用包时，可以直接打包，避免重新签名已授权构建：

```sh
./scripts/package-dmg.sh /path/to/tourXbox.app
```

## 目录

| 目录 | 内容 |
| --- | --- |
| `Sources/MappingCore` | 配置、手势识别、保持动作账本、颜色算法、摇杆旋钮与宿主协议 |
| `Sources/BrushPad` | GameController、CGEvent、SwiftUI / AppKit、Photoshop 适配 |
| `Tests` | 核心与 macOS 原生状态测试 |
| `Design/AppIcon.icon` | 现代 macOS 应用图标源文件 |
| `Design/Icon/tourXbox.icns` | 应用图标兼容资源 |
| `scripts` | 发布构建与 DMG 打包 |
| `docs/images` | README 使用的真实应用截图 |

构建缓存、安装包、原始验证记录与个人研究资料均不进入 Git。发布包由 Releases 分发。清理 `.build/`、`.build-release/`、`Build/` 或 `DerivedData/` 不影响源码；下一次构建会重新生成。

不要把个人映射、权限数据库、原始系统日志或签名凭据提交到公开仓库。平台迁移见 [PORTABILITY.md](../PORTABILITY.md)。
