import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:nooto_v2/l10n/gen/app_localizations.dart';
import 'package:nooto_v2/onboarding/onboarding_chat_provider.dart';
import 'package:nooto_v2/onboarding/onboarding_chat_screen.dart';
import 'package:nooto_v2/onboarding/welcome_screen.dart';
import 'package:nooto_v2/providers/auth_provider.dart';
import 'package:nooto_v2/providers/locale_provider.dart';
import 'package:nooto_v2/services/notification_service.dart';
import 'package:nooto_v2/shell/shell_screen.dart';
import 'package:nooto_v2/theme/app_theme.dart';

class MobileApp extends StatelessWidget {
  const MobileApp({super.key});

  @override
  Widget build(BuildContext context) {
    final notifications = context.read<NotificationService>();
    return Consumer<LocaleProvider>(
      builder: (context, locale, _) => MaterialApp(
        title: 'Nooto',
        debugShowCheckedModeBanner: false,
        navigatorKey: notifications.navigatorKey,
        theme: buildAppTheme(),
        locale: locale.locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const _Router(),
      ),
    );
  }
}

class _Router extends StatefulWidget {
  const _Router();

  @override
  State<_Router> createState() => _RouterState();
}

class _RouterState extends State<_Router> {
  bool _drainedDeepLink = false;

  @override
  Widget build(BuildContext context) {
    return Consumer2<AuthChangeProvider, OnboardingChatProvider>(
      builder: (context, auth, chat, _) {
        if (!auth.isSignedIn) return const WelcomeScreen();
        if (!chat.completed) return const OnboardingChatScreen();
        // Cold-start FCM tap: once auth + onboarding are settled and the
        // shell is about to render, drain any queued deep_link captured
        // before the navigator was mounted. See NotificationService.
        if (!_drainedDeepLink) {
          _drainedDeepLink = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            context.read<NotificationService>().drainPendingDeepLink(context);
          });
        }
        return const ShellScreen();
      },
    );
  }
}
