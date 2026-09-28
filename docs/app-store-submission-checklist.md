# vibebuddy iOS — App Store 提交清单

App 已上架（`com.vibebuddy.app`，Team `LQAVR62TK2`）。每次提交新版本按下面走；App ID、Push、Time Sensitive、iCloud (CloudKit) 容器 `iCloud.com.vibebuddy.app`、App Group `group.com.vibebuddy.app` 都已配好，以 `project.yml` 与 entitlements 为准。

## 必过项：Watch 通知、震动与审批

涉及远程连接、推送、Watch 或配对的版本，按 [Watch 验收](watch-notification-acceptance.md)在日常使用的开发签名直装包上完成手机锁屏后的通知、真实震动、手表批准和 Mac 回执（Mac 端推送切到 sandbox 配合开发包）。记录双方实际版本及推送环境。个人开发项目：一轮通过即算数，不走 TestFlight，不重复跑。

## 步骤

1. 版本号：`project.yml` 里每个 target 的 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` 保持一致。
2. `tools/archive-ios.sh`（用 Xcode 登录的 Apple ID 签名，也支持 `--api-key`）：核对配置、archive、导出，验证 `.ipa` 里 app / Widget / 通知扩展 / Watch app 都正确内嵌与签名，最后打印上传命令。脚本从不上传。
3. 上传：Organizer → Distribute App → App Store Connect，或脚本打印的 `xcrun altool` 命令。等几分钟 build 出现在版本页。
4. 更新说明写进 `docs/release-notes-ios-<version>.md`，粘到 What's New。文案、隐私标签和审核备注见 [app-store-listing.md](app-store-listing.md)。
5. 选 build → Submit for Review。提交要有所有者的明确指令。

## 被拒风险

伴侣 app 最可能按 Guideline 4.2 / 4.2.3（依赖外部软件，审核员无法验证）被拒。对策：审核备注写清配对方式，附演示视频 `docs/app-store-screenshots/pro-max-demo-reviewer-flow.mp4`，App 内有演示模式可在没有 Mac 时看到完整界面。
