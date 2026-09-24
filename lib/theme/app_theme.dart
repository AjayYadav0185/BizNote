import 'package:flutter/cupertino.dart';

/// The application theme follows the device's light/dark appearance by leaving
/// [CupertinoThemeData.brightness] unset. Dynamic Cupertino colors are resolved
/// against the current platform brightness at render time.
const CupertinoThemeData appTheme = CupertinoThemeData(
  primaryColor: CupertinoColors.systemBlue,
  scaffoldBackgroundColor: CupertinoColors.systemBackground,
  barBackgroundColor: CupertinoColors.secondarySystemBackground,
  textTheme: CupertinoTextThemeData(
    navTitleTextStyle: TextStyle(
      fontSize: 18,
      fontWeight: FontWeight.w600,
      color: CupertinoColors.label,
    ),
    navLargeTitleTextStyle: TextStyle(
      fontSize: 34,
      fontWeight: FontWeight.bold,
      color: CupertinoColors.label,
    ),
  ),
);
