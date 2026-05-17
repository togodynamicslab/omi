// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appName => 'Nooto';

  @override
  String welcomeBrandLine(String brand) {
    return 'Welcome to $brand';
  }

  @override
  String get welcomeTaglinePrefix => 'Personal intelligence that turns ';

  @override
  String get welcomeTaglineEmphasis => 'thought to action.';

  @override
  String get welcomeContinueWithApple => 'Continue with Apple';

  @override
  String get welcomeContinueWithGoogle => 'Continue with Google';

  @override
  String get welcomeWaitingForBrowser => 'Waiting for browser…';

  @override
  String get welcomeAgreeFooter =>
      'By continuing you agree to our Terms and Privacy Policy.';

  @override
  String get onboardingPromptHintTyped => 'Type your answer…';

  @override
  String get onboardingPromptHintTap => 'Tap an option above to continue';

  @override
  String get onboardingOpenerName => 'Hey — what should I call you?';

  @override
  String onboardingOpenerLanguage(String name) {
    return 'Nice to meet you, $name. What language do you want me to use?';
  }

  @override
  String get onboardingOpenerMicrophone =>
      'I\'ll need your mic to listen for what matters.';

  @override
  String get onboardingOpenerNotifications =>
      'Mind if I ping you when something needs your attention?';

  @override
  String get onboardingOpenerBackground =>
      'I work best if I can keep listening in the background.';

  @override
  String get onboardingOpenerLocation =>
      'Want me to tag where things happen? Optional — feel free to skip.';

  @override
  String get onboardingOpenerDevice =>
      'Have a Nooto device on you? We can wire it up later — pairing arrives in the next phase.';

  @override
  String get onboardingOpenerSpeechProfile =>
      'Let me learn your voice so I can tell you apart from the rest of the world.';

  @override
  String get onboardingOpenerAcknowledge => 'All set. Let\'s go.';

  @override
  String get onboardingSkipped => 'Sure, we can do that later.';

  @override
  String get onboardingChipMoreLanguages => 'More languages…';

  @override
  String get onboardingChipSkipForNow => 'Skip for now';

  @override
  String get onboardingChipPairLater => 'I\'ll pair it later';

  @override
  String get onboardingAckLetsGo => 'Let\'s go';

  @override
  String get onboardingAckGotIt => 'Got it';

  @override
  String get onboardingPermissionAllow => 'Allow';

  @override
  String get onboardingPermissionPending => 'Pending';

  @override
  String get onboardingPermissionGranted => 'Granted';

  @override
  String get onboardingPermissionDenied => 'Denied';

  @override
  String get onboardingPermissionDeniedAction => 'Open settings';

  @override
  String get onboardingPermissionLabelMicrophone => 'Microphone access';

  @override
  String get onboardingPermissionLabelMicrophoneHelper =>
      'Audio is processed on your device; only the transcript leaves.';

  @override
  String get onboardingPermissionLabelNotifications => 'Notification access';

  @override
  String get onboardingPermissionLabelNotificationsHelper =>
      'Quiet, useful nudges only — never noise.';

  @override
  String get onboardingPermissionLabelBackground => 'Background activity';

  @override
  String get onboardingPermissionLabelBackgroundHelper =>
      'Lets Nooto stay alive while you\'re using other apps.';

  @override
  String get onboardingPermissionLabelLocation => 'Location';

  @override
  String get onboardingPermissionLabelLocationHelper =>
      'Tags conversations with where they happened. Optional.';

  @override
  String get onboardingSpeechCardTitle => 'Read this aloud';

  @override
  String get onboardingSpeechCardBody =>
      'Whenever you\'re ready, hold the button and read this in a normal voice for about five seconds.';

  @override
  String get onboardingSpeechCardSample =>
      'Hi, I\'m getting Nooto set up. This is what my voice sounds like in a normal room.';

  @override
  String get onboardingSpeechRecording => 'Listening…';

  @override
  String get onboardingSpeechCaptured => 'Voice captured ✓';

  @override
  String get onboardingSpeechSkip => 'Skip for now';

  @override
  String get shellTabHome => 'Home';

  @override
  String get shellTabChat => 'Chat';

  @override
  String get shellTabLibrary => 'Library';

  @override
  String get shellTabPlan => 'Plan';

  @override
  String get shellTabApps => 'Apps';

  @override
  String shellComingSoonTitle(String tab) {
    return '$tab arrives next';
  }

  @override
  String get shellComingSoonBody =>
      'This screen lands in a future phase. For now, the morning brief and today\'s commitments are on Home.';

  @override
  String get todayCardHeader => 'Today';

  @override
  String todayCardCountPartial(int visible, int total) {
    return '$visible of $total';
  }

  @override
  String todayCardCountFull(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count items',
      one: '1 item',
    );
    return '$_temp0';
  }

  @override
  String get todayCardSeeAll => 'See all';

  @override
  String get todayCardSeeAllSemantics => 'See all action items, opens Plan tab';

  @override
  String get summaryTemplate => 'Summary template';

  @override
  String summarizedBy(String name) {
    return 'Summarized by $name';
  }

  @override
  String get noSummaryForApp =>
      'No summary available — tap to choose another app';

  @override
  String get reprocessingConversation => 'Reprocessing…';

  @override
  String get reprocessFailed => 'Couldn\'t reprocess. Try again.';

  @override
  String get chooseSummarizationApp => 'Choose a summarization app';

  @override
  String get currentlyUsing => 'Currently using';

  @override
  String get suggestedForThisConversation => 'Suggested for this conversation';

  @override
  String get summarizedAppsSuggestedSection => 'Suggested';

  @override
  String get summarizedAppsAvailableSection => 'Installed';

  @override
  String get summarizedAppsEmpty => 'No apps installed yet';

  @override
  String get summarizeWithApp => 'Summarize with an app';

  @override
  String get pendantPillLive => 'Live';

  @override
  String get pendantPillConnecting => 'Connecting…';

  @override
  String get pendantPillReconnecting => 'Reconnecting';

  @override
  String pendantPillOfflineSince(String time) {
    return 'Offline since $time';
  }

  @override
  String get pendantPillPaused => 'Paused';

  @override
  String get pendantPairTitle => 'Pair your pendant';

  @override
  String get pendantPairConnecting => 'Setting up your pendant…';

  @override
  String get pendantPairIncompatible =>
      'This pendant doesn\'t expose the right audio service. Make sure your firmware is up to date.';

  @override
  String get pendantPairPermissionDenied =>
      'Bluetooth and microphone access are needed to pair.';

  @override
  String get pendantPairOpenSettings => 'Open Settings';

  @override
  String get pendantPairTryAgain => 'Try again';

  @override
  String get pendantVoiceCardConnectTitle => 'Connect your pendant';

  @override
  String get pendantVoiceCardConnectBody => 'Tap to pair your pendant.';

  @override
  String pendantVoiceCardOfflineTitle(String time) {
    return 'Your pendant disconnected at $time.';
  }

  @override
  String get pendantVoiceCardOfflineBody => 'Tap to reconnect.';

  @override
  String pendantPausePrompt(int seconds) {
    return 'Pause pendant for ${seconds}s while we record your voice?';
  }

  @override
  String get pendantPauseConfirm => 'Pause and continue';

  @override
  String get pendantOnboardingTurnText =>
      'Pair your pendant when you\'re ready. Hold it near your phone so I can find it.';

  @override
  String get pendantScreenTitle => 'Pendant';

  @override
  String get pendantScreenMenuItem => 'Pendant';

  @override
  String get pendantScreenPairCta => 'Pair pendant';

  @override
  String get pendantScreenPairHint => 'Hold your pendant close.';

  @override
  String get pendantScreenConnectedHeader => 'Connected';

  @override
  String get pendantScreenDisconnectCta => 'Disconnect';

  @override
  String get pendantScreenReconnectCta => 'Reconnect';

  @override
  String get pendantScreenInterruptedExplain =>
      'Paused while another audio session is active.';

  @override
  String pendantScreenBatteryLabel(int percent) {
    return '$percent% battery';
  }

  @override
  String pendantScreenCodecLabel(String codec) {
    return 'Codec: $codec';
  }

  @override
  String get settingsScreenTitle => 'Settings';

  @override
  String get settingsMenuItem => 'Settings';

  @override
  String get settingsDevModeHeader => 'Developer Mode';

  @override
  String get settingsPermissionsLabel => 'Permissions';

  @override
  String get settingsPermissionMicrophone => 'Microphone';

  @override
  String get settingsPermissionBluetooth => 'Bluetooth';

  @override
  String get settingsPermissionNotifications => 'Notifications';

  @override
  String get settingsPermissionLocation => 'Location';

  @override
  String get settingsPendantLabel => 'Pendant';

  @override
  String get settingsAuthLabel => 'Account';

  @override
  String settingsAuthSignedInAs(String email) {
    return 'Signed in as $email';
  }

  @override
  String get settingsAuthNotSignedIn => 'Not signed in';

  @override
  String get settingsBuildLabel => 'Build';

  @override
  String get settingsActionOpenIosSettings => 'Open iOS Settings';

  @override
  String get settingsActionResetOnboarding => 'Reset onboarding';

  @override
  String get settingsPermissionStatusGranted => 'Granted';

  @override
  String get settingsPermissionStatusDenied => 'Denied';

  @override
  String get settingsPermissionStatusPermanentlyDenied => 'Permanently denied';

  @override
  String get settingsPermissionStatusRestricted => 'Restricted';

  @override
  String get settingsPermissionStatusLimited => 'Limited';

  @override
  String get settingsPermissionOpenSettingsCta => 'Open Settings';

  @override
  String get pendantScreenDefaultDeviceName => 'Nooto pendant';

  @override
  String get pendantCeremonySearching => 'Searching.';

  @override
  String get pendantCeremonyFound => 'Found you.';

  @override
  String get pendantCeremonySettingUp => 'Setting up.';

  @override
  String pendantCeremonyGreetingNamed(String name) {
    return 'Hello, $name.';
  }

  @override
  String get pendantCeremonyGreetingFallback => 'Hello.';

  @override
  String get pendantCeremonyTimeout =>
      'I can\'t see your pendant from here. Hold it close and let\'s try again.';

  @override
  String get pendantCeremonyBleError =>
      'Something interrupted the connection. Let\'s try once more.';

  @override
  String get pendantCeremonyIncompatible =>
      'This pendant doesn\'t speak my language. Make sure your firmware is up to date.';

  @override
  String get pendantCeremonyBluetoothOff =>
      'Bluetooth\'s off. Turn it on in Control Center and let\'s try again.';

  @override
  String get pendantScreenBackLabel => 'Back';

  @override
  String get inboxEmptyTitle => 'Nothing here yet';

  @override
  String get inboxEmptyDescription =>
      'Your apps will message you here. Connect an app to get started.';

  @override
  String get inboxEmptyAction => 'Browse apps';

  @override
  String get inboxErrorTitle => 'Can\'t reach server';

  @override
  String get inboxErrorRetry => 'Retry';

  @override
  String get inboxScreenTitle => 'Inbox';

  @override
  String get inboxFilterAll => 'All';

  @override
  String get inboxBubbleCopy => 'Copy';

  @override
  String get inboxBubbleShare => 'Share';

  @override
  String get inboxBubbleCancel => 'Cancel';

  @override
  String get drawerInboxLabel => 'Inbox';

  @override
  String get settingsNotificationsLabel => 'Notifications';

  @override
  String get settingsNotificationsStateOn => 'On';

  @override
  String get settingsNotificationsStateOff => 'Off — tap to enable';

  @override
  String get settingsNotificationsStateOpenSettings =>
      'Open Settings to enable';

  @override
  String get settingsCategoryAccount => 'Account';

  @override
  String get settingsCategoryAccountDescription => 'Sign-in, identity';

  @override
  String get settingsCategoryPermissions => 'Permissions';

  @override
  String get settingsCategoryPermissionsDescription =>
      'Microphone, Bluetooth, Notifications, Location';

  @override
  String get settingsCategoryPendant => 'Pendant';

  @override
  String get settingsCategoryPendantDescription =>
      'Connection status, codec, battery';

  @override
  String get settingsCategoryNotifications => 'Notifications';

  @override
  String get settingsCategoryNotificationsDescription =>
      'Apps and Brief alerts';

  @override
  String get settingsCategoryAbout => 'About';

  @override
  String get settingsCategoryAboutDescription => 'Build version, support';

  @override
  String get settingsCategoryDeveloper => 'Developer';

  @override
  String get settingsCategoryDeveloperDescription => 'Diagnostics and reset';

  @override
  String get settingsSearchPlaceholder => 'Search settings';

  @override
  String get settingsSearchEmpty => 'No matching settings';

  @override
  String get settingsNotificationsDescription =>
      'Apps and Brief send proactive messages to your Inbox. Turn off to silence the device push without losing the in-app feed.';

  @override
  String get settingsAccountSignOut => 'Sign out';

  @override
  String get settingsDeveloperResetOnboarding => 'Reset onboarding';

  @override
  String get settingsDeveloperOpenSystemSettings => 'Open iOS Settings';

  @override
  String get settingsNotificationsTestAction => 'Send test notification';

  @override
  String get settingsNotificationsTestHint =>
      'Writes a test message to your Inbox and fires an OS push (5 per hour).';

  @override
  String get settingsNotificationsTestSent =>
      'Test notification sent. Check Inbox.';

  @override
  String get settingsNotificationsTestFailed => 'Test notification failed.';

  @override
  String get refreshSummarySemantic => 'Refresh summary';

  @override
  String get settingsCategoryNativeSync => 'Native Sync';

  @override
  String get settingsCategoryNativeSyncDescription =>
      'Auto-push action items to iOS Reminders';

  @override
  String get nativeSyncScreenTitle => 'Native Sync';

  @override
  String get nativeSyncEnabledLabel => 'Push to iOS Reminders';

  @override
  String get nativeSyncEnabledDescription =>
      'Nooto automatically saves high-confidence action items to your iOS Reminders app. Items you delete in Reminders are never re-pushed.';

  @override
  String get nativeSyncThresholdLabel => 'Confidence threshold';

  @override
  String get nativeSyncThresholdHelp =>
      'Lower the threshold to push more items. Items below this score stay in Nooto only.';

  @override
  String get nativeSyncDailyBudgetLabel => 'Daily limit';

  @override
  String get nativeSyncDailyBudgetHelp =>
      'Max items pushed per day. Prevents flooding Reminders on a chatty day.';

  @override
  String get nativeSyncRecentlyPushedLabel => 'Recently pushed';

  @override
  String get nativeSyncRecentlyPushedEmpty => 'Nothing pushed yet';

  @override
  String get nativeSyncRecentlyPushedTitle => 'Recently pushed';
}
