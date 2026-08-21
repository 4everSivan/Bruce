# mddd Logo 候选提示词 — 方向 A「守望犬」

- IP 主题: 小狗 (守望犬) — 对应「菜单栏值守, 实时盯用量」
- 构图: 坐姿, 从下右角探入, 头微转向观察者, 下垂圆耳为唯一识别特征
- 约束: 三色语义 (2 IP 色 + 1 背景色), 1536×1536, 32×32 可识别, 6–10 基础形状, 8–12% 极轻内部建模, Flat-first
- 适用模型: GPT Image 2 / Nano Banana Pro / Seedream 5.0 Pro 等现代指令型模型 (约束走主提示词 `Constraints:` 行)
- 变体分布: 方向 A 六变体 A1–A6, 仅配色不同

## 公共骨架

将下方 `<IP_COLOR_1>` `<IP_COLOR_2>` `<BACKGROUND>` 替换为对应变体配色后直接使用.

```text
Create one complete full-bleed 1:1 square IP mascot logo artwork, 1536x1536.
Backdrop: cover the entire canvas with one visible, fully opaque solid <BACKGROUND>. Keep <BACKGROUND> clearly visible in all four square corners and every open area surrounding the mascot.
Subject: one highly simplified watchdog puppy mascot, sitting upright and leaning in from the lower-right corner as if perched on a menu bar edge, head turned slightly toward the viewer, reduced to one rounded continuous silhouette with one pair of large droopy rounded ears as its single defining feature. Both ears fully visible.
Complexity: 6–10 broad basic shapes, at most two broad internal color regions, face with two eyes and one mouth only, no eyebrows, no nostrils, no fur tufts. Readable as a black silhouette at 32x32.
Color behavior: exactly three semantic colors in the complete artwork: <IP_COLOR_1> as the main body mass, <IP_COLOR_2> as one continuous defining region (muzzle/chest patch) reused for facial marks, plus the backdrop color <BACKGROUND>. No other semantic colors. Keep IP, facial marks, and backdrop clearly separated. Closely related tonal variants from ultra-light internal modeling do not count as extra colors.
Composition: upright, emerging from the lower-right, filling 75–85% of the square, bottom crop intentional, never crop the ears.
Style: ultra-clean Flat-first logo treatment, minimal graphic masses, only 8–12% extremely subtle internal tonal modeling inside the IP; barely neo-skeuomorphic, thick, soft, restrained. Mostly flat. No prescribed gradient direction or highlight count.
Finish: only the mascot over the full-canvas backdrop, clean geometric surfaces, normal square outer corners.
Constraints: no text, no watermark, no borders, frames, cards or App-icon masks, one mascot only, no scenery, thick rounded contours without fragile lines or sharp tips (ear tips visibly blunt and rounded), no photorealistic material, no dramatic bevel, no glossy hotspot, no extrusion, no strong 3D rendering, no external cast shadow, background flat with no gradient, texture, vignette or lighting variation.
```

## 变体配色映射

| 变体 | IP 色 1 (身体主色) | IP 色 2 (吻部/胸块 + 面部标记) | 背景色 | 策略 |
|------|-------------------|------------------------------|--------|------|
| A1 | `#F59E4C` 暖橙 | `#FFF1DC` 奶油 | `#1B2A4A` 深海军蓝 | 经典深色看板场景 |
| A2 | `#FFF1DC` 奶油 | `#6B4A2F` 可可棕 | `#7D9B76` 鼠尾草绿 | 浅 IP 深绿底 |
| A3 | `#5C3D2E` 巧克力棕 | `#E8A33D` 琥珀 | `#F5EFE4` 米白 | 深 IP 浅底, 暖色系 |
| A4 | `#E8735A` 珊瑚红 | `#FDEDE3` 暖白 | `#141B24` 墨蓝黑 | 液态玻璃深色模式气质 |
| A5 | `#E9B949` 金黄 | `#4A3222` 深棕 | `#A8C3D1` 雾蓝 | 冷暖对比 |
| A6 | `#3E3A39` 炭灰 | `#F2A154` 暖橙 | `#F8F1E5` 奶油 | 反色策略 (深 IP 浅底) |

## 出图后评估清单

- [ ] 32×32 黑色剪影可识别
- [ ] 恰好三个语义色, 第二 IP 色为连续区域而非碎片
- [ ] 双耳完整可见, 尖端钝圆
- [ ] 面部仅两眼一嘴, 无眉毛/鼻孔/毛发细节
- [ ] IP 占画布 75–85%, 从下右角探入, 直立不倾斜
- [ ] 内部建模 ≤ 8–12%, 无体积感/黏土感/光泽热点
- [ ] 背景纯色平整, 四角可见, 无渐变/纹理/暗角
- [ ] 无文字/水印/边框/外阴影

## 下一步

生成 6 张候选后, 回传或给出保存路径, 逐张对照上表评估, 再决定精修对象. 若本地配置生图 MCP/CLI, 可由 agent 直接批量生成.
