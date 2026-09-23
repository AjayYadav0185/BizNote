import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';

import 'providers/note_provider.dart';
import 'database/database_helper.dart';
import 'screens/home_screen.dart';
import 'services/background_service.dart';
import 'services/location_service.dart';

/// Boots the app and hooks the background service into the native OS layer.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Desktop/web need an FFI-backed sqlite factory, otherwise every database
  // call fails silently (caught + debugPrint) and no note is ever saved.
  await DatabaseHelper.ensureInitialized();

  // Registers the Dart entry points of the persistent service. This has to run
  // before `runApp` so the native side always holds the newest callbacks.
  // Android/iOS only: elsewhere the plugin throws instead of starting anything.
  if (isBackgroundTrackingSupported) {
    try {
      await initializeBackgroundService();
    } catch (error) {
      debugPrint('[App] background service unavailable: $error');
    }
  }

  runApp(const BizNoteApp());
}

/// Root widget: creates the [NoteProvider] that bridges SQLite to the UI and
/// asks for the location permissions the background loop needs.
class BizNoteApp extends StatefulWidget {
  const BizNoteApp({super.key});

  @override
  State<BizNoteApp> createState() => _BizNoteAppState();
}

class _BizNoteAppState extends State<BizNoteApp> {
  /// Used to show the permission dialogs from above the [Navigator].
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  late final NoteProvider _noteProvider;

  @override
  void initState() {
    super.initState();
    _noteProvider = NoteProvider();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _bootstrapPermissions(),
    );
  }

  @override
  void dispose() {
    _noteProvider.dispose();
    super.dispose();
  }

  /// Requests "while using the app" access and then escalates to
  /// "Allow all the time", which is what the 15 minute loop needs in order to
  /// run while the app is closed.
  Future<void> _bootstrapPermissions() async {
    // Location tracking only exists on Android/iOS: elsewhere there is nothing
    // to grant and no tracker update to trigger, so no dialog is shown either.
    if (!isBackgroundTrackingSupported) {
      return;
    }
    try {
      final bool foregroundGranted =
          await LocationService.ensureForegroundPermission();
      if (!mounted) {
        return;
      }

      if (!foregroundGranted) {
        await _showPermissionDialog(
          title: 'Location access is required',
          message: 'BizNote keeps the "Live Location Tracker" note up to date '
              'with your position. Enable location access in Settings.',
        );
        return;
      }

      final bool backgroundGranted =
          await LocationService.ensureBackgroundPermission();
      if (!mounted) {
        return;
      }

      // Give the user an immediate first fix instead of waiting 15 minutes.
      _noteProvider.requestImmediateLocationUpdate();

      if (!backgroundGranted) {
        await _showPermissionDialog(
          title: 'Allow location access "Always"?',
          message: 'Choose "Always" so the tracked note keeps updating while '
              'the app is closed. Otherwise it only refreshes while you are '
              'using the app.',
        );
      }
    } catch (error) {
      debugPrint('[App] permission bootstrap failed: $error');
    }
  }

  /// iOS style permission dialog with a shortcut to the system settings.
  Future<void> _showPermissionDialog({
    required String title,
    required String message,
  }) async {
    final BuildContext? dialogContext = _navigatorKey.currentContext;
    if (dialogContext == null) {
      return;
    }

    await showCupertinoDialog<void>(
      context: dialogContext,
      builder: (BuildContext context) => CupertinoAlertDialog(
        title: Text(title),
        content: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(message),
        ),
        actions: <Widget>[
          CupertinoDialogAction(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Not now'),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () async {
              Navigator.of(context).pop();
              await LocationService.openAppSettings();
            },
            child: const Text('Open Settings'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<NoteProvider>.value(
      value: _noteProvider,
      child: CupertinoApp(
        title: 'Notes',
        debugShowCheckedModeBanner: false,
        navigatorKey: _navigatorKey,
        theme: const CupertinoThemeData(
          brightness: Brightness.light,
          primaryColor: CupertinoColors.systemBlue,
          scaffoldBackgroundColor: Color(0xFFFFFEFE),
          barBackgroundColor: Color(0xFFF2F2F7),
          textTheme: CupertinoTextThemeData(
            navTitleTextStyle: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: CupertinoColors.black,
            ),
            navLargeTitleTextStyle: TextStyle(
              fontSize: 34,
              fontWeight: FontWeight.bold,
              color: CupertinoColors.black,
            ),
          ),
        ),
        home: const HomeScreen(),
      ),
    );
  }
}
