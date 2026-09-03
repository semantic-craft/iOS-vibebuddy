# VibeBuddy 国区上架 — ICP App 备案逐步清单

> # ⛔ 不适用 — 2026-09-03 决定:**只上架美区,不上国区**
>
> 备案义务的判定标准是**是否在国区应用商店上架**,与服务器在哪无关。不上国区就
> **没有备案义务**,也**不需要**走 §-1 的豁免申诉——那条路是给"想上国区、但依法
> 不该被要求备案"的 app 用的,不上国区连这个问题都不存在。
>
> 连带解除的约束(这些原本都是备案带来的):
> - App Store「App 名称」**不再需要**与任何备案名逐字一致 → `VibeBuddy: Agent Monitor`
>   可以原样用,副标题/后缀也能留着做 ASO(见 `docs/app-store-paste-sheet.md` §1/§2)
> - 不需要中文名定稿、不需要阿里云服务器、不需要 `responsay.com` 备案域名
> - 不需要人脸核验、不需要工信部 24 小时短信验证
> - 分发证书换证后**不需要**提交备案变更
>
> **本文保留只为一件事**:哪天决定上国区,或国内安卓商店(华为/小米/OPPO/vivo/应用宝——
> 那些同样强制备案),从 §-1 重新开始读。§0 的公钥与指纹到 2027-06-06 证书到期为止有效。
>
> 注意:responsay 和 nomovox 若要上国区,§2 的"多 app 共用一台服务器"策略仍然成立。

> 主体:**个人** · 接入服务商:**阿里云** · 出具 2026-06-07 · **修订 2026-09-03(R3)**
> 图例:🧑 只能你做(实名/付费/人脸/手机)· 🤖 我能帮你做(命令/文案/核对)· ⏳ 等待 · ❓待你确认

**2026-09-03 这次改了什么**(详见各节)
1. 新增 §-1:**先决定走备案还是豁免申诉**——这条路原清单没有,可能整件事都不用做。
2. §3 的公钥/指纹提取命令**在本机跑不通**(cloud-managed 签名,本地根本没有分发证书),已换成能跑通的做法,**公钥、SHA-1、MD5 已提取并填入 §0**。
3. §1 名称:补上 **2026-02-12 起 App Store 逐字严格校验**这条硬规则,以及它和 `docs/app-store-paste-sheet.md`(R2)里英文名的冲突。
4. §4 备案表单文案已起草。

---

## §-1. 先决定:备案,还是向 Apple 申请豁免?(🧑 拍板,这是最省钱的一步)

原清单直接假设"纯局域网 app 也要备案"。这条**在监管口径上成立,但不是唯一出路**:苹果对未备案 app 一刀切下架国区,而**纯离线 / 只连苹果服务器的 app 可以向 Apple 申请 ICP 豁免**,多位开发者已完整走通,2–3 个工作日,零成本。

| | 路线 A:正规备案 | 路线 B:豁免申诉 |
|---|---|---|
| 成本 | ~¥110–130/年(服务器+域名) | ¥0 |
| 周期 | 阿里云初审 1–2 工作日 + 管局 ~20 工作日 | 2–3 个工作日(也有人报 1 周–1 月) |
| 副作用 | **App 名称被锁死**,以后改名要重新备案 | 名称自由,可留副标题做 ASO |
| 稳定性 | 稳,长期经营的正解 | 通过后仍有被下架风险;一旦加联网功能就得补备案 |

**vibebuddy 属于灰色地带,不是干净的"纯离线"**,这点必须诚实评估:

| 网络行为 | 对豁免的影响 |
|---|---|
| 局域网连你自己的 Mac | ✅ 不构成"在境内提供互联网信息服务",无主办者服务器 |
| APNs 推送 | ✅ 只连苹果服务器,属于豁免话术明确覆盖的情形 |
| **语音伴侣 → OpenAI / Google / 阿里云百炼** | ⚠️ **这是唯一的硬伤**。虽然默认关闭、用用户自己的 key、不过 vibebuddy 服务器,但它确实是到第三方服务器的联网调用 |

所以两个选择:

- **想走豁免** → 干净的做法是**国区版本不带语音功能**,那时 vibebuddy 就是标准的"本地工具 + 苹果系统服务",申诉话术站得住。
- **语音要留** → 申诉时如实写明,**能不能过取决于苹果审核员**;赌不过就走路线 A。

