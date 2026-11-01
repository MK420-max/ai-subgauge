# Mac 主题与面板检查

final result: passed

范围：当前 Mac 实现的离线渲染、源码连接、单元测试与开发包资源。参考为 `../shared/brand/mockups/mockup-dark.jpg` 和 `mockup-light.jpg`；按用户定稿文字覆盖参考图中的彩色额度条、浅色单按钮栏和过大标题。

- 紧凑标题栏：主题对应 App logo 为 24px；标题与厂商名称均为 16pt；标题下有细分隔线。
- 厂商行：38px 圆角图标容器、名称、剩余额度条，右侧百分比和重置倒计时右对齐；演示/错误信息保留在副文字处。Codex、Grok、Claude 顺序固定，运行与勾选筛选仍由原 store 决定。
- 两主题均有等宽圆角“设置 / 刷新”按钮。按钮接入原设置入口与立即刷新操作；刷新期间禁用重复刷新。
- 浅色沙金至淡紫渐变、柔和波纹与半透明叠层；深色深靛蓝渐变和银蓝细描边。所有新增颜色来自共享 theme.json，额度绿黄红沿用现有规则。
- 核对四种主题/语言组合及其 2× 版本：文字完整，无裁切或重叠，圆角、分隔线和按钮间距一致。标准尺寸 440×350，高清尺寸 880×700。
- 指定 MacOSX26.5 SDK 的 swift build / swift test 通过，226 项测试通过。共享 i18n 检查通过，980 键、961 个引用键。shell 语法与 git diff --check 通过。
- 开发包 codesign --verify --deep --strict 通过；打包资源与 shared 源文件哈希一致；从目录外运行包内离线预览成功。构建脚本先保留旧开发包，避免混合签名资源。

产物：`.build/preview/theme/mac-panel-{light|dark}-{en|zh-Hans}.png`，同名 2× 文件在 `2x/`。构建、测试及打包日志在 `.build/theme-work/`。

边界：没有启动正常 App 流程、登录、读取真实额度或操作正式 App。系统外观实时切换、设置点击及原生提示的现场行为仍需运行开发 App 后手动验收。运行时 App 图标已接入有效外观变化；Finder 静态图标使用浅色版。Windows 实现留待后续。
