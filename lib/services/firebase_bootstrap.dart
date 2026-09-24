import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

/// The one and only Firebase entry point of the app.
///
/// Firebase has to be initialised **once per isolate**: the UI isolate does it
/// lazily on the first cloud write, the background location service does its
/// own when it mirrors a fix. [ensureInitialized] caches the result — success
/// *and* failure — per isolate, so a missing configuration is logged once
/// instead of on every write.
///
/// The lookup order is deliberate:
///  1. `Firebase.initializeApp()` with no options, which on Android/iOS builds
///     the default app from the resources the Google Services plugin generated
///     out of `google-services.json` / `GoogleService-Info.plist`, and on the
///     web reuses the app an inline `firebase.initializeApp()` in `index.html`
///     may already have created.
///  2. [fallbackOptions], the values of `android/app/google-services.json`
///     spelled out in Dart. This is what makes the cloud mirror work on
///     desktop, on the web and on an Android build that has no
///     `google-services.json` yet — and it pins [databaseUrl], because the
///     Android SDK otherwise guesses `https://<project-id>-default-rtdb
///     .firebaseio.com`, which does not exist for this project (the database
///     lives in `asia-southeast1`).
class FirebaseBootstrap {
  FirebaseBootstrap._();

  /// Realtime Database of the BizNote Firebase project.
  static const String databaseUrl =
      'https://bizarohq-b92c8-default-rtdb.asia-southeast1.firebasedatabase.app';

  /// Project values copied from `android/app/google-services.json`.
  ///
  /// Only used when the platform has no usable native configuration. On iOS the
  /// Android app id in here is meaningless, so a real `GoogleService-Info.plist`
  /// (or a matching web app registration) is what step 1 is for.
  static const FirebaseOptions fallbackOptions = FirebaseOptions(
    apiKey: 'AIzaSyBLXcEWIGyoPZyPGTfpTiqgtERgqO04ocg',
    appId: '1:914724512933:android:6bae8470538e660b7d994c',
    messagingSenderId: '914724512933',
    projectId: 'bizarohq-b92c8',
    storageBucket: 'bizarohq-b92c8.firebasestorage.app',
    databaseURL: databaseUrl,
  );

  /// Cached initialization of the current isolate (`null` = not tried yet).
  static Future<bool>? _initialization;

  /// True once Firebase is ready to be used **in this isolate**.
  ///
  /// Never throws: every failure is logged and reported as `false` so callers
  /// can stay fail-soft (the local SQLite write must never depend on the
  /// network).
  static Future<bool> ensureInitialized() => _initialization ??= _initialize();

  static Future<bool> _initialize() async {
    try {
      await Firebase.initializeApp();
    } catch (error) {
      debugPrint('[Firebase] platform configuration unusable: $error');
      try {
        await Firebase.initializeApp(options: fallbackOptions);
      } catch (fallbackError) {
        debugPrint(
          '[Firebase] initialization failed — add '
          'android/app/google-services.json for com.biznote.notepad_app '
          '(web/desktop need a Firebase web app in the same project) · '
          '$fallbackError',
        );
        return false;
      }
    }

    final String? configuredUrl = Firebase.app().options.databaseURL;
    debugPrint(
      '[Firebase] initialized · databaseURL=${configuredUrl ?? databaseUrl}',
    );
    if (configuredUrl == null) {
      debugPrint(
        '[Firebase] google-services.json has no firebase_url — writes may go '
        'to the wrong region. Re-download the file after creating the '
        'Realtime Database.',
      );
    }
    return true;
  }
}