⚠️ **不要在申诉材料里隐瞒语音功能。** 材料最后要你手写签名声明,写不实内容性质完全不同。

**豁免申诉入口**(🤖 我可以起草声明全文):
App Store Connect 页面最底部「联系我们」→ 新的问题 → 分发 → 有关分发的其它疑问 → 填表。
表里的「应用的 Apple ID」指 App Store Connect 里这个 App 的 Apple ID,不是你的开发者账号。
苹果回两封邮件(一封说要什么材料,一封给上传链接),材料需**打印、手写签名、扫描回传**,内容含 Team ID、账户持有人法定姓名、App ID 和确认声明。

- [ ] **决定走 A 还是 B** ← 这一格没填之前,下面 §1–§5 先别动

> 下面 §1 起是**路线 A(正规备案)**的流程。选路线 B 的话,只需要 §1 的名称决定(可以选英文名)和一份声明。

---

## §0. 已确认的 App 信息(🤖 已核对到当前构建)

数据来自 2026-09-03 由 `tools/archive-ios.sh` 导出的发布签名 `.ipa`,不是从 project.yml 抄的。

| 项 | 值 | 备注 |
|---|---|---|
| 包名(Bundle ID) | `com.vibebuddy.app` | 备案"运行平台特征"填这个;大小写严格匹配。Widget `com.vibebuddy.app.widget` 不单独备案 |
| 开发者 Team | `LQAVR62TK2` | |
| 版本 | **1.0 / build 3** | 原清单写 build 1,已过时 |
| 图标下显示名(`CFBundleDisplayName`) | `vibebuddy` | 与 App Store 名称不同,见 §1 的 ❓ |
| 分类 | **工具**(个人主体只能选无经营类目) | 见 §4.2 |
| **App 名称** | **待定稿 → §1** | 一旦备案就锁死 |
| iOS 公钥 | ✅ 已提取,见下 | |
| 证书 SHA-1 | `52:8D:E1:1D:AF:CE:15:43:40:19:D0:A1:9A:A3:6E:67:D1:81:D8:55` | |
| 证书 MD5 | `F8:B5:E2:52:51:D8:F1:83:AF:35:9C:72:0B:28:ED:17` | 表单若要 MD5 用这个,见 §3 的 ❓ |
| 证书有效期 | 2026-06-06 → 2027-06-06 | **到期换证后公钥和指纹会变**,需提交备案变更 |
| 后台域名 | 待购买(§2) | 纯局域网 app 实际不用,仅满足备案 |

**公钥**(备案表单「公钥」栏,整段粘贴,含首尾两行):

```
-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEApliYzOfv9w9v/24lUwMR
UjoKaMpXm3UYB6JAl9zHqWZ50RAFtVu39B+o8vw3r/EXUzPG/cGCz8Kxd8aCyuGR
stwVqwQDfPkAFNLT9NOhgI9XgDIE+VfVAS30JaB/XHcwr264Navoauw3/qhtFoLW
iAvt3DwbziJ+8vH4JuS5W6qNXiLd5kvkdOtAqHC3ibK76EwkzfOPzmD3dadk7yn6
w+2ODoEzg9mmIGoMot9CIXdJ+r0Lp8cnBgSr1i+umqI2emoMYbUMfnqNwLNlrmxG
wlzivX34ekrkdI+9zyrz5Gw42iv1w7BRK3bLEi7z/9KRaGAnxnLYUbA1G9fsY9Yx
9wIDAQAB
-----END PUBLIC KEY-----
```

签发对象:`Apple Distribution: Xianwei Zhang (LQAVR62TK2)`

---

## §1. 名称定稿(🧑 拍板 — 备案前必须想清楚)

**2026-02-12 起 App Store 对国区名称改成逐字严格校验。** 起因是"死了么"事件(一款备案名 demumu 的应用改名炒作、买量冲榜后跑路),苹果随即收紧。现在:

- App Store Connect 后台的「App 名称」必须与备案名**完全一致**——有开发者卡在四个字中间的**一个空格**上;
- **副标题后缀彻底没了**("XX - 一句话介绍"这种格式过不了),对独立开发者等于丢掉唯一的免费搜索流量入口;
- 想改名 = 重新备案;
- 校验的是**后台「App 名称」字段**,不是包里的名称——所以 `CFBundleDisplayName` 保持 `vibebuddy` 不影响校验。

### ⚠️ 与 R2 的直接冲突

