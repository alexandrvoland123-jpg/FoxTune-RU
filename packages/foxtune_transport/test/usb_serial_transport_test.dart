
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxtune_transport/foxtune_transport.dart';

void main() {
  group('USB permission', () {
    test('a denial reads as a denial, not as a bug', () {
      final message = UsbSerialTransport.describeOpenFailure(
        PlatformException(
          code: 'UsbSerialPortAdapter',
          message: 'Failed to acquire permissions.',
        ),
      );

      expect(message, startsWith('Доступ к USB отклонён'));
      expect(message, contains('всегда'));
    });

    test('any other failure keeps the plugin detail', () {
      final message = UsbSerialTransport.describeOpenFailure(
        PlatformException(code: 'x', message: 'Interface busy'),
      );

      expect(
        message,
        'Не удалось получить доступ к USB-устройству: Interface busy',
      );
    });
  });

  group('device filter', () {
    test('lists exactly the vendors the port picker treats as likely ECUs', () {
      final file = [
        File('../../app/foxtune_app/android/app/src/main/res/xml/'
            'device_filter.xml'),
        File('app/foxtune_app/android/app/src/main/res/xml/'
            'device_filter.xml'),
      ].firstWhere((f) => f.existsSync());

      final declared = RegExp(r'vendor-id="(\d+)"')
          .allMatches(file.readAsStringSync())
          .map((m) => int.parse(m.group(1)!))
          .toSet();

      expect(declared, EcuPort.knownEcuVendorIds);
    });
  });

  group('port events', () {
    test('network and desktop transports report none', () async {
      expect(await const TcpEcuTransport().portEvents.isEmpty, isTrue);
    });
  });
}
