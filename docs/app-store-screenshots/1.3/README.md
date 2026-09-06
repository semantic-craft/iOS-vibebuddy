# VibeBuddy 1.3 截图包

2026-09-06 实拍。共 **12 张**：iOS 4 张、watchOS 4 张、macOS 2 张，以及审核配对参考 2 张。全部来自实际运行的 App 演示界面，没有生成或重绘 UI；图片均为 RGB JPEG、无透明通道。文件名数字是各语言内的建议上传顺序。

## 上传位置

| 文件夹 | 每种语言 | 尺寸 | 用途 |
|---|---:|---|---|
| `ios/en-US`、`ios/zh-Hans` | 2 张 | 1320 × 2868 | iPhone 6.9-inch 栏：任务看板、Codex 任务详情 |
| `watchos/en-US`、`watchos/zh-Hans` | 2 张 | 416 × 496 | Apple Watch 栏：任务概览、额度；两种语言尺寸一致 |
| `macos/en-US`、`macos/zh-Hans` | 1 张 | 2560 × 1600 | Mac 平台截图尺寸；当前 Mac 伴侣通过 GitHub 分发，可用于仓库与审核附件。不要上传到 iPhone 截图栏 |
| `reviewer/en-US`、`reviewer/zh-Hans` | 1 张 | 1320 × 2868 | 首次配对及演示入口参考，不作为主宣传截图 |

应用当前 `TARGETED_DEVICE_FAMILY=1`，本包不包含 iPad。截图格式与尺寸依据 [Apple Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/) 核对：iPhone 使用受支持的 6.9-inch 尺寸，Mac 为 16:10，Watch 跨语言保持一致。

## 当前素材边界

- **英文版可优先用于预览；中文环境仍有未翻译的产品标签**（例如 “4 things need you”“Requires input”“Model”“Reply”）。样例项目名、代码和模型名也保留英文。图片没有替换这些文字；若发布前完善本地化，应从最终成品重拍。
- Watch 这里拍的是 **App 内任务与额度页面**，不把额度页面称作“表盘小组件截图”。表盘组件配置及实际表盘呈现尚未收录，不应用这组图代替该功能的视觉验收。
- Watch 页面可滚动，额度图展示 Codex 的周窗口和短窗口；下方内容仍在滚动页中。审批页初拍的操作按钮不完整，已从交付包剔除，没有用裁切、拼接或缩小文字伪造完整界面。
- 配对参考页已更新为本地实现的 Mac 下载三步引导；它用于帮助定位演示和配对入口，不证明真实 Mac 配对已经验收。
- 演示数据只用于说明界面。任务状态、额度百分比、错误和模型名称均不构成真实 Agent 兼容性、通知送达或额度验证。Mac 演示中的额度区域如实显示等待刷新。
- 这是**本地准备好的截图素材**，未上传 App Store Connect。最终提交的 build 若改变界面或本地化，应重拍受影响页面。

## 来源与重拍信息

- 本轮起始 HEAD：`90da1f7ce78eee7a4bc8e3c4197f5defdec449da`。产品源码未因截图任务修改。
- iOS / Watch：根据当前 `VibeBuddyApp/project.yml` 生成独立 Xcode 工程，Release、arm64 模拟器构建成功。运行时是 iOS / watchOS 26.5；截图构建通过 `WATCHOS_DEPLOYMENT_TARGET=26.5` 适配已安装的模拟器，未改项目正式部署目标。这不是 Distribution archive 或最终设备验收。
- Mac：已安装 1.3(7) 的独立副本，bundle ID 改为 `com.vibebuddy.store-shots` 并本地 ad hoc 签名，仅用于隔离演示和偏好。已核对 `10a04f5..90da1f7` 没有 Mac App Sources 差异；正在运行的正式应用未替换。
- 启动输入：`VIBEBUDDY_DEMO=1`；英文 `-AppleLanguages '(en)' -AppleLocale en_US`；中文 `-AppleLanguages '(zh-Hans)' -AppleLocale zh_CN`。Watch 概览用 `VIBEBUDDY_WATCH_SCENARIO=normal`、`VIBEBUDDY_WATCH_PAGE=home`，额度用 `quota`。交付图使用默认文字大小。
- iPhone 用独立历史截图模拟器副本；Watch 用本轮独立模拟器。iPhone 状态栏时间固定为 9:41；Watch 模拟器不支持该覆盖，保留系统显示时间。
- 原生采集：`xcrun simctl io <device> screenshot --type=jpeg <path>`；Mac `screencapture -x -o -l <windowID> -t jpg <path>`，1280×800 点窗口得到 2560×1600 像素图片。没有后期缩放、叠字或合成。
- 生成工程与构建日志保留于 `.scratch/store-shots-1.3/`。旧的本地 Xcode 工程缺少源码引用，初次构建失败；iOS 改用重新生成的独立工程成功，Mac 最终采用上述已安装成品副本，未将旧工程失败表述为本轮 Mac 源码构建通过。
- `manifest.json` 记录每张图片的尺寸、色彩模式、字节数和 SHA-256。

## 预览

### iPhone

| English | 中文环境 |
|---|---|
| ![Task dashboard](ios/en-US/01-dashboard.jpg) | ![任务看板](ios/zh-Hans/01-dashboard.jpg) |
| ![Codex task](ios/en-US/02-codex-task.jpg) | ![Codex 任务详情](ios/zh-Hans/02-codex-task.jpg) |

### Apple Watch

| English | 中文环境 |
|---|---|
| ![Watch tasks](watchos/en-US/01-task-overview.jpg) | ![手表任务](watchos/zh-Hans/01-task-overview.jpg) |
| ![Watch quota](watchos/en-US/02-quota.jpg) | ![手表额度](watchos/zh-Hans/02-quota.jpg) |

### Mac

![Mac English](macos/en-US/01-dashboard-approval.jpg)

![Mac 中文环境](macos/zh-Hans/01-dashboard-approval.jpg)

## 本地引导更新（2026-09-06）

reviewer 中的 iPhone 配对截图已更新为本次未提交的 Mac 伴侣三步引导。其他产品截图仍来自前述 HEAD；截图不代表真实 Mac 配对验收。
