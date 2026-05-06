import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';

import 'package:nooto_v2/apps/apps_provider.dart';
import 'package:nooto_v2/apps/apps_storage.dart';
import 'package:nooto_v2/chat/chat_provider.dart';
import 'package:nooto_v2/chat/chat_storage.dart';
import 'package:nooto_v2/library/conversations_provider.dart';
import 'package:nooto_v2/library/library_provider.dart';
import 'package:nooto_v2/env_flags.dart';
import 'package:nooto_v2/firebase_options.dart';
import 'package:nooto_v2/home/home_storage.dart';
import 'package:nooto_v2/mobile_app.dart';
import 'package:nooto_v2/onboarding/onboarding_chat_provider.dart';
import 'package:nooto_v2/plan/plan_guidance_provider.dart';
import 'package:nooto_v2/plan/plan_storage.dart';
import 'package:nooto_v2/providers/action_items_provider.dart';
import 'package:nooto_v2/providers/auth_provider.dart';
import 'package:nooto_v2/providers/locale_provider.dart';
import 'package:nooto_v2/providers/pendant_provider.dart';
import 'package:nooto_v2/providers/pendant_stt_provider.dart';
import 'package:nooto_v2/services/api_client.dart';
import 'package:nooto_v2/services/app_links_service.dart';
import 'package:nooto_v2/services/ble/omi_pendant.dart';
import 'package:nooto_v2/services/ble/socket_streamer.dart';
import 'package:nooto_v2/services/chat_service.dart';
import 'package:nooto_v2/services/notification_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kEnableFirebaseAuth) {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  }
  await Hive.initFlutter();
  await Future.wait([
    Hive.openBox<Map>(HomeBoxes.cards),
    Hive.openBox<Map>(HomeBoxes.brief),
    Hive.openBox<Map>(HomeBoxes.actions),
    Hive.openBox<Map>(ChatBoxes.messages),
    Hive.openBox<Map>(ChatBoxes.sessions),
    Hive.openBox<Map>(AppsBoxes.prefs),
    Hive.openBox<dynamic>(PlanBoxes.prefs),
    Hive.openBox<dynamic>(OmiPendant.hiveBoxName),
  ]);
  // One-shot sweep of action-log entries from retired card kinds (today/jira-stuck).
  // Idempotent — safe to run every launch. See lib/home/home_storage.dart.
  final swept = await sweepRetiredHomeActionLogEntries();
  if (swept > 0) debugPrint('[HomeStorage] swept $swept retired action-log entries');
  final localeProvider = LocaleProvider();
  await localeProvider.hydrate();
  final apiClient = ApiClient();
  final chatService = ChatService(client: apiClient);
  final notificationService = NotificationService(client: apiClient);
  // Initialize FCM listeners + capture any cold-start deep-link payload
  // before runApp(). Token registration waits until sign-in (onSignIn).
  if (kEnableFirebaseAuth) {
    unawaited(notificationService.initialize());
  }
  final appLinksService = AppLinksService();
  // Process-level singletons for the pendant recording stack (Lane C).
  // Per Decision 1C in the eng-review test plan, OmiPendant and
  // SocketStreamer survive Provider tree rebuilds; PendantProvider is the
  // thin ChangeNotifier adapter wired into the Provider tree below.
  final omiPendant = OmiPendant.instance;
  final socketStreamer = SocketStreamer();
  final pendantProvider = PendantProvider(pendant: omiPendant, socket: socketStreamer);
  // Cold-start auto-reconnect: read last-paired pendant from Hive and
  // attempt to reconnect. Non-blocking — the UI can render before BLE
  // resolves.
  unawaited(pendantProvider.bootstrap());
  // App-startup deep-link wiring. AppsProvider drains the cold-start link
  // (captured before apps load) and listens for warm links thereafter. The
  // AppsProvider construction below grabs both via the closure.
  final appsProvider = AppsProvider(client: apiClient);
  // Cold-start: capture any pending nooto:// URI iOS handed us on launch.
  // AppsProvider.load() drains it after first successful apps fetch.
  unawaited(
    appLinksService.loadColdStartLink().then((link) async {
      if (link is AppSetupComplete) {
        // Wait for apps to load before retrying enable, so the lookup in
        // handleSetupComplete finds the app row.
        while (!appsProvider.hasFetched) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        appsProvider.handleSetupComplete(link.appId, link.status);
      }
    }),
  );
  // Warm path: every subsequent nooto:// URL while the app is running.
  appLinksService.linkStream.listen(
    (link) {
      debugPrint('[main] warm deep-link received: $link');
      if (link is AppSetupComplete) {
        debugPrint('[main] → dispatching handleSetupComplete(${link.appId}, ${link.status})');
        appsProvider.handleSetupComplete(link.appId, link.status);
      }
    },
    onError: (e) {
      debugPrint('[main] linkStream error: $e');
    },
  );
  runApp(
    MultiProvider(
      providers: [
        Provider<ApiClient>.value(value: apiClient),
        ChangeNotifierProvider<NotificationService>.value(value: notificationService),
        ChangeNotifierProvider(create: (_) => AuthChangeProvider(notificationService: notificationService)),
        ChangeNotifierProvider(create: (_) => OnboardingChatProvider()),
        ChangeNotifierProvider.value(value: localeProvider),
        ChangeNotifierProvider(create: (_) => ActionItemsProvider(client: apiClient)),
        ChangeNotifierProvider.value(value: appsProvider),
        ChangeNotifierProvider(create: (_) => LibraryProvider(client: apiClient)),
        ChangeNotifierProvider(create: (_) => ConversationsProvider(client: apiClient)),
        Provider<ChatService>.value(value: chatService),
        ChangeNotifierProvider(create: (_) => ChatProvider(service: chatService)),
        ChangeNotifierProvider(create: (_) => PlanGuidanceProvider(service: chatService)),
        ChangeNotifierProvider<PendantProvider>.value(value: pendantProvider),
        // On-device live-transcription pipe: Pendant Opus → Dart decode →
        // method channel → iOS SFSpeechRecognizer (see PendantSttProvider).
        // Driven by PendantProvider.state (start on `live`, stop elsewhere)
        // and LocaleProvider (drives SFSpeechRecognizer's locale, e.g.
        // `en_US` vs `pt_BR`).
        ChangeNotifierProxyProvider2<PendantProvider, LocaleProvider, PendantSttProvider>(
          create: (_) => PendantSttProvider(),
          update: (_, pendant, locale, stt) {
            stt!.onLocaleChanged(locale.locale);
            stt.onPendantStateChanged(pendant.info.state, pendant.info.codec);
            return stt;
          },
        ),
      ],
      child: const MobileApp(),
    ),
  );
}
