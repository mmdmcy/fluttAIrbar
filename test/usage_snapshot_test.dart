import 'package:flutter_test/flutter_test.dart';
import 'package:fluttairbar/models/usage_snapshot.dart';

void main() {
  test('RateWindow formats reset from seconds', () {
    final w = RateWindow(usedPercent: 28, resetAfterSeconds: 3661);
    expect(w.resetDescription, 'in 1h 01m');
  });

  test('RateWindow uses days and date for long resets', () {
    final at = DateTime.now().add(const Duration(hours: 600));
    final w = RateWindow(usedPercent: 10, resetAt: at);
    expect(w.resetDescription, contains('d ·'));
    expect(w.resetDescription, isNot(contains('600h')));
  });

  test('ResetCredit availability respects expiry', () {
    final ok = ResetCredit(
      id: '1',
      status: 'available',
      expiresAt: DateTime.now().add(const Duration(days: 1)),
    );
    final expired = ResetCredit(
      id: '2',
      status: 'available',
      expiresAt: DateTime.now().subtract(const Duration(days: 1)),
    );
    expect(ok.isAvailable, isTrue);
    expect(expired.isAvailable, isFalse);
  });

  test('tray tooltip prefers weekly window', () {
    const snap = AppSnapshot(
      codex: CodexUsage(
        email: 'a@b.c',
        accountId: 'x',
        authSource: 'opencode',
        secondary: RateWindow(usedPercent: 28, label: 'Weekly'),
      ),
      cursor: CursorUsage(authSource: 'app', usedPercent: 10),
    );
    expect(snap.trayTooltip, contains('Weekly 72% left'));
    expect(snap.trayTooltip, contains('Cursor 90% left'));
    expect(snap.trayTitle, '72%');
  });
}
