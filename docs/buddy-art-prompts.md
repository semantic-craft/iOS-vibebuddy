# vibebuddy 吉祥物 — AI 出图提示词(二次元猫)

目标:同一只猫,4 个状态各一张,**二次元/kawaii 风**、**透明背景 PNG**、居中、小尺寸(~60px)也清晰。
状态对应 app 的 BuddyState:**working / needsResponse(举牌) / done(开心) / sleeping(睡觉)**。

技术要求(给我用):
- **透明背景 PNG**(最重要;不然要抠图)
- 正方形画布、角色居中、4 张**同一只猫**(造型/配色一致)
- 干净粗描边 + 平涂/赛璐璐上色(anime 感),别写实、别太复杂
- 给我时:把 4 个 PNG 命名 `cat_working.png / cat_needs.png / cat_done.png / cat_sleeping.png`,丢进 `VibeBuddyApp/Resources/Buddy/`,我接进去(静态图 + 我加动效)

---

## 方案 1:一张「角色表情设定图」(最推荐,一致性最好)
一次出 4-5 个姿势,风格/角色天然一致,再切成单张。**ChatGPT(GPT-image)/ Gemini 直接能出多姿势一张图。**

> A character design / expression sheet of ONE cute chibi cat mascot for a developer app, kawaii anime style. Show the SAME cat in a 2x2 grid, four poses: (1) sitting and focused while typing on a tiny laptop; (2) standing and holding up a small wooden sign with big alert eyes (sign is blank); (3) happy, eyes closed in a smile, paws up celebrating with a sparkle; (4) curled up sleeping with "Zzz". Consistent character across all four, round body, big expressive eyes, soft flat cel-shaded colors, thick clean outlines, simple and readable when small. Transparent background. Each pose centered with even spacing.

(若工具不支持透明,就加 "plain solid white background",我来抠。)

## 方案 2:单张分别出(每状态一条)
用同一段「风格锚点」+ 换姿势,保证一致:

风格锚点(每条都带上):
> cute chibi cat mascot, kawaii anime style, round body, big expressive eyes, soft flat cel-shaded colors, thick clean outlines, centered, transparent background, simple and readable at small size

- **working**:`<风格锚点>, sitting and focused while typing on a tiny laptop, calm`
- **needsResponse**:`<风格锚点>, standing and holding up a small blank wooden sign, big alert eyes, ears perked, slightly worried-cute`
- **done**:`<风格锚点>, happy, eyes closed in a smile, paws raised celebrating, a small sparkle`
- **sleeping**:`<风格锚点>, curled up asleep, eyes closed, a small "Zzz" above`

---

## 各工具要点
- **Midjourney**:句尾加 `--niji 6 --ar 1:1`(niji 6 = 动漫专用模型,最二次元)。一致性:先出一张满意的当 reference,后面几张加 `--cref <图片URL> --cw 100`。透明:MJ 不擅长真透明 → 用白底出图我来抠,或用其透明功能(若有)。
- **ChatGPT(GPT-image / 4o 画图)**:可直接出**透明 PNG**,也能一张图出 2x2 表情设定(方案 1)。一致性最好,推荐先用它出设定图。
- **Gemini(Imagen / "Nano Banana" 编辑)**:先出一张,再说「同一只猫,改成睡觉的姿势」来保持一致;支持透明/编辑。

---

## 交付后我做什么
1. 你把 4 张 PNG 按上面命名丢进 `Resources/Buddy/`。
2. 我把 BuddyView 从 Lottie 切到「按状态显示对应 PNG + SwiftUI 动效(呼吸/跳/举牌叠加)」。
3. 上 App Store 前:自己生成的图**版权干净**(比 LottieFiles 那只黑猫安全),可放心用。
