// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Portuguese (`pt`).
class AppLocalizationsPt extends AppLocalizations {
  AppLocalizationsPt([String locale = 'pt']) : super(locale);

  @override
  String get appName => 'Nooto';

  @override
  String welcomeBrandLine(String brand) {
    return 'Bem-vindo ao $brand';
  }

  @override
  String get welcomeTaglinePrefix => 'Inteligência pessoal que transforma ';

  @override
  String get welcomeTaglineEmphasis => 'pensamento em ação.';

  @override
  String get welcomeContinueWithApple => 'Continuar com Apple';

  @override
  String get welcomeContinueWithGoogle => 'Continuar com Google';

  @override
  String get welcomeWaitingForBrowser => 'Aguardando o navegador…';

  @override
  String get welcomeAgreeFooter =>
      'Ao continuar você concorda com nossos Termos e Política de Privacidade.';

  @override
  String get onboardingPromptHintTyped => 'Digite sua resposta…';

  @override
  String get onboardingPromptHintTap =>
      'Toque em uma opção acima para continuar';

  @override
  String get onboardingOpenerName => 'Oi — como você quer que eu te chame?';

  @override
  String onboardingOpenerLanguage(String name) {
    return 'Prazer em te conhecer, $name. Em qual idioma você quer que eu fale?';
  }

  @override
  String get onboardingOpenerMicrophone =>
      'Vou precisar do seu microfone para ouvir o que importa.';

  @override
  String get onboardingOpenerNotifications =>
      'Tudo bem se eu te avisar quando algo precisar da sua atenção?';

  @override
  String get onboardingOpenerBackground =>
      'Funciono melhor se puder continuar ouvindo em segundo plano.';

  @override
  String get onboardingOpenerLocation =>
      'Quer que eu marque onde as coisas acontecem? Opcional — pode pular.';

  @override
  String get onboardingOpenerDevice =>
      'Tem um aparelho Nooto com você? Podemos conectar depois — o pareamento chega na próxima fase.';

  @override
  String get onboardingOpenerSpeechProfile =>
      'Deixa eu aprender sua voz para te reconhecer no meio de outras.';

  @override
  String get onboardingOpenerAcknowledge => 'Tudo pronto. Vamos lá.';

  @override
  String get onboardingSkipped => 'Claro, podemos fazer isso depois.';

  @override
  String get onboardingChipMoreLanguages => 'Mais idiomas…';

  @override
  String get onboardingChipSkipForNow => 'Pular por agora';

  @override
  String get onboardingChipPairLater => 'Vou parear depois';

  @override
  String get onboardingAckLetsGo => 'Vamos lá';

  @override
  String get onboardingAckGotIt => 'Entendi';

  @override
  String get onboardingPermissionAllow => 'Permitir';

  @override
  String get onboardingPermissionPending => 'Pendente';

  @override
  String get onboardingPermissionGranted => 'Permitido';

  @override
  String get onboardingPermissionDenied => 'Negado';

  @override
  String get onboardingPermissionDeniedAction => 'Abrir ajustes';

  @override
  String get onboardingPermissionLabelMicrophone => 'Acesso ao microfone';

  @override
  String get onboardingPermissionLabelMicrophoneHelper =>
      'O áudio é processado no seu dispositivo; só a transcrição sai.';

  @override
  String get onboardingPermissionLabelNotifications => 'Acesso a notificações';

  @override
  String get onboardingPermissionLabelNotificationsHelper =>
      'Só avisos úteis e silenciosos — nunca ruído.';

  @override
  String get onboardingPermissionLabelBackground =>
      'Atividade em segundo plano';

  @override
  String get onboardingPermissionLabelBackgroundHelper =>
      'Permite que o Nooto continue ativo enquanto você usa outros apps.';

  @override
  String get onboardingPermissionLabelLocation => 'Localização';

  @override
  String get onboardingPermissionLabelLocationHelper =>
      'Marca conversas com o local em que aconteceram. Opcional.';

  @override
  String get onboardingSpeechCardTitle => 'Leia isto em voz alta';

