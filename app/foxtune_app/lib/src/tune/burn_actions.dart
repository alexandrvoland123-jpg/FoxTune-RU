import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:foxtune_tune/foxtune_tune.dart';

import '../dashboard/gauge_status.dart';
import 'tune_controller.dart';

/// Committing unsaved changes to the ECU.
///
/// Shared by the table editor and the settings screens, because a tuner who
/// has changed a trigger setting and a VE cell expects one Burn button to
/// mean the same thing in both places.
class BurnActions {
  const BurnActions._();

  /// Confirms, then writes, verifies and burns every changed page.
  static Future<void> confirmAndBurn(
    BuildContext context,
    WidgetRef ref,
    TuneState tune,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => BurnDialog(pages: tune.dirtyPages.toList()..sort()),
    );
    if (confirmed != true || !context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      final results = await ref.read(tuneProvider.notifier).commitDirtyPages();
      messenger.showSnackBar(
        SnackBar(content: Text('Страниц записано в EEPROM: ${results.length}.')),
      );
    } on Object catch (error) {
      messenger.showSnackBar(
        SnackBar(
          backgroundColor: StatusPalette.critical,
          content: Text('$error'),
          duration: const Duration(seconds: 8),
        ),
      );
    }
  }
}

/// Confirmation before anything is made permanent.
class BurnDialog extends StatelessWidget {
  const BurnDialog({super.key, required this.pages});

  /// 1-based page numbers about to be written.
  final List<int> pages;

  @override
  Widget build(BuildContext context) => AlertDialog(
    icon: Icon(Icons.warning_amber_rounded, color: StatusPalette.warning),
    title: const Text('Записать изменения в ЭБУ?'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Страницы для записи: ${pages.join(", ")}'),
        const SizedBox(height: 12),
        const Text(
          'Каждая страница записывается в ОЗУ, сверяется с контрольной суммой ЭБУ и записывается в EEPROM, только если она совпала. Точка восстановления сохраняется перед первой записью этого сеанса.'
          ''
          '',
        ),
        const SizedBox(height: 12),
        const Text(
          'Не записывайте во флеш при работающем двигателе, если не уверены, что изменение безопасно.'
          '',
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(false),
        child: const Text('Отмена'),
      ),
      FilledButton(
        onPressed: () => Navigator.of(context).pop(true),
        child: const Text('Прошить'),
      ),
    ],
  );
}
