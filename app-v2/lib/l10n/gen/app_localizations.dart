import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_pt.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'gen/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('pt'),
  ];

  /// No description provided for @appName.
  ///
  /// In en, this message translates to:
  /// **'Nooto'**
  String get appName;

  /// No description provided for @welcomeBrandLine.
  ///
  /// In en, this message translates to:
  /// **'Welcome to {brand}'**
  String welcomeBrandLine(String brand);

  /// No description provided for @welcomeTaglinePrefix.
  ///
  /// In en, this message translates to:
  /// **'Personal intelligence that turns '**
  String get welcomeTaglinePrefix;

  /// No description provided for @welcomeTaglineEmphasis.
  ///
  /// In en, this message translates to:
  /// **'thought to action.'**
  String get welcomeTaglineEmphasis;

  /// No description provided for @welcomeContinueWithApple.
  ///
  /// In en, this message translates to:
  /// **'Continue with Apple'**
  String get welcomeContinueWithApple;

  /// No description provided for @welcomeContinueWithGoogle.
  ///
  /// In en, this message translates to:
  /// **'Continue with Google'**
  String get welcomeContinueWithGoogle;

  /// No description provided for @welcomeWaitingForBrowser.
  ///
  /// In en, this message translates to:
  /// **'Waiting for browser…'**
  String get welcomeWaitingForBrowser;

  /// No description provided for @welcomeAgreeFooter.
  ///
  /// In en, this message translates to:
  /// **'By continuing you agree to our Terms and Privacy Policy.'**
  String get welcomeAgreeFooter;

  /// No description provided for @onboardingPromptHintTyped.
  ///
  /// In en, this message translates to:
  /// **'Type your answer…'**
  String get onboardingPromptHintTyped;

  /// No description provided for @onboardingPromptHintTap.
  ///
  /// In en, this message translates to:
  /// **'Tap an option above to continue'**
  String get onboardingPromptHintTap;

  /// No description provided for @onboardingOpenerName.
  ///
  /// In en, this message translates to:
  /// **'Hey — what should I call you?'**
  String get onboardingOpenerName;

  /// No description provided for @onboardingOpenerLanguage.
  ///
  /// In en, this message translates to:
  /// **'Nice to meet you, {name}. What language do you want me to use?'**
  String onboardingOpenerLanguage(String name);

  /// No description provided for @onboardingOpenerMicrophone.
  ///
  /// In en, this message translates to:
  /// **'I\'ll need your mic to listen for what matters.'**
  String get onboardingOpenerMicrophone;

  /// No description provided for @onboardingOpenerNotifications.
  ///
  /// In en, this message translates to:
  /// **'Mind if I ping you when something needs your attention?'**
  String get onboardingOpenerNotifications;

  /// No description provided for @onboardingOpenerBackground.
  ///
  /// In en, this message translates to:
  /// **'I work best if I can keep listening in the background.'**
  String get onboardingOpenerBackground;

  /// No description provided for @onboardingOpenerLocation.
  ///
  /// In en, this message translates to:
  /// **'Want me to tag where things happen? Optional — feel free to skip.'**
  String get onboardingOpenerLocation;

  /// No description provided for @onboardingOpenerDevice.
  ///
  /// In en, this message translates to:
  /// **'Have a Nooto device on you? We can wire it up later — pairing arrives in the next phase.'**
  String get onboardingOpenerDevice;

  /// No description provided for @onboardingOpenerSpeechProfile.
  ///
  /// In en, this message translates to:
  /// **'Let me learn your voice so I can tell you apart from the rest of the world.'**
  String get onboardingOpenerSpeechProfile;

  /// No description provided for @onboardingOpenerAcknowledge.
  ///
  /// In en, this message translates to:
  /// **'All set. Let\'s go.'**
  String get onboardingOpenerAcknowledge;

  /// No description provided for @onboardingSkipped.
  ///
  /// In en, this message translates to:
  /// **'Sure, we can do that later.'**
  String get onboardingSkipped;

  /// No description provided for @onboardingChipMoreLanguages.
  ///
  /// In en, this message translates to:
  /// **'More languages…'**
  String get onboardingChipMoreLanguages;

  /// No description provided for @onboardingChipSkipForNow.
  ///
  /// In en, this message translates to:
  /// **'Skip for now'**
  String get onboardingChipSkipForNow;

  /// No description provided for @onboardingChipPairLater.
  ///
  /// In en, this message translates to:
  /// **'I\'ll pair it later'**
  String get onboardingChipPairLater;

  /// No description provided for @onboardingAckLetsGo.
  ///
  /// In en, this message translates to:
  /// **'Let\'s go'**
  String get onboardingAckLetsGo;

  /// No description provided for @onboardingAckGotIt.
  ///
  /// In en, this message translates to:
  /// **'Got it'**
  String get onboardingAckGotIt;

  /// No description provided for @onboardingPermissionAllow.
  ///
  /// In en, this message translates to:
  /// **'Allow'**
  String get onboardingPermissionAllow;

  /// No description provided for @onboardingPermissionPending.
  ///
  /// In en, this message translates to:
  /// **'Pending'**
  String get onboardingPermissionPending;

  /// No description provided for @onboardingPermissionGranted.
  ///
  /// In en, this message translates to:
  /// **'Granted'**
  String get onboardingPermissionGranted;

  /// No description provided for @onboardingPermissionDenied.
  ///
  /// In en, this message translates to:
  /// **'Denied'**
  String get onboardingPermissionDenied;

  /// No description provided for @onboardingPermissionDeniedAction.
  ///
  /// In en, this message translates to:
  /// **'Open settings'**
  String get onboardingPermissionDeniedAction;

  /// No description provided for @onboardingPermissionLabelMicrophone.
  ///
  /// In en, this message translates to:
  /// **'Microphone access'**
  String get onboardingPermissionLabelMicrophone;

  /// No description provided for @onboardingPermissionLabelMicrophoneHelper.
  ///
  /// In en, this message translates to:
  /// **'Audio is processed on your device; only the transcript leaves.'**
  String get onboardingPermissionLabelMicrophoneHelper;

  /// No description provided for @onboardingPermissionLabelNotifications.
  ///
  /// In en, this message translates to:
  /// **'Notification access'**
  String get onboardingPermissionLabelNotifications;

  /// No description provided for @onboardingPermissionLabelNotificationsHelper.
  ///
  /// In en, this message translates to:
  /// **'Quiet, useful nudges only — never noise.'**
  String get onboardingPermissionLabelNotificationsHelper;

  /// No description provided for @onboardingPermissionLabelBackground.
  ///
  /// In en, this message translates to:
  /// **'Background activity'**
  String get onboardingPermissionLabelBackground;

  /// No description provided for @onboardingPermissionLabelBackgroundHelper.
  ///
  /// In en, this message translates to:
  /// **'Lets Nooto stay alive while you\'re using other apps.'**
  String get onboardingPermissionLabelBackgroundHelper;

  /// No description provided for @onboardingPermissionLabelLocation.
  ///
  /// In en, this message translates to:
  /// **'Location'**
  String get onboardingPermissionLabelLocation;

  /// No description provided for @onboardingPermissionLabelLocationHelper.
  ///
  /// In en, this message translates to:
  /// **'Tags conversations with where they happened. Optional.'**
  String get onboardingPermissionLabelLocationHelper;

  /// No description provided for @onboardingSpeechCardTitle.
  ///
  /// In en, this message translates to:
  /// **'Read this aloud'**
  String get onboardingSpeechCardTitle;

  /// No description provided for @onboardingSpeechCardBody.
  ///
  /// In en, this message translates to:
  /// **'Whenever you\'re ready, hold the button and read this in a normal voice for about five seconds.'**
  String get onboardingSpeechCardBody;

  /// No description provided for @onboardingSpeechCardSample.
  ///
  /// In en, this message translates to:
  /// **'Hi, I\'m getting Nooto set up. This is what my voice sounds like in a normal room.'**
  String get onboardingSpeechCardSample;

  /// No description provided for @onboardingSpeechRecording.
  ///
  /// In en, this message translates to:
  /// **'Listening…'**
  String get onboardingSpeechRecording;

  /// No description provided for @onboardingSpeechCaptured.
  ///
  /// In en, this message translates to:
  /// **'Voice captured ✓'**
  String get onboardingSpeechCaptured;

  /// No description provided for @onboardingSpeechSkip.
  ///
  /// In en, this message translates to:
  /// **'Skip for now'**
  String get onboardingSpeechSkip;

  /// No description provided for @shellTabHome.
  ///
  /// In en, this message translates to:
  /// **'Home'**
  String get shellTabHome;

  /// No description provided for @shellTabChat.
  ///
  /// In en, this message translates to:
  /// **'Chat'**
  String get shellTabChat;

  /// No description provided for @shellTabLibrary.
  ///
  /// In en, this message translates to:
  /// **'Library'**
  String get shellTabLibrary;

  /// No description provided for @shellTabPlan.
  ///
  /// In en, this message translates to:
  /// **'Plan'**
  String get shellTabPlan;

  /// No description provided for @shellTabApps.
  ///
  /// In en, this message translates to:
  /// **'Apps'**
  String get shellTabApps;

  /// No description provided for @shellComingSoonTitle.
  ///
  /// In en, this message translates to:
  /// **'{tab} arrives next'**
  String shellComingSoonTitle(String tab);

  /// No description provided for @shellComingSoonBody.
  ///
  /// In en, this message translates to:
  /// **'This screen lands in a future phase. For now, the morning brief and today\'s commitments are on Home.'**
  String get shellComingSoonBody;

  /// No description provided for @todayCardHeader.
  ///
  /// In en, this message translates to:
  /// **'Today'**
  String get todayCardHeader;

  /// No description provided for @todayCardCountPartial.
  ///
  /// In en, this message translates to:
  /// **'{visible} of {total}'**
  String todayCardCountPartial(int visible, int total);

  /// No description provided for @todayCardCountFull.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 item} other{{count} items}}'**
  String todayCardCountFull(int count);

  /// No description provided for @todayCardSeeAll.
  ///
  /// In en, this message translates to:
  /// **'See all'**
  String get todayCardSeeAll;

  /// No description provided for @todayCardSeeAllSemantics.
  ///
  /// In en, this message translates to:
  /// **'See all action items, opens Plan tab'**
  String get todayCardSeeAllSemantics;

  /// No description provided for @summaryTemplate.
  ///
  /// In en, this message translates to:
  /// **'Summary template'**
  String get summaryTemplate;

  /// No description provided for @summarizedBy.
  ///
  /// In en, this message translates to:
  /// **'Summarized by {name}'**
  String summarizedBy(String name);

  /// No description provided for @noSummaryForApp.
  ///
  /// In en, this message translates to:
  /// **'No summary available — tap to choose another app'**
  String get noSummaryForApp;

  /// No description provided for @reprocessingConversation.
  ///
  /// In en, this message translates to:
  /// **'Reprocessing…'**
  String get reprocessingConversation;

  /// No description provided for @reprocessFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t reprocess. Try again.'**
  String get reprocessFailed;

  /// No description provided for @chooseSummarizationApp.
  ///
  /// In en, this message translates to:
  /// **'Choose a summarization app'**
  String get chooseSummarizationApp;

  /// No description provided for @currentlyUsing.
  ///
  /// In en, this message translates to:
  /// **'Currently using'**
  String get currentlyUsing;

  /// No description provided for @suggestedForThisConversation.
  ///
  /// In en, this message translates to:
  /// **'Suggested for this conversation'**
  String get suggestedForThisConversation;

  /// No description provided for @summarizedAppsSuggestedSection.
  ///
  /// In en, this message translates to:
  /// **'Suggested'**
  String get summarizedAppsSuggestedSection;

  /// No description provided for @summarizedAppsAvailableSection.
  ///
  /// In en, this message translates to:
  /// **'Installed'**
  String get summarizedAppsAvailableSection;

  /// No description provided for @summarizedAppsEmpty.
  ///
  /// In en, this message translates to:
  /// **'No apps installed yet'**
  String get summarizedAppsEmpty;

  /// No description provided for @summarizeWithApp.
  ///
  /// In en, this message translates to:
  /// **'Summarize with an app'**
  String get summarizeWithApp;

  /// Status pill label when pendant is connected and streaming.
  ///
  /// In en, this message translates to:
  /// **'Live'**
  String get pendantPillLive;

  /// Status pill label during initial connection or first-pair handshake.
  ///
  /// In en, this message translates to:
  /// **'Connecting…'**
  String get pendantPillConnecting;

  /// Status pill label after a BLE drop while auto-reconnect is in flight.
  ///
  /// In en, this message translates to:
  /// **'Reconnecting'**
  String get pendantPillReconnecting;

  /// Status pill label after 30s with no successful reconnect.
  ///
  /// In en, this message translates to:
  /// **'Offline since {time}'**
  String pendantPillOfflineSince(String time);

  /// Status pill label while AVAudioSession interruption is active (call, Siri, etc.).
  ///
  /// In en, this message translates to:
  /// **'Paused'**
  String get pendantPillPaused;

  /// Pairing sheet title.
  ///
  /// In en, this message translates to:
  /// **'Pair your pendant'**
  String get pendantPairTitle;

  /// Pairing sheet progress message during 5-15s first-pair characteristic discovery.
  ///
  /// In en, this message translates to:
  /// **'Setting up your pendant…'**
  String get pendantPairConnecting;

  /// Pairing sheet error message when the device does not expose the Omi audio service.
  ///
  /// In en, this message translates to:
  /// **'This pendant doesn\'t expose Omi audio. Make sure your firmware is up to date.'**
  String get pendantPairIncompatible;

  /// Pairing sheet error message when BLE or mic permission is denied.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth and microphone access are needed to pair.'**
  String get pendantPairPermissionDenied;

  /// Pairing sheet CTA that opens the OS settings app.
  ///
  /// In en, this message translates to:
  /// **'Open Settings'**
  String get pendantPairOpenSettings;

  /// Pairing sheet CTA shown after an incompatible-device error.
  ///
  /// In en, this message translates to:
  /// **'Try again'**
  String get pendantPairTryAgain;

  /// Home voice card title shown while no pendant is paired.
  ///
  /// In en, this message translates to:
  /// **'Connect your pendant'**
  String get pendantVoiceCardConnectTitle;

  /// Home voice card body shown while no pendant is paired.
  ///
  /// In en, this message translates to:
  /// **'Tap to pair your Omi pendant.'**
  String get pendantVoiceCardConnectBody;

  /// Home voice card title shown after the pendant has been offline for at least 5 minutes.
  ///
  /// In en, this message translates to:
  /// **'Your pendant disconnected at {time}.'**
  String pendantVoiceCardOfflineTitle(String time);

  /// Home voice card body shown after the pendant has been offline for at least 5 minutes.
  ///
  /// In en, this message translates to:
  /// **'Tap to reconnect.'**
  String get pendantVoiceCardOfflineBody;

  /// Sheet prompt shown when phone-mic capture is requested while pendant is live.
  ///
  /// In en, this message translates to:
  /// **'Pause pendant for {seconds}s while we record your voice?'**
  String pendantPausePrompt(int seconds);

  /// Confirm CTA on the pause-pendant sheet.
  ///
  /// In en, this message translates to:
  /// **'Pause and continue'**
  String get pendantPauseConfirm;

  /// Onboarding chat turn text introducing pendant pairing after speech profile.
  ///
  /// In en, this message translates to:
  /// **'Pair your pendant when you\'re ready. Hold it near your phone so I can find it.'**
  String get pendantOnboardingTurnText;

  /// AppBar title for the dedicated pendant connection screen.
  ///
  /// In en, this message translates to:
  /// **'Pendant'**
  String get pendantScreenTitle;

  /// Kebab menu entry that opens the pendant connection screen.
  ///
  /// In en, this message translates to:
  /// **'Pendant'**
  String get pendantScreenMenuItem;

  /// Primary CTA on the pendant screen when no pendant is paired.
  ///
  /// In en, this message translates to:
  /// **'Pair pendant'**
  String get pendantScreenPairCta;

  /// Hint shown under the pair CTA on the pendant screen.
  ///
  /// In en, this message translates to:
  /// **'Hold your Omi pendant near your phone.'**
  String get pendantScreenPairHint;

  /// Header on the pendant screen when the pendant is live.
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get pendantScreenConnectedHeader;

  /// Outlined button on the pendant screen to disconnect a live pendant.
  ///
  /// In en, this message translates to:
  /// **'Disconnect'**
  String get pendantScreenDisconnectCta;

  /// Button on the pendant screen to reconnect when offline.
  ///
  /// In en, this message translates to:
  /// **'Reconnect'**
  String get pendantScreenReconnectCta;

  /// Explanation shown when the pendant is in interrupted state.
  ///
  /// In en, this message translates to:
  /// **'Recording is paused while a phone call or other audio session is active.'**
  String get pendantScreenInterruptedExplain;

  /// Battery percentage row label on the pendant screen.
  ///
  /// In en, this message translates to:
  /// **'{percent}% battery'**
  String pendantScreenBatteryLabel(int percent);

  /// Codec badge label on the pendant screen.
  ///
  /// In en, this message translates to:
  /// **'Codec: {codec}'**
  String pendantScreenCodecLabel(String codec);

  /// No description provided for @settingsScreenTitle.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsScreenTitle;

  /// No description provided for @settingsMenuItem.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsMenuItem;

  /// No description provided for @settingsDevModeHeader.
  ///
  /// In en, this message translates to:
  /// **'Developer Mode'**
  String get settingsDevModeHeader;

  /// No description provided for @settingsPermissionsLabel.
  ///
  /// In en, this message translates to:
  /// **'Permissions'**
  String get settingsPermissionsLabel;

  /// No description provided for @settingsPermissionMicrophone.
  ///
  /// In en, this message translates to:
  /// **'Microphone'**
  String get settingsPermissionMicrophone;

  /// No description provided for @settingsPermissionBluetooth.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth'**
  String get settingsPermissionBluetooth;

  /// No description provided for @settingsPermissionNotifications.
  ///
  /// In en, this message translates to:
  /// **'Notifications'**
  String get settingsPermissionNotifications;

  /// No description provided for @settingsPermissionLocation.
  ///
  /// In en, this message translates to:
  /// **'Location'**
  String get settingsPermissionLocation;

  /// No description provided for @settingsPendantLabel.
  ///
  /// In en, this message translates to:
  /// **'Pendant'**
  String get settingsPendantLabel;

  /// No description provided for @settingsAuthLabel.
  ///
  /// In en, this message translates to:
  /// **'Account'**
  String get settingsAuthLabel;

  /// No description provided for @settingsAuthSignedInAs.
  ///
  /// In en, this message translates to:
  /// **'Signed in as {email}'**
  String settingsAuthSignedInAs(String email);

  /// No description provided for @settingsAuthNotSignedIn.
  ///
  /// In en, this message translates to:
  /// **'Not signed in'**
  String get settingsAuthNotSignedIn;

  /// No description provided for @settingsBuildLabel.
  ///
  /// In en, this message translates to:
  /// **'Build'**
  String get settingsBuildLabel;

  /// No description provided for @settingsActionOpenIosSettings.
  ///
  /// In en, this message translates to:
  /// **'Open iOS Settings'**
  String get settingsActionOpenIosSettings;

  /// No description provided for @settingsActionResetOnboarding.
  ///
  /// In en, this message translates to:
  /// **'Reset onboarding'**
  String get settingsActionResetOnboarding;

  /// No description provided for @settingsPermissionStatusGranted.
  ///
  /// In en, this message translates to:
  /// **'Granted'**
  String get settingsPermissionStatusGranted;

  /// No description provided for @settingsPermissionStatusDenied.
  ///
  /// In en, this message translates to:
  /// **'Denied'**
  String get settingsPermissionStatusDenied;

  /// No description provided for @settingsPermissionStatusPermanentlyDenied.
  ///
  /// In en, this message translates to:
  /// **'Permanently denied'**
  String get settingsPermissionStatusPermanentlyDenied;

  /// No description provided for @settingsPermissionStatusRestricted.
  ///
  /// In en, this message translates to:
  /// **'Restricted'**
  String get settingsPermissionStatusRestricted;

  /// No description provided for @settingsPermissionStatusLimited.
  ///
  /// In en, this message translates to:
  /// **'Limited'**
  String get settingsPermissionStatusLimited;

  /// No description provided for @settingsPermissionOpenSettingsCta.
  ///
  /// In en, this message translates to:
  /// **'Open Settings'**
  String get settingsPermissionOpenSettingsCta;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'pt'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'pt':
      return AppLocalizationsPt();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
