import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:BizNote/theme/app_theme.dart';

void main() {
  testWidgets('app theme resolves to the device background color',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(platformBrightness: Brightness.dark),
        child: CupertinoApp(
          theme: appTheme,
          home: Builder(
            builder: (BuildContext context) {
              expect(
                CupertinoDynamicColor.resolve(
                  appTheme.scaffoldBackgroundColor,
                  context,
                ).toARGB32(),
                0xFF000000,
              );
              expect(
                CupertinoTheme.brightnessOf(context),
                Brightness.dark,
              );
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    expect(find.byType(CupertinoApp), findsOneWidget);
  });
}
