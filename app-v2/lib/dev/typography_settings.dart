import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

/// Dogfood-grade typography toggle.
///
/// Currently controls whether brief / plan-guidance prose renders in
/// Source Serif 4 (`brandAccent`) instead of the default sans-serif.
/// DESIGN.md restricts the serif accent to one site (the brief greeting);
/// this toggle lets us experiment with extending it to body copy without
/// committing to a system change. If dogfood lands on serif as the default,
/// flip `_useSerifBody` and update the DESIGN.md decision log; otherwise
/// the toggle is a tasting menu, not a permanent preference.
class TypographySettings extends ChangeNotifier {
  TypographySettings._();

  static const String _boxName = 'dev.typography.v1';
  static const String _useSerifBodyKey = 'useSerifBody';

  static Future<TypographySettings> load() async {
    final box = await Hive.openBox<dynamic>(_boxName);
    final s = TypographySettings._();
    s._box = box;
    s._useSerifBody = (box.get(_useSerifBodyKey) as bool?) ?? false;
    return s;
  }

  late Box<dynamic> _box;
  bool _useSerifBody = false;

  bool get useSerifBody => _useSerifBody;

  Future<void> setUseSerifBody(bool value) async {
    if (_useSerifBody == value) return;
    _useSerifBody = value;
    await _box.put(_useSerifBodyKey, value);
    notifyListeners();
  }

  Future<void> toggleSerifBody() => setUseSerifBody(!_useSerifBody);
}
