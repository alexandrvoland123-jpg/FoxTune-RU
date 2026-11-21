import 'dart:io';

import 'ecu_transport.dart';
import 'serial_port_transport.dart';
import 'usb_serial_transport.dart';

/// Chooses the transport for the host platform.
EcuTransport createPlatformTransport() {
  if (Platform.isAndroid) return UsbSerialTransport();
  if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
    return SerialPortTransport();
  }
  if (Platform.isIOS) {
    throw UnsupportedError(
      'В iOS нет универсального API для USB-последовательного порта, а фреймворк External Accessory требует лицензии Apple MFi. Чтобы подключиться к Speeduino с iOS, нужен мост WiFi (ESP8266/ESP32) или BLE.'
      ''
      '',
    );
  }
  throw UnsupportedError('Нет транспорта ЭБУ для ${Platform.operatingSystem}');
}
