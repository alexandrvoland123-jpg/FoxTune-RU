import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:foxtune_tune/foxtune_tune.dart';

import '../dashboard/gauge_status.dart';
import '../files/file_saving.dart';
import 'tune_controller.dart';

/// Import and export of a single table as a TunerStudio `.table` file.
///
/// Like a `.msq` load, an import only changes the in-memory tune. Nothing
/// reaches the ECU until the user burns.
abstract final class TableFileActions {
  /// Writes the open table to a file the user chooses.
  static Future<void> export(
    BuildContext context,
    WidgetRef ref,
    TableView view,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final suggested =
        '${view.table.id.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')}.table';

    try {
      final saved = await ref
          .read(fileSavingProvider)
          .saveText(
            dialogTitle: 'Экспорт: ${view.title}',
            fileName: suggested,
            extension: 'table',
            text: TableFileCodec.encode(view),
          );
      if (saved == null) return;
      messenger.showSnackBar(
        SnackBar(content: Text('${view.title} экспортировано в $saved')),
      );
    } on Object catch (error) {
      messenger.showSnackBar(
        SnackBar(
          backgroundColor: StatusPalette.critical,
          content: Text('Не удалось экспортировать: $error'),
        ),
      );
    }
  }

  /// Loads a `.table` file into the open table.
  static Future<void> import(
    BuildContext context,
    WidgetRef ref,
    TableView view,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    TableFileData data;
    try {
      final picked = await ref
          .read(fileSavingProvider)
          .pickFile(
            dialogTitle: 'Импорт в ${view.title}',
            extensions: const ['table'],
          );
      if (picked == null || !context.mounted) return;
      data = TableFileCodec.decode(picked.text);
    } on Object catch (error) {
      messenger.showSnackBar(
        SnackBar(
          backgroundColor: StatusPalette.critical,
          content: Text(switch (error) {
            TableFileException(:final message) => message,
            WrongFileTypeException(:final message) => message,
            _ => 'Не удалось прочитать файл: $error',
          }),
          duration: const Duration(seconds: 6),
        ),
      );
      return;
    }

    if (!context.mounted) return;
    final choice = await showDialog<_ImportChoice>(
      context: context,
      builder: (_) => _ImportDialog(view: view, data: data),
    );
    if (choice == null) return;

    final outcome = TableFileCodec.applyTo(
      view,
      data,
      importAxes: choice.importAxes,
    );
    ref.read(tuneProvider.notifier).notifyEdited();

    messenger.showSnackBar(
      SnackBar(
        content: Text(
          outcome.resampled
              ? 'Импортировано ${outcome.sourceShape} в ${outcome.targetShape}, интерполировано на оси этой таблицы. Запишите во флеш для применения.'
                    ''
              : 'Импортировано ячеек: ${outcome.cellsWritten}${outcome.axesWritten ? ' и оси' : ''}. Запишите во флеш для применения.'
                    ''
                    '',
        ),
        duration: const Duration(seconds: 6),
      ),
    );
  }
}

class _ImportChoice {
  const _ImportChoice({required this.importAxes});
  final bool importAxes;
}

/// Confirms an import, stating plainly what it will do.
class _ImportDialog extends StatefulWidget {
  const _ImportDialog({required this.view, required this.data});

  final TableView view;
  final TableFileData data;

  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  bool _importAxes = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sameShape =
        widget.data.rows == widget.view.rows &&
        widget.data.columns == widget.view.columns;

    return AlertDialog(
      title: Text('Импорт в ${widget.view.title}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Файл: ${widget.data.rows} x ${widget.data.columns}     Эта таблица: ${widget.view.rows} x ${widget.view.columns}'
            '',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          if (sameShape)
            const Text('Формы совпадают, поэтому значения копируются ячейка в ячейку.')
          else
            Text(
              'Формы различаются, поэтому файл будет интерполирован на оси этой таблицы. Значения за пределами диапазона файла держатся на его краю, а не экстраполируются.'
              ""
              '',
              style: theme.textTheme.bodyMedium,
            ),
          const SizedBox(height: 12),
          Text(
            'Значения ограничиваются тем, что допускает определение, и ничто не попадёт в ЭБУ, пока вы не запишете во флеш.'
            '',
            style: theme.textTheme.bodySmall,
          ),
          if (sameShape) ...[
            const SizedBox(height: 8),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _importAxes,
              // Off by default: importing values is the common case, and
              // moving the axes changes what every other row and column means.
              onChanged: (v) => setState(() => _importAxes = v ?? false),
              title: const Text('Также заменить значения осей'),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(context).pop(_ImportChoice(importAxes: _importAxes)),
          child: const Text('Импорт'),
        ),
      ],
    );
  }
}
