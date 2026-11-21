import 'package:foxtune_ini/foxtune_ini.dart';

/// Why writing to a connected ECU is or is not permitted.
///
/// Writing a bad table to a running engine destroys hardware, so permission is
/// something that must be *earned* by positive evidence, never assumed. Every
/// constructor here states a reason, and the default is refusal.
class WritePermission {
  const WritePermission._(this.allowed, this.reason);

  /// Writing is permitted.
  const WritePermission.granted() : this._(true, null);

  /// Writing is refused, with a reason fit to show the user.
  const WritePermission.refused(String reason) : this._(false, reason);

  /// Whether writes may proceed.
  final bool allowed;

  /// Why writes are refused, or `null` when they are permitted.
  final String? reason;

  /// Decides whether this session may write.
  ///
  /// Both conditions are required, and both are about avoiding a specific
  /// disaster:
  ///
  /// * A **signature mismatch** means the definition in hand may not describe
  ///   the ECU on the wire, so every page offset is suspect. Writing under
  ///   those conditions puts arbitrary bytes in arbitrary places.
  /// * **Write mode** must be turned on deliberately. Read-only is the default
  ///   so that connecting to an engine, by itself, can never change it.
  static WritePermission evaluate({
    required IniDocument? definition,
    required String? reportedSignature,
    required bool writeModeEnabled,
  }) {
    if (definition == null) {
      return const WritePermission.refused(
          'Определение ЭБУ не загружено, поэтому раскладка страниц неизвестна.');
    }
    final expected = definition.identity.signature;
    if (expected == null) {
      return const WritePermission.refused(
          'В загруженном определении не указана сигнатура, поэтому нельзя подтвердить, что оно подходит этому ЭБУ.'
          '');
    }
    if (reportedSignature == null) {
      return const WritePermission.refused(
          'ЭБУ не сообщил сигнатуру.');
    }
    if (!definition.matchesSignature(reportedSignature)) {
      return WritePermission.refused(
          'ЭБУ сообщает «$reportedSignature», а загруженное определение для «$expected». Смещениям страниц доверять нельзя (cannot be trusted).'
          '');
    }
    if (!writeModeEnabled) {
      return const WritePermission.refused(
          'Режим записи выключен (Write mode is off). Включайте его осознанно, чтобы вносить изменения.');
    }
    return const WritePermission.granted();
  }

  @override
  String toString() =>
      allowed ? 'WritePermission.granted' : 'WritePermission.refused($reason)';
}

/// Thrown when a write is attempted that the guard rails forbid.
class WriteRefusedException implements Exception {
  WriteRefusedException(this.reason);

  final String reason;

  @override
  String toString() => 'WriteRefusedException: $reason';
}
