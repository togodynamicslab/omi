import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nooto_v2/inbox/inbox_screen.dart';
import 'package:nooto_v2/services/api_client.dart';

/// Top-level handler required by `firebase_messaging` for background
/// notifications. Must be a top-level function (not a method) because the
/// plugin spawns an isolate to receive the message and needs a static target.
///
/// We don't render anything ourselves here — iOS already shows the system
/// banner from APNS, and we rely on that. The handler exists only so the
/// plugin's contract is satisfied.
@pragma('vm:entry-point')
Future<void> backgroundFcmHandler(RemoteMessage message) async {
  // No-op. Inbox feed is fetched on Inbox open; there's nothing to persist
  // here for v0.
}

/// Slim notifications-as-chat service. Owns:
/// - FCM init + APNS bridging
/// - Token persistence to `POST /v1/users/fcm-token`
/// - Foreground banner via `flutter_local_notifications`
/// - Tap handling (deep_link='inbox' → push InboxScreen)
/// - Sign-in / sign-out lifecycle hooks (called from auth_provider)
///
/// Cold-start FCM tap: when the app launches from a tap on a push, we queue
/// the navigation in [pendingDeepLink] until the home renders + auth resolves.
/// `MobileApp`/`ShellScreen` consults this on first build and drains it.
class NotificationService extends ChangeNotifier {
  NotificationService({
    required ApiClient client,
    FirebaseMessaging? messaging,
    FlutterLocalNotificationsPlugin? localNotifications,
    GlobalKey<NavigatorState>? navigatorKey,
  }) : _client = client,
       _messagingOverride = messaging,
       _localNotifications = localNotifications ?? FlutterLocalNotificationsPlugin(),
       navigatorKey = navigatorKey ?? GlobalKey<NavigatorState>();

  final ApiClient _client;
  // Lazily resolve `FirebaseMessaging.instance` so tests can construct the
  // service without booting a Firebase app. Production callers omit
  // [messaging] and the getter falls back to the real plugin instance the
  // first time `initialize()` is invoked.
  final FirebaseMessaging? _messagingOverride;
  FirebaseMessaging get _messaging => _messagingOverride ?? FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _localNotifications;

  /// Test seam: when set, the service uses this navigator instead of pushing
  /// via [navigatorKey]. Production callers omit and the service installs
  /// itself on `MaterialApp(navigatorKey: ...)`.
  final GlobalKey<NavigatorState> navigatorKey;

  bool _initialized = false;
  StreamSubscription<RemoteMessage>? _foregroundSub;
  StreamSubscription<RemoteMessage>? _tapSub;
  StreamSubscription<String>? _tokenRefreshSub;

  /// Deep-link captured from a cold-start FCM tap. Drained by the router once
  /// auth + home are ready. Null when the app launched normally.
  String? pendingDeepLink;

  /// User-visible toggle stored in SharedPreferences (kept simple — Hive
  /// boxes are scoped by domain). True (the default) means register tokens
  /// on sign-in; false means skip registration even if iOS has granted
  /// permission. Mirrors the gating in the design doc's settings row.
  static const String _toggleKey = 'notifications.enabled';
  static const String _deviceIdKey = 'notifications.device_id';
  static const String _lastTokenKey = 'notifications.last_token';
  static const String _unreadInboxKey = 'notifications.unread_inbox_count';

  /// Cached unread count for the Inbox surface. Hydrated from prefs on
  /// [initialize] so a cold start doesn't show 0 until the first FCM event.
  int _unreadInboxCount = 0;
  int get unreadInboxCount => _unreadInboxCount;
  bool get hasUnreadInbox => _unreadInboxCount > 0;