`docs/app-store-paste-sheet.md` 里填的 App 名称是 **`VibeBuddy: Agent Monitor`**(因为"vibebuddy"单独在商店被占用)。**走路线 A 的话这个名字必须等于备案名**,而个人备案用带冒号的纯英文名能不能过,不确定。两条出路:

- 备案一个中文名,并把 App Store Connect 的**简体中文本地化**名称改成它(海外区仍可用英文名);
- 或走 §-1 的路线 B,名称完全自由,`VibeBuddy: Agent Monitor` 原样保留。

❓**待确认(问阿里云备案客服,他们是接入商,以他们口径为准):**
1. 个人主体能否备案纯英文 App 名称?
2. 备案「App 名称」到底填**应用商店展示名**还是**手机图标下的名称**?——阿里云同行的华为云文档写的是"下载安装 App 后显示在图标下面的名称",而实操社区一致说必须等于 App Store 展示名。两者在本项目里**是不同的**(`vibebuddy` vs `VibeBuddy: Agent Monitor`),不能猜。

### 中文名候选(🤖 起草)

个人备案不得含企业字号、"中国/国家/政府"等敏感词;上限 30 字符;同一主体下唯一。

| 候选 | 长处 | 短处 |
|---|---|---|
| **代码搭子** ← 推荐 | 无歧义、无敏感词、口语化有记忆点、贴合"工具"类目 | "搭子"是当下流行语,几年后可能显得过时 |
| 码搭子 | 更短更脆 | "码"单独易被读成号码/码头,首次接触不好懂 |
| 智能体看板 | 最直白,审核最稳,描述即功能 | 平淡,没有品牌感 |
| 敲代码搭子 | 最口语 | 5 字偏长,略啰嗦 |

- [ ] 定稿中文名:____________
- [ ] App Store Connect 简体中文本地化「App 名称」改为该名(与备案名逐字一致,注意空格)
- [ ] 同步更新 `docs/app-store-paste-sheet.md` §1

---

## §2. 阿里云开户 + 买备案资源(🧑)

入口:<https://beian.aliyun.com> ——**仅路线 A 需要**。

- [ ] 2.1 注册阿里云账号,完成**个人实名认证**(支付宝/银行卡)
- [ ] 2.2 买**符合备案条件的云服务器**(三个 app 共用一台):
  - **ECS 经济型 e**,**地域中国内地**、**1 年(≥3 个月)**、**3M 公网带宽**(2核2G),~¥99/年
  - 三个硬条件:① 中国内地 ② 包年包月≥3月 ③ 有公网带宽 —— 满足后可申请**备案服务码**
- [ ] 2.3 域名:
  - [ ] **`responsay.com` → 阿里云万网注册** + **域名实名认证** —— 唯一的备案后台域名,三个 app 共用
  - [ ] **`nomovox.com` → Cloudflare 注册**(纯品牌/海外,**不参与备案**)
  - **顺序**:responsay.com 先解析到阿里云服务器**过完备案**,之后再按需把 NS 换到 Cloudflare
  - ⚠️ 不要在 Cloudflare 买备案域名:国外注册商域名无法直接备案,转入境内还需"注册满 60 天"
- 成本合计:**约 ¥110–130/年**

### 多 app 共用策略(VibeBuddy / responsay / nomovox)

同一个人主办者下**可共用一台阿里云服务器**作为接入资源,买一台 ¥99 服务器即可覆盖三者。

| App | 后端 | 国内访问架构建议 |
|---|---|---|
| VibeBuddy | 局域网,无真后端 | 后台域名纯走形式;Cloudflare 与否不影响 |
| responsay | 有真后端、面向国内 | 国内主力 → 阿里云国内/国内 CDN;国内+海外 → 双线 |
| nomovox(输入法) | 涉及用户输入内容 | 数据尽量境内,审查更严 |

**Cloudflare 注意**:免费/Pro 版对大陆访问慢且不稳;要顺畅得用 Cloudflare **中国网络(Enterprise + 京东云,需 ICP 备案)**——用 CDN 向中国访客提供服务同样要备案,绕不过。<https://developers.cloudflare.com/china-network/concepts/icp/>

---

## §3. 提取 iOS 备案特征信息(🤖 已完成)

**原清单的命令在本机跑不通**,值已用下面的方法提取好,填在 §0。

原来写的是:

```bash
security find-certificate -c "Apple Distribution" -p > /tmp/dist.pem   # ✗ 在本机返回"找不到"
```

