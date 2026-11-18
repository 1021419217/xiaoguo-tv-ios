# 待办交接（2026-11-19 04:20）

代码基线：`5f83a57`（底栏已恢复实底）。以下按优先级排列。

## 1. 卡顿（最高优先）

用户反馈：滑动掉帧、图片加载慢、像内存不够。三个已知嫌疑点，按顺序处理：

- **底栏 `BackdropFilter`**：`lib/ui/shell/app_shell.dart` 里导航外面包了一层 `ImageFilter.blur(sigmaX: 24, sigmaY: 24)`，全宽实时模糊，滚动时每帧重算。**直接删掉这层**，保留下面的实底。
- **瀑布流非懒加载**：`lib/ui/widgets/drama_grid.dart` 的 `_masonry` 用 `SliverToBoxAdapter` + `Column(children: [...])`，一次性构建全部卡片。条目多时会内存暴涨、滑动卡。改成懒加载（`SliverList` 或分块构建）。
- **封面解码尺寸**：`lib/ui/widgets/cover_image.dart` / `cover_loader.dart`。列表封面应按显示宽度解码（约 440），不要按原图尺寸解码；详情页才用大图。

## 2. 勾选后「取消追剧」红条与底栏重叠

- 位置：`lib/ui/follow/follow_page.dart` 的选中操作条（红色「取消追剧」）。
- 原因：浮动操作条没给底栏让位。
- 改法：距底 = 底栏高度（62）+ 安全区 + 12。

## 3. 下载页右上角无用按钮

- 位置：`lib/ui/downloads/downloads_page.dart`，右上角三横线圆钮（`BarButton` + `Icons.menu` 一类）。
- 现象：点击无反应。
- 改法：没有绑定动作就删掉；若预留功能，先注释掉不要显示。

## 4. 最近观看右上两个按钮

- 位置：`lib/ui/widgets/page_header.dart`（已加 `Row(spacing: 8)`）+ 各页 `actions`。
- 现象：贴右边太近（右内边距 16），且两个按钮配色不统一（一个中性灰、一个粉红底）。
- 改法：右内边距 16 → 20；两个按钮统一同一种色调（危险操作才用红）。

## 做完后的验证顺序

1. `dart analyze lib`（必须先过，不要再被 Flutter 末尾的签名提示误导）
2. 构建一次，出未签名 IPA
3. 实机看：滑动帧率、图片加载、勾选条位置、右上按钮

## 已知忌讳（避免重复踩坑）

- 不要整文件回退 `drama_grid.dart`：三页依赖其中的 `usePosterMasonry` / `PosterMasonry` / `posterAspect`。
- 瀑布流回退老算法时，注意 `CoverShapes.ratioOf` 现在是**双参数**（source, dramaId）。
- 不要全局覆盖 `scheme.primary`：会废掉「外观」切色。
