import 'ecu_transport.dart';

/// Fallback for targets without `dart:io`, such as Flutter web.
EcuTransport createPlatformTransport() => throw UnsupportedError(
      'Последовательному транспорту нужна платформа с dart:io.',
    );
