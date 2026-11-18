import 'package:flutter/material.dart';

abstract final class AppRadius {
  static const content = 12.0;
  static const surface = 20.0;
  static const badge = 8.0;
  static const pill = 999.0;

  static BorderRadius get contentAll => BorderRadius.circular(content);
  static BorderRadius get surfaceAll => BorderRadius.circular(surface);
  static BorderRadius get badgeAll => BorderRadius.circular(badge);
  static const BorderRadius pillAll = BorderRadius.all(Radius.circular(999));
}

abstract final class AppSpace {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
}

abstract final class AppType {
  static const display = 27.0;
  static const title = 15.0;
  static const body = 13.0;
  static const caption = 10.5;

  static const displayWeight = FontWeight.w800;
  static const titleWeight = FontWeight.w700;
  static const bodyWeight = FontWeight.w500;
  static const captionWeight = FontWeight.w400;

  static TextStyle displayStyle(Color color) => TextStyle(
    fontSize: display,
    fontWeight: displayWeight,
    letterSpacing: -0.5,
    color: color,
  );

  static TextStyle titleStyle(Color color) => TextStyle(
    fontSize: title,
    fontWeight: titleWeight,
    height: 1.3,
    color: color,
  );

  static TextStyle bodyStyle(Color color) => TextStyle(
    fontSize: body,
    fontWeight: bodyWeight,
    height: 1.4,
    color: color,
  );

  static TextStyle captionStyle(Color color) => TextStyle(
    fontSize: caption,
    fontWeight: captionWeight,
    height: 1.3,
    color: color,
  );
}