  @override
  String get onboardingSpeechCardBody =>
      'Quando estiver pronto, segure o botão e leia isto em voz normal por uns cinco segundos.';

  @override
  String get onboardingSpeechCardSample =>
      'Oi, estou configurando o Nooto. É assim que minha voz soa numa sala normal.';

  @override
  String get onboardingSpeechRecording => 'Ouvindo…';

  @override
  String get onboardingSpeechCaptured => 'Voz capturada ✓';

  @override
  String get onboardingSpeechSkip => 'Pular por agora';

  @override
  String get shellTabHome => 'Início';

  @override
  String get shellTabChat => 'Chat';

  @override
  String get shellTabLibrary => 'Biblioteca';

  @override
  String get shellTabPlan => 'Plano';

  @override
  String get shellTabApps => 'Apps';

  @override
  String shellComingSoonTitle(String tab) {
    return '$tab chega em breve';
  }

  @override
  String get shellComingSoonBody =>
      'Esta tela chega em uma fase futura. Por enquanto, o Nooto v2 é só o fluxo de boas-vindas e onboarding.';

  @override
  String get todayCardHeader => 'Hoje';

  @override
  String todayCardCountPartial(int visible, int total) {
    return '$visible de $total';
  }

  @override
  String todayCardCountFull(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count itens',
      one: '1 item',
    );
    return '$_temp0';
  }

  @override
  String get todayCardSeeAll => 'Ver tudo';

  @override
  String get todayCardSeeAllSemantics => 'Ver todas as ações, abre a aba Plano';

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
  String get pendantPillLive => 'Ao vivo';

  @override
  String get pendantPillConnecting => 'Conectando…';

  @override
  String get pendantPillReconnecting => 'Reconectando';

  @override
  String pendantPillOfflineSince(String time) {
    return 'Offline desde $time';
  }

  @override
  String get pendantPillPaused => 'Pausado';

  @override
  String get pendantPairTitle => 'Conectar pendant';

  @override
  String get pendantPairConnecting => 'Configurando seu pendant…';

  @override
  String get pendantPairIncompatible =>
      'Este pendant não expõe o serviço de áudio correto. Verifique se o firmware está atualizado.';

  @override
  String get pendantPairPermissionDenied =>
      'Acesso a Bluetooth e microfone é necessário para conectar.';

  @override
  String get pendantPairOpenSettings => 'Abrir Ajustes';

  @override
  String get pendantPairTryAgain => 'Tentar novamente';

  @override
  String get pendantVoiceCardConnectTitle => 'Conecte seu pendant';

  @override
  String get pendantVoiceCardConnectBody => 'Toque para conectar seu pendant.';

  @override
  String pendantVoiceCardOfflineTitle(String time) {
    return 'Seu pendant desconectou às $time.';
  }

  @override
  String get pendantVoiceCardOfflineBody => 'Toque para reconectar.';

  @override
  String pendantPausePrompt(int seconds) {
    return 'Pausar pendant por ${seconds}s para gravar sua voz?';
  }

  @override
  String get pendantPauseConfirm => 'Pausar e continuar';

  @override
  String get pendantOnboardingTurnText =>
      'Conecte seu pendant quando estiver pronto. Mantenha-o perto do telefone para que eu possa encontrá-lo.';

  @override
  String get pendantScreenTitle => 'Pendant';

  @override
  String get pendantScreenMenuItem => 'Pendant';

  @override
  String get pendantScreenPairCta => 'Conectar pendant';

  @override
  String get pendantScreenPairHint => 'Deixe seu pendant perto.';

  @override
  String get pendantScreenConnectedHeader => 'Conectado';

  @override
  String get pendantScreenDisconnectCta => 'Desconectar';

  @override
  String get pendantScreenReconnectCta => 'Reconectar';

  @override
  String get pendantScreenInterruptedExplain =>
      'Pausado enquanto outra sessão de áudio está ativa.';

  @override
  String pendantScreenBatteryLabel(int percent) {
    return '$percent% de bateria';
  }

  @override
  String pendantScreenCodecLabel(String codec) {
    return 'Codec: $codec';
  }

  @override
  String get settingsScreenTitle => 'Configurações';

  @override
  String get settingsMenuItem => 'Configurações';

  @override
  String get settingsDevModeHeader => 'Modo Desenvolvedor';

  @override
  String get settingsPermissionsLabel => 'Permissões';

  @override
  String get settingsPermissionMicrophone => 'Microfone';

  @override
  String get settingsPermissionBluetooth => 'Bluetooth';

  @override
  String get settingsPermissionNotifications => 'Notificações';

  @override
  String get settingsPermissionLocation => 'Localização';

  @override
  String get settingsPendantLabel => 'Pendant';

  @override
  String get settingsAuthLabel => 'Conta';

  @override
  String settingsAuthSignedInAs(String email) {
    return 'Conectado como $email';
  }

  @override
  String get settingsAuthNotSignedIn => 'Não conectado';

  @override
  String get settingsBuildLabel => 'Build';

  @override
  String get settingsActionOpenIosSettings => 'Abrir Ajustes do iOS';

  @override
  String get settingsActionResetOnboarding => 'Reiniciar onboarding';

  @override
  String get settingsPermissionStatusGranted => 'Permitido';

  @override
  String get settingsPermissionStatusDenied => 'Negado';

  @override
  String get settingsPermissionStatusPermanentlyDenied =>
      'Permanentemente negado';

  @override
  String get settingsPermissionStatusRestricted => 'Restrito';

  @override
  String get settingsPermissionStatusLimited => 'Limitado';

  @override
  String get settingsPermissionOpenSettingsCta => 'Abrir Ajustes';

  @override
  String get pendantScreenDefaultDeviceName => 'Pendant Nooto';

  @override
  String get pendantCeremonySearching => 'Procurando.';

  @override
  String get pendantCeremonyFound => 'Encontrei você.';

  @override
  String get pendantCeremonySettingUp => 'Conectando.';

  @override
  String pendantCeremonyGreetingNamed(String name) {
    return 'Olá, $name.';
  }

  @override
  String get pendantCeremonyGreetingFallback => 'Olá.';

  @override
  String get pendantCeremonyTimeout =>
      'Não consigo ver seu pendant daqui. Deixe ele perto e vamos tentar de novo.';

  @override
  String get pendantCeremonyBleError =>
      'Algo interrompeu a conexão. Vamos tentar mais uma vez.';

  @override
  String get pendantCeremonyIncompatible =>
      'Este pendant não fala minha língua. Verifique se o firmware está atualizado.';

  @override
  String get pendantCeremonyBluetoothOff =>
      'Bluetooth está desligado. Ative no Centro de Controle e vamos tentar de novo.';

  @override
  String get pendantScreenBackLabel => 'Voltar';

  @override
  String get inboxEmptyTitle => 'Nada por aqui ainda';

  @override
  String get inboxEmptyDescription =>
      'Seus apps vão te enviar mensagens aqui. Conecte um app para começar.';

  @override
  String get inboxEmptyAction => 'Ver apps';

  @override
  String get inboxErrorTitle => 'Não foi possível conectar ao servidor';

  @override
  String get inboxErrorRetry => 'Tentar novamente';

  @override
  String get inboxScreenTitle => 'Caixa de entrada';

  @override
  String get inboxFilterAll => 'Todos';

  @override
  String get inboxBubbleCopy => 'Copiar';

  @override
  String get inboxBubbleShare => 'Compartilhar';

  @override
  String get inboxBubbleCancel => 'Cancelar';

  @override
  String get drawerInboxLabel => 'Caixa de entrada';

  @override
  String get settingsNotificationsLabel => 'Notificações';

  @override
  String get settingsNotificationsStateOn => 'Ativadas';

  @override
  String get settingsNotificationsStateOff => 'Desativadas — toque para ativar';

  @override
  String get settingsNotificationsStateOpenSettings =>
      'Abra Configurações para ativar';
}