**为什么失败**:这台机器用的是 Xcode **cloud-managed 分发签名**——私钥留在 Apple,签名发生在 `-exportArchive` 阶段,本地钥匙串里**一张 Apple Distribution 证书都没有**(`security find-identity -v` 查不到任何 distribution 项),而 app 照样被正确签名。这是正常状态,不是配置缺失。

**能跑通的做法**——从已签名的 `.ipa` 里把证书抠出来(证书是公开信息,签名产物里本来就带着):

```bash
# 先用 tools/archive-ios.sh 产出 .ipa
cd "$(mktemp -d)" && unzip -q /path/to/VibeBuddyApp.ipa
codesign -d --extract-certificates=cert- Payload/VibeBuddyApp.app   # cert-0 是叶子证书(DER)

openssl x509 -inform DER -in cert-0 -noout -pubkey            # 公钥
openssl x509 -inform DER -in cert-0 -noout -fingerprint -sha1  # SHA-1
openssl x509 -inform DER -in cert-0 -noout -fingerprint -md5   # MD5
openssl x509 -inform DER -in cert-0 -noout -subject -dates     # 签发对象与有效期
```

- 阿里云备案系统也支持直接上传 `.p12`/`.cer` 自动解析。**注意本机没有可导出的 `.p12`**(私钥在 Apple 手上),所以走上面的命令或上传 `cert-0`。
- ❓**SHA-1 还是 MD5?** 原清单断言"iOS 用 SHA-1(安卓才用 MD5)",但华为云的备案文档统一写「公钥、**MD5** 签名值」,社区也有人被这一栏卡住。**两个值 §0 都给了**,按表单实际标签填。无论哪个,要的都是**证书指纹**,不是 ipa 文件的哈希。
- [x] 跑出公钥 + SHA-1 + MD5(2026-09-03)
- [ ] 填入备案表单的"运行平台特征"

---

## §4. 提交 App 备案(🧑 + 🤖 文案已起草)

在 <https://beian.aliyun.com> → App 备案:

- [ ] 4.1 主办者信息(个人:姓名 / 身份证 / 手机 / 邮箱)
- [ ] 4.2 App 基础信息:**App 名称(= §1 定稿名)**、图标、内容分类、语言
  - **分类选「工具」**。个人主体只能选无经营类目(工具/摄影/图书等);电商/金融/医疗/教育需前置审批资质。原清单写的"开发者工具"不一定在可选项里,以表单实际下拉为准。
  - **语言选「中文」**(不建议多选)
  - 图标:`VibeBuddyApp/Sources/Assets.xcassets/AppIcon.appiconset/icon_1024.png`,建议压到 100K 以内再传
- [ ] 4.3 运行平台特征:平台 iOS、包名 `com.vibebuddy.app`、公钥、指纹(全部见 §0)
- [ ] 4.4 接入信息:选 §2 的阿里云服务器 + 后台域名
- [ ] 4.5 上传材料 + 阿里云 App **人脸核验**(主办者本人)
- [ ] 4.6 提交

### 后台域名怎么填(🤖)

vibebuddy 没有真后端,这一栏纯粹是备案制度的形式要求。

- 填 **`responsay.com`** 本身,或给它一个子域名做区分(如 `vibebuddy.responsay.com`)。三个 app 共用同一主域名是允许的。
- 域名的**实名认证信息必须与备案主体一致**(都是你本人),否则这一步直接卡住。
- 还要填**域名解析到的服务器 IP**——就是 §2 那台阿里云 ECS 的公网 IP。所以备案期间 `responsay.com` 必须真的解析到那台机器,不能提前挂到 Cloudflare。
- App 支持二到四级域名备案。
- 「首页地址」非必填,可留空。

### 备案表单文案(🤖 起草,可直接粘)

**App 简介 / 服务内容描述**:

```
本应用是一款面向软件开发者的本地工具,用于查看运行在用户自己电脑上的编程辅助程序的运行状态。用户通过扫描二维码,将手机与同一局域网内的个人电脑配对,在手机上查看各项任务的进行状态,并在需要时给出继续或停止的指令。

本应用不设服务器,不提供账号注册与登录,不发布、传播或存储任何面向公众的信息内容,不含社交、社区、评论、资讯、直播、交易等功能。所有数据仅在用户本人的手机与电脑之间通过局域网直接传输,不经过本应用的任何服务器。
```

