import 'package:flutter_test/flutter_test.dart';
import 'package:zerotouch_intake/models/lifecycle_request.dart';

void main() {
  group('LifecycleRequest.toJson — wire contract', () {
    test('Joiner sends camelCase fields the Function expects', () {
      const req = LifecycleRequest(
        action: LifecycleAction.joiner,
        firstName: 'Ada',
        lastName: 'Byron',
        department: 'Engineering',
        jobTitle: 'Developer',
        personalEmail: 'ada@example.com',
      );
      final json = req.toJson();

      expect(json['action'], 'Joiner');
      expect(json['firstName'], 'Ada');
      expect(json['lastName'], 'Byron');
      expect(json['department'], 'Engineering');
      expect(json['jobTitle'], 'Developer');
      expect(json['personalEmail'], 'ada@example.com');
      // Fields not relevant to Joiner must be omitted, not null.
      expect(json.containsKey('identity'), isFalse);
      expect(json.containsKey('newDepartment'), isFalse);
      expect(json.containsKey('lastDay'), isFalse);
    });

    test('Mover sends identity + newDepartment only', () {
      const req = LifecycleRequest(
        action: LifecycleAction.mover,
        identity: 'ada.byron@tenant.onmicrosoft.com',
        newDepartment: 'Sales',
      );
      final json = req.toJson();

      expect(json['action'], 'Mover');
      expect(json['identity'], 'ada.byron@tenant.onmicrosoft.com');
      expect(json['newDepartment'], 'Sales');
      expect(json.containsKey('firstName'), isFalse);
    });

    test('Leaver with a future date formats lastDay as yyyy-MM-dd', () {
      final req = LifecycleRequest(
        action: LifecycleAction.leaver,
        identity: 'ada.byron@tenant.onmicrosoft.com',
        lastDay: DateTime(2026, 12, 31),
      );
      final json = req.toJson();

      expect(json['action'], 'Leaver');
      expect(json['identity'], 'ada.byron@tenant.onmicrosoft.com');
      expect(json['lastDay'], '2026-12-31');
    });

    test('Leaver without a date omits lastDay (immediate)', () {
      const req = LifecycleRequest(
        action: LifecycleAction.leaver,
        identity: 'ada.byron@tenant.onmicrosoft.com',
      );
      final json = req.toJson();

      expect(json.containsKey('lastDay'), isFalse);
    });

    test('action wire values match the PowerShell router exactly', () {
      expect(LifecycleAction.joiner.wire, 'Joiner');
      expect(LifecycleAction.mover.wire, 'Mover');
      expect(LifecycleAction.leaver.wire, 'Leaver');
    });
  });
}
