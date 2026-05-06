import 'package:firebase_auth/firebase_auth.dart' show FirebaseAuth;
import 'package:permission_handler/permission_handler.dart';

import 'package:nooto_v2/env_flags.dart';

/// Test seam: lets widget tests inject a deterministic permission status
/// without poking platform channels. Mirrors the constructor-seam pattern
/// used by `api_client.dart` and `socket_streamer.dart`.
typedef PermissionResolver = Future<PermissionStatus> Function(Permission permission);

/// Test seam: lets widget tests bypass Firebase entirely. Returning `null`
/// means "no signed-in account" and renders the Not-signed-in copy.
typedef EmailResolver = String? Function();

Future<PermissionStatus> defaultPermissionResolver(Permission p) => p.status;

Future<bool> defaultOpenAppSettings() => openAppSettings();

String? defaultEmailResolver() {
  if (!kEnableFirebaseAuth) return null;
  return FirebaseAuth.instance.currentUser?.email;
}