> 起草口径:全程避开"信息服务""内容发布""用户上传"这类会触发额外审查的措辞,如实强调无服务器、无账号、无内容分发——这三条正是个人主体、无经营类目能顺利过审的理由。语音功能是可选项且不经本应用服务器,是否在此处提及,建议按 §-1 的路线选择保持一致。

---

## §5. 审核 + 填回 App Store Connect(⏳ + 🧑 + 🤖 核对)

- [ ] 5.1 阿里云初审 **1–2 工作日**(可能电话核实)
- [ ] 5.2 **工信部会发短信验证,必须 24 小时内完成,逾期整个流程重来** ← 别错过
- [ ] 5.3 提交管局,**一般 20 工作日内**核发备案号(短信通知)
- [ ] 5.4 到 [工信部备案查询](https://beian.miit.gov.cn) 或阿里云审核页,**复制**带 `-1A` 后缀的备案号(**不要手输**,避免全/半角问题)
- [ ] 5.5 粘贴到 **App Store Connect → App 信息 →「App Store 法规和许可」→ ICP 备案号**
- [ ] 5.6 确认 App Store「App 名称」与备案名逐字一致 → 提交审核

### 如果卡进"死循环"

报错 `App 名称与中国工业和信息化部 (MIIT) 记录不符`,而改名又提示"下一次提交 App 后将审核此名称"——社区实测的绕法:

1. 在要提交的新版本里把「App 名称」改成与备案名一致;
2. 把 App 信息里的**主要语言**改成该名字对应的语言(简体中文);
3. 填入备案号,保存成功;
4. 之后可再把主要语言和名称调回去。

---

## §6. 2026 年首次提审的额外材料(🧑 + 🤖)

今年首次提审的材料要求整体提高了,备案材料备齐时顺手一起准备:

- [ ] **真机全流程录屏** —— 现有的 `docs/app-store-screenshots/pro-max-demo-reviewer-flow.mp4` 是 demo 模式录的,**不是真机全流程**;国区提审可能需要补一份真实 Mac + iPhone 配对的录屏
- [ ] **测试账号** —— 本应用无账号体系,注明"无需账号,内置演示模式"
- [ ] **第三方依赖清单** —— 🤖 可从 `Package.resolved` 生成
- [ ] **区域适配说明** —— 简体中文本地化已有(`VibeBuddyApp/Resources/zh-Hans.lproj`)

---

## 常见坑

- App 名称与工信部记录不一致 → 提审报"与 MIIT 记录不符";务必逐字一致(连空格)、复制粘贴备案号。
- App 备案 ≠ 网站备案,域名已做过网站备案仍需单独 App 备案。
- 同主体同 App 在不同渠道若名称不同,需分别备案。
- 个人备案名称不得含企业/单位字号、"中国/国家/政府"等。
- **App 名称、Bundle ID 属于备案核心信息,变更后必须提交备案变更并等管局重新审核通过,才能更新商店版本。**
- **分发证书到期换证后,公钥与指纹会变**(当前证书 2027-06-06 到期),同样需要提交变更。

## 来源

- 2026 年新规与豁免/备案两条路对比:<https://post.m.smzdm.com/p/ad7dgwwk/>
- 豁免申诉实操(V2EX,多人实测):<https://origin.v2ex.com/t/1232582> · <https://v2ex.com/t/1224824> · <https://origin.v2ex.com/t/1208704>
- App 名称强校验:<https://www.163.com/dy/article/IURHT83O0511QMVT.html> · 死循环绕法 <https://m.bilibili.com/opus/914373901402767369>
- 备案表单字段规范(华为云,字段口径与阿里云一致):<https://support.huaweicloud.com/usermanual-icp/zh-cn_topic_0000002127792641.html>
- 个人主体类目限制与全流程:<https://aiflutter.com/docs/zh/guide/filing.html>
- 阿里云 App 备案 FAQ:<https://help.aliyun.com/zh/icp-filing/basic-icp-service/support/basics-about-icp-filling-for-apps>
- 阿里云 App 特征信息:<https://help.aliyun.com/zh/icp-filing/basic-icp-service/user-guide/fill-in-app-feature-information>
- 备案服务器条件:<https://help.aliyun.com/zh/icp-filing/basic-icp-service/user-guide/icp-filing-server-access-information-check>
- Cloudflare 中国网络与 ICP:<https://developers.cloudflare.com/china-network/concepts/icp/>