  /// Cleared by [InboxScreen] on mount. Persists across app restarts.
  Future<void> markInboxRead() async {
    if (_unreadInboxCount == 0) return;
    _unreadInboxCount = 0;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_unreadInboxKey, 0);
    notifyListeners();
  }

  Future<void> _bumpUnreadInbox() async {
    _unreadInboxCount += 1;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_unreadInboxKey, _unreadInboxCount);
    notifyListeners();
  }

  Future<bool> isToggleEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_toggleKey) ?? true;
  }

  Future<void> setToggleEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_toggleKey, value);
    notifyListeners();
  }

  /// One-shot init — wires platform handlers, registers the background
  /// handler, and listens for FCM events. Safe to call multiple times.
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    // Hydrate the unread badge counter so the chat tab dot survives cold start.
    final prefs = await SharedPreferences.getInstance();
    _unreadInboxCount = prefs.getInt(_unreadInboxKey) ?? 0;
    if (_unreadInboxCount > 0) notifyListeners();

    // Local notifications channel — used by the foreground handler to render
    // an in-app banner since iOS suppresses the OS banner while the app is
    // active. Initialized once.
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings();
    await _localNotifications.initialize(
      const InitializationSettings(android: androidInit, iOS: iosInit),
      onDidReceiveNotificationResponse: (details) {
        // Tapping the in-app banner routes to Inbox just like an OS-level tap.
        _handleDeepLink(_extractDeepLinkFromPayload(details.payload));
      },
    );

    // Background handler must be registered BEFORE listeners.
    FirebaseMessaging.onBackgroundMessage(backgroundFcmHandler);

    // Foreground: show a local banner + bump badge.
    _foregroundSub = FirebaseMessaging.onMessage.listen(_onForegroundMessage);

    // OS-level tap on background notification → app comes to foreground.
    _tapSub = FirebaseMessaging.onMessageOpenedApp.listen(_onMessageOpenedApp);

    // Cold-start: if the app launched from a tap, capture the deep-link so
    // the router can drain it after auth + home render. We do NOT navigate
    // here — `MobileApp` does not exist yet at this point in the boot.
    final initialMessage = await _messaging.getInitialMessage();
    if (initialMessage != null) {
      pendingDeepLink = _extractDeepLink(initialMessage);
      // The user is heading to Inbox; the screen will mark-read on mount,
      // so don't bump the badge here.
    }

    // Token refresh: re-persist on rotation. Backend upserts by device_key
    // so this is idempotent.
    _tokenRefreshSub = _messaging.onTokenRefresh.listen((token) async {
      await _persistToken(token);
    });
  }

  /// Called from auth_provider when a user signs in. No-op when the toggle
  /// is off — matches the design doc's "in-app toggle off" behavior.
  Future<void> onSignIn() async {
    if (!await isToggleEnabled()) return;
    await initialize();
    final granted = await _requestPermission();
    if (!granted) return;
    final token = await _getToken();
    if (token == null) return;
    await _persistToken(token);
  }

  /// Called from auth_provider BEFORE the actual Firebase sign-out, so the
  /// DELETE has a valid auth token. Best-effort: errors here don't block the
  /// sign-out flow.
  /// In-app dogfood affordance: ask the backend to send the signed-in user a
  /// test notification (writes to Inbox + fires OS push). Surfaces the
  /// backend's `detail` field on rate-limit / failure so the caller can show
  /// it in a snackbar.
  Future<void> sendTestNotification() async {
    await _client.post('v1/users/test-notification', body: const <String, dynamic>{});
  }

  Future<void> signOut() async {
    try {
      await _client.delete('v1/users/fcm-token', headers: await _deviceHeaders());
    } catch (e) {
      debugPrint('[NotificationService] signOut delete failed: $e');
    }
    try {
      await _messaging.deleteToken();
    } catch (_) {}
    // Clear the dedup cache so the next user signing in on this device
    // re-registers against their uid. Same FCM token mapped to a different
    // uid otherwise gets dedup'd and the new mapping never persists.
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_lastTokenKey);
  }

  /// Drains [pendingDeepLink] and pushes the matching screen. Caller is the
  /// router (post-auth, post-home-render). Idempotent.
  void drainPendingDeepLink(BuildContext context) {
    final link = pendingDeepLink;
    if (link == null) return;
    pendingDeepLink = null;
    _navigateForDeepLink(context, link);
  }

  Future<bool> _requestPermission() async {
    if (Platform.isIOS) {
      final settings = await _messaging.requestPermission(alert: true, badge: true, sound: true);
      return settings.authorizationStatus == AuthorizationStatus.authorized ||
          settings.authorizationStatus == AuthorizationStatus.provisional;
    }
    // Android 13+ requires runtime permission too — firebase_messaging
    // forwards to the system dialog when we call requestPermission.
    final settings = await _messaging.requestPermission();
    return settings.authorizationStatus == AuthorizationStatus.authorized;
  }

  Future<String?> _getToken() async {
    try {
      if (Platform.isIOS) {
        // APNS token can land late on first launch; legacy app pattern is to
        // poll once before requesting the FCM token to avoid a no-token
        // window. See firebase/flutterfire#12244.
        await _messaging.getAPNSToken();
      }
      return await _messaging.getToken();
    } catch (e) {
      debugPrint('[NotificationService] getToken failed: $e');
      return null;
    }
  }

  Future<void> _persistToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_lastTokenKey) == token) return;
    try {
      String timeZone = 'UTC';
      try {
        timeZone = await FlutterTimezone.getLocalTimezone();
      } catch (_) {}
      await _client.post(
        'v1/users/fcm-token',
        body: {'fcm_token': token, 'time_zone': timeZone},
        headers: await _deviceHeaders(),
      );
      await prefs.setString(_lastTokenKey, token);
    } catch (e) {
      debugPrint('[NotificationService] persistToken failed: $e');
    }
  }

  Future<Map<String, String>> _deviceHeaders() async {
    final platform = Platform.isIOS
        ? 'ios'
        : Platform.isAndroid
        ? 'android'
        : 'unknown';
    final hash = await _deviceIdHash();
    return {'X-App-Platform': platform, 'X-Device-Id-Hash': hash};
  }

  /// Stable per-install device id hash. Generated once on first call and
  /// stored in SharedPreferences. We hash a random uuid (rather than a real
  /// device id) so logs don't leak device identifiers and so the value is
  /// stable across permission/account changes within the app install.
  Future<String> _deviceIdHash() async {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(_deviceIdKey);
    if (cached != null && cached.isNotEmpty) return cached;
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    final hash = sha256.convert(bytes).toString().substring(0, 16);
    await prefs.setString(_deviceIdKey, hash);
    return hash;
  }

  Future<void> _onForegroundMessage(RemoteMessage message) async {
    // Bump the inbox badge on every inbound push regardless of toggle state —
    // even with OS push silenced, the message landed in the user's inbox feed
    // and the tab dot is the in-app signal that something new arrived.
    if (_isInboxBound(message)) {
      await _bumpUnreadInbox();
    }
    // Respect the user's in-app toggle: if notifications are off the OS push
    // never arrives, but the FCM stream can still fire (e.g. if the toggle
    // was flipped after permission was already granted).
    if (!await isToggleEnabled()) return;
    final data = message.data;
    final notification = message.notification;
    final title = notification?.title ?? data['title']?.toString() ?? '';
    final body = notification?.body ?? data['body']?.toString() ?? '';
    if (title.isEmpty && body.isEmpty) return;

    const androidDetails = AndroidNotificationDetails(
      'inbox_default',
      'Inbox',
      channelDescription: 'Notifications from Nooto apps and Brief',
      importance: Importance.high,
      priority: Priority.high,
    );
    const iosDetails = DarwinNotificationDetails(presentAlert: true, presentBadge: true, presentSound: true);
    final id = message.messageId?.hashCode ?? DateTime.now().millisecondsSinceEpoch.remainder(0x7fffffff);
    _localNotifications.show(
      id,
      title,
      body,
      const NotificationDetails(android: androidDetails, iOS: iosDetails),
      payload: jsonEncode(data),
    );
  }

  void _onMessageOpenedApp(RemoteMessage message) {
    final deepLink = _extractDeepLink(message);
    _handleDeepLink(deepLink);
  }

  void _handleDeepLink(String? deepLink) {
    if (deepLink == null) return;
    final ctx = navigatorKey.currentContext;
    if (ctx == null) {
      // Not mounted yet → queue for cold-start drain.
      pendingDeepLink = deepLink;
      return;
    }
    _navigateForDeepLink(ctx, deepLink);
  }

  void _navigateForDeepLink(BuildContext context, String deepLink) {
    if (deepLink == 'inbox') {
      Navigator.of(context, rootNavigator: true).push(InboxScreen.route());
    }
    // Future: handle more deep links here. Unknown values silently ignored.
  }

  String? _extractDeepLink(RemoteMessage message) {
    final raw = message.data['deep_link'];
    if (raw is String && raw.isNotEmpty) return raw;
    return null;
  }

  bool _isInboxBound(RemoteMessage message) {
    final raw = message.data['deep_link'];
    return raw is String && raw == 'inbox';
  }

  String? _extractDeepLinkFromPayload(String? payload) {
    if (payload == null || payload.isEmpty) return null;
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map && decoded['deep_link'] is String) {
        return decoded['deep_link'] as String;
      }
    } catch (_) {}
    return null;
  }

  @override
  void dispose() {
    _foregroundSub?.cancel();
    _tapSub?.cancel();
    _tokenRefreshSub?.cancel();
    super.dispose();
  }
}
