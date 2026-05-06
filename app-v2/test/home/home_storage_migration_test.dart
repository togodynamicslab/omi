import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;

import 'package:nooto_v2/home/home_storage.dart';

/// Migration unit test: `sweepRetiredHomeActionLogEntries` removes action-log
/// rows whose keys belong to retired card kinds (`jira-stuck-*`, `today:*`)
/// and leaves everything else alone. Idempotent — running twice is a no-op.

void main() {
  late String tempDir;

  setUp(() async {
    tempDir = p.join(Directory.systemTemp.path, 'home-storage-test-${DateTime.now().microsecondsSinceEpoch}');
    Hive.init(tempDir);
    await Hive.openBox<Map>(HomeBoxes.actions);
  });

  tearDown(() async {
    await Hive.box<Map>(HomeBoxes.actions).clear();
    await Hive.close();
  });

  test('sweeps jira-stuck-* and today:* keys; leaves welcome / brief / etc untouched', () async {
    final box = Hive.box<Map>(HomeBoxes.actions);
    await box.putAll({
      // Should be swept:
      'jira-stuck-2026-04-30::dismiss': {'id': 'jira-stuck-2026-04-30', 'action': 'dismiss', 'ts': 1},
      'jira-stuck-2026-05-01::snooze': {'id': 'jira-stuck-2026-05-01', 'action': 'snooze', 'ts': 2, 'until': 99},
      'today:summary::accept': {'id': 'today:summary', 'action': 'accept', 'ts': 3},
      'today:summary::dismiss': {'id': 'today:summary', 'action': 'dismiss', 'ts': 4},
      // Should be preserved:
      'welcome::dismiss': {'id': 'welcome', 'action': 'dismiss', 'ts': 5},
      'brief:2026-05-05::dismiss': {'id': 'brief:2026-05-05', 'action': 'dismiss', 'ts': 6},
      'pair-pendant-unpaired::accept': {'id': 'pair-pendant-unpaired', 'action': 'accept', 'ts': 7},
    });

    final swept = await sweepRetiredHomeActionLogEntries();

    expect(swept, 4);
    expect(box.containsKey('jira-stuck-2026-04-30::dismiss'), isFalse);
    expect(box.containsKey('jira-stuck-2026-05-01::snooze'), isFalse);
    expect(box.containsKey('today:summary::accept'), isFalse);
    expect(box.containsKey('today:summary::dismiss'), isFalse);
    expect(box.containsKey('welcome::dismiss'), isTrue);
    expect(box.containsKey('brief:2026-05-05::dismiss'), isTrue);
    expect(box.containsKey('pair-pendant-unpaired::accept'), isTrue);
  });

  test('idempotent: second run is a no-op', () async {
    final box = Hive.box<Map>(HomeBoxes.actions);
    await box.putAll({
      'jira-stuck-2026-04-30::dismiss': {'id': 'x', 'action': 'dismiss', 'ts': 1},
      'today:summary::accept': {'id': 'today:summary', 'action': 'accept', 'ts': 2},
      'welcome::dismiss': {'id': 'welcome', 'action': 'dismiss', 'ts': 3},
    });

    final firstSwept = await sweepRetiredHomeActionLogEntries();
    final secondSwept = await sweepRetiredHomeActionLogEntries();

    expect(firstSwept, 2);
    expect(secondSwept, 0);
    expect(box.containsKey('welcome::dismiss'), isTrue);
  });

  test('empty box is a no-op', () async {
    final swept = await sweepRetiredHomeActionLogEntries();
    expect(swept, 0);
  });
}
