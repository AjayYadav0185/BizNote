import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';

import 'providers/note_provider.dart';
import 'screens/home_screen.dart';

void main() {
  runApp(const NotepadApp());
}

class NotepadApp extends StatelessWidget {
  const NotepadApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (context) => NoteProvider(),
      child: const CupertinoApp(
        title: 'Notes',
        debugShowCheckedModeBanner: false,
        theme: CupertinoThemeData(
          brightness: Brightness.light,
          primaryColor: CupertinoColors.systemBlue,
          scaffoldBackgroundColor: const Color(0xFFFFFEFE),
          barBackgroundColor: const Color(0xFFF2F2F7),
          textTheme: CupertinoTextThemeData(
            navTitleTextStyle: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: CupertinoColors.black,
            ),
            navLargeTitleTextStyle: const TextStyle(
              fontSize: 34,
              fontWeight: FontWeight.w300,
              color: CupertinoColors.black,
            ),
          ),
          // iOS-like system colors
          systemOrange: CupertinoColors.systemOrange,
          systemYellow: CupertinoColors.systemYellow,
          systemGreen: CupertinoColors.systemGreen,
          systemRed: CupertinoColors.systemRed,
          systemBlue: CupertinoColors.systemBlue,
          systemGrey: CupertinoColors.systemGrey,
          systemGrey2: CupertinoColors.systemGrey2,
          systemGrey3: CupertinoColors.systemGrey3,
          systemGrey4: CupertinoColors.systemGrey4,
          systemGrey5: CupertinoColors.systemGrey5,
          systemGrey6: CupertinoColors.systemGrey6,
        ),
        home: HomeScreen(),
      ),
    );
  }
}
