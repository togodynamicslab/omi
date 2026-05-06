import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart' show FirebaseAuth, User;
import 'package:flutter/foundation.dart';

import 'package:nooto_v2/env_flags.dart';
import 'package:nooto_v2/services/auth_service.dart';
import 'package:nooto_v2/services/notification_service.dart';

/// Wraps Firebase auth state changes so the rest of the app can listen via
/// Provider without depending on Firebase directly. Until Task #12 wires up
/// the v2 Firebase bundle IDs, [kEnableFirebaseAuth] keeps Firebase out of
/// the boot path and we run with a local dev "signed-in" toggle.
class AuthChangeProvider extends ChangeNotifier {
  AuthChangeProvider({NotificationService? notificationService}) : _notificationService = notificationService {
    if (kEnableFirebaseAuth) {
      // Guarded so widget tests can construct this provider without booting
      // a Firebase app — Firebase.initializeApp() is only called in the real
      // app entry points. In tests, fakes that extend this class still need
      // super() to run, but they do not need a live Firebase subscription.
      try {
        _sub = FirebaseAuth.instance.authStateChanges().listen(_onAuthStateChanged);
      } catch (_) {
        _sub = null;
      }
    }
  }

  StreamSubscription<User?>? _sub;
  bool _devSignedIn = false;
  String _devName = 'Dev';
  bool _wasSignedIn = false;
  final NotificationService? _notificationService;

  bool get isSignedIn {
    if (kEnableFirebaseAuth) return AuthService.instance.isSignedIn();
    return _devSignedIn;
  }

  String? get displayName {
    if (kEnableFirebaseAuth) {
      final n = AuthService.instance.currentUser?.displayName?.trim();
      if (n == null || n.isEmpty) return null;
      return n;
    }
    return _devName;
  }

  /// Used by the welcome screen during Phase 1 to skip Firebase auth.
  void devSignIn({String? name}) {
    _devSignedIn = true;
    if (name != null && name.isNotEmpty) _devName = name;
    notifyListeners();
  }

  Future<void> signOut() async {
    if (kEnableFirebaseAuth) {
      // CRITICAL ORDER: delete the FCM token BEFORE Firebase signs out, so
      // the DELETE call has a valid auth token. Multi-user device safety
      // (see design doc: "FCM token cleanup on logout").
      try {
        await _notificationService?.signOut();
      } catch (_) {}
      await AuthService.instance.signOut();
    } else {
      _devSignedIn = false;
      notifyListeners();
    }
  }

  /// Bridges Firebase's auth state stream into ChangeNotifier-land AND fires
  /// the notification-service onSignIn hook on the off→on transition. We
  /// dedupe via [_wasSignedIn] so duplicate state emissions don't re-register
  /// the FCM token. Token-refresh handling is owned by NotificationService.
  void _onAuthStateChanged(User? user) {
    final nowSignedIn = user != null && !user.isAnonymous;
    if (nowSignedIn && !_wasSignedIn) {
      // Fire-and-forget: token registration shouldn't block UI navigation.
      // Errors surface in NotificationService logs.
      unawaited(_notificationService?.onSignIn() ?? Future.value());
    }
    _wasSignedIn = nowSignedIn;
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
