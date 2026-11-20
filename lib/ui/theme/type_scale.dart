import 'package:flutter/material.dart';

/// 短剧之家字阶（Type Scale）。
///
/// 依据官方截图逐字测量 + 系统字体栈特性反推。短剧之家没有打包自定义中文字体，
/// 中文走系统字体（iOS 苹方 / Android 思源黑体），因此这里只固化「字号 / 字重 /
/// 字距 / 行高」四件事——这正是它比普通 App「高级」的排版来源：
///
///   标题特粗 + 负字距收紧，说明文字细 + 行高放松，靠对比 rather than 一味加粗。
///
/// 小果之前的问题是把标题和正文都设成 w600~w800，对比被抹平、糊成一片。
/// 本文件把层级拉开，统一给主题层和各页面引用，改字阶只需改这一处。
abstract final class TypeScale {
  // ── 字重档位 ─────────────────────────────────────────────
  static const FontWeight regular = FontWeight.w400; // 正文、说明
  static const FontWeight medium = FontWeight.w500; // 元信息、次要标签
  static const FontWeight semibold = FontWeight.w600; // 分组标题、条目标题
  static const FontWeight bold = FontWeight.w700; // 强标题
  static const FontWeight heavy = FontWeight.w800; // 剧名、大标题、当前选中

  // ── 字距档位（负值收紧大标题，正值放松小字） ──────────────
  static const double trackingTight = -0.5; // 剧名
  static const double trackingSnug = -0.2; // 大标题 / 条目标题
  static const double trackingNormal = 0.0; // 正文
  static const double trackingLoose = 0.3; // 分组小标题

  // ── 行高档位 ─────────────────────────────────────────────
  static const double leadingTitle = 1.25; // 标题
  static const double leadingBody = 1.55; // 正文简介（短剧之家观感）
  static const double leadingCaption = 1.4; // 说明灰字

  /// 生成一档文字样式。color 故意不写死，由调用方按主题着色。
  static TextStyle style({
    required double size,
    required FontWeight weight,
    double spacing = trackingNormal,
    double height = leadingBody,
  }) =>
      TextStyle(
        fontSize: size,
        fontWeight: weight,
        letterSpacing: spacing,
        height: height,
      );

  // ── 语义化字阶 ───────────────────────────────────────────
  // 剧名 / 沉浸式封面大标题：特粗 + 紧字距
  static TextStyle display(double size) => style(
        size: size,
        weight: heavy,
        spacing: trackingTight,
        height: leadingTitle,
      );

  // 页面大标题（设置页「设置」、分区大标题）：特粗 + 略收
  static TextStyle headline(double size) => style(
        size: size,
        weight: heavy,
        spacing: trackingSnug,
        height: leadingTitle,
      );

  // 条目标题（设置项「设备互联」、卡片主标题）：中等偏粗
  static TextStyle title(double size) => style(
        size: size,
        weight: semibold,
        spacing: trackingSnug,
        height: leadingTitle,
      );

  // 正文 / 剧情简介：常规 + 放松行高
  static TextStyle body(double size) => style(
        size: size,
        weight: regular,
        spacing: trackingNormal,
        height: leadingBody,
      );

  // 元信息 / 标签（奇幻 · 全 260 集 · 已完结）：中等
  static TextStyle meta(double size) => style(
        size: size,
        weight: medium,
        spacing: trackingNormal,
        height: leadingCaption,
      );

  // 说明灰字 / 副标题：细 + 放松行高
  static TextStyle caption(double size) => style(
        size: size,
        weight: regular,
        spacing: trackingNormal,
        height: leadingCaption,
      );

  // 分组小标题（「设备与同步」「界面与播放」）：小字 + 正字距 + 中粗
  static TextStyle section(double size) => style(
        size: size,
        weight: semibold,
        spacing: trackingLoose,
        height: leadingCaption,
      );

  // 按钮 / 当前选中态：粗
  static TextStyle emphasis(double size) => style(
        size: size,
        weight: bold,
        spacing: trackingSnug,
        height: leadingTitle,
      );
}
