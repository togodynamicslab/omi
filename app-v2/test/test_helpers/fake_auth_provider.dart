import 'package:nooto_v2/providers/auth_provider.dart';

/// In-memory test double for [AuthChangeProvider].
///
/// Avoids hitting Firebase in widget tests. The base class consults
/// `kEnableFirebaseAuth` (true in v2 builds) to decide whether to read
/// Firebase or the dev fields, so we override the getters directly here.
class FakeAuthChangeProvider extends AuthChangeProvider {
  FakeAuthChangeProvider({String? displayName, bool isSignedIn = true})
    : _displayName = displayName,
      _isSignedIn = isSignedIn;

  String? _displayName;
  bool _isSignedIn;

  @override
  String? get displayName => _displayName;

  @override
  bool get isSignedIn => _isSignedIn;

  void setDisplayName(String? next) {
    _displayName = next;
    notifyListeners();
  }

  void setSignedIn(bool value) {
    _isSignedIn = value;
    notifyListeners();
  }
}
