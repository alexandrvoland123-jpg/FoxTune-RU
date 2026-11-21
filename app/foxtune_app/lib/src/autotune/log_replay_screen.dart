import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:foxtune_tune/foxtune_tune.dart';

import '../dashboard/gauge_status.dart';
import '../files/file_saving.dart';
import '../logging/log_files.dart';
import '../tune/burn_actions.dart';
import '../tune/msq_actions.dart';
import '../tune/offline_tune.dart';
import '../tune/table_grid.dart';
import '../tune/tune_controller.dart';
import '../window/window_app_bar.dart';
import 'autotune_controller.dart';
import 'autotune_widgets.dart';

/// Works out what replaying [log] would do to [tune].
typedef LogReplayRunner = Future<LogReplayResult> Function(
  TuneState tune,
  String log,
  AutotuneSettings settings,
);

/// Runs a replay's analysis away from the UI.
///
/// A half-hour log takes about a second on a desktop, and several on a phone:
/// long enough to freeze the screen if run on it.
final logReplayRunnerProvider = Provider<LogReplayRunner>(
  (ref) => _replayInBackground,
);

Future<LogReplayResult> _replayInBackground(
  TuneState tune,
  String log,
  AutotuneSettings settings,
) => Isolate.run(
  () =>
      LogReplay.analyse(tune: tune, log: MslLog.parse(log), settings: settings),
);

/// Replays a recorded log into the VE table.
///
/// Opened from the Autotune tab, against the loaded tune - the connected
/// ECU's, or a file being edited with no ECU at all. Either way the log is
/// worked through on a copy and what it would change is shown first: nothing
/// is corrected until Apply, which is then an ordinary edit - burned or not as
/// the tuner decides, or for a file, saved or not.
class LogReplayScreen extends ConsumerStatefulWidget {
  const LogReplayScreen({super.key});

  /// Opens a replay into the loaded tune.
  static Future<void> open(BuildContext context) => Navigator.of(context)
      .push(MaterialPageRoute<void>(builder: (_) => const LogReplayScreen()));

  @override
  ConsumerState<LogReplayScreen> createState() => _LogReplayScreenState();
}

class _LogReplayScreenState extends ConsumerState<LogReplayScreen> {
  late AutotuneSettings _settings = ref.read(autotuneProvider).settings;

  String? _logName;
  String? _logText;

  /// The tune as analysed, for showing what the replay changes.
  TuneState? _before;
  LogReplayResult? _result;

  /// Why the log could not be read at all.
  String? _problem;

  bool _busy = false;
  bool _applied = false;

  /// Which analysis is the latest, so a slow one cannot land over it.
  int _run = 0;

  CellSelection _selection = const CellSelection.single(0, 0);
  bool _showCoverage = false;

  TuneState? get _tune => ref.read(tuneProvider).value;

  @override
  Widget build(BuildContext context) {
    final tune = ref.watch(tuneProvider).value;
    final offline = ref.watch(editingOfflineProvider);

    return Scaffold(
      appBar: const WindowAppBar(title: Text('Воспроизвести журнал')),
      body: SafeArea(
        child: tune == null
            ? const _Message(
                text:
                    'Тюн больше не загружен. Подключитесь или откройте файл снова, чтобы воспроизвести в нём журнал.'
                    '',
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _toolbar(context, tune, offline: offline),
                  const Divider(height: 1),
                  _summary(context),
                  if (_problem ?? _result?.blockedReason case final reason?)
                    _Notice(text: reason, warning: true),
                  if (_applied)
                    _Notice(
                      text: offline
                          ? 'Применено к тюну. Сохраните, чтобы оставить.'
                          : 'Применено к тюну. В ЭБУ ничего не попадёт, пока вы не запишете во флеш.'
                                '',
                    ),
                  const Divider(height: 1),
                  Expanded(child: _body(context, tune)),
                ],
              ),
      ),
    );
  }

  Widget _toolbar(
    BuildContext context,
    TuneState tune, {
    required bool offline,
  }) {
    final theme = Theme.of(context);
    final result = _result;
    final permission = ref.watch(editPermissionProvider);
    final canApply =
        !_busy &&
        !_applied &&
        result != null &&
        result.changes.isNotEmpty &&
        permission.allowed;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (offline)
            if (ref.watch(offlineTuneProvider) case final open?)
              Text('Тюн: ${open.fileName}', style: theme.textTheme.labelLarge),
          FilledButton.tonalIcon(
            onPressed: _busy ? null : () => _chooseLog(context),
            icon: const Icon(Icons.folder_open),
            label: Text(_logName == null ? 'Выберите журнал' : 'Другой журнал'),
          ),
          TextButton.icon(
            onPressed: _busy ? null : () => _editLimits(context),
            icon: const Icon(Icons.tune),
            label: const Text('Пределы'),
          ),
          if (!offline)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Switch(
                  value: ref.watch(writeModeProvider),
                  onChanged: (v) => ref.read(writeModeProvider.notifier).set(v),
                ),
                const SizedBox(width: 4),
                Text('Режим записи', style: theme.textTheme.labelLarge),
              ],
            ),
          FilledButton.icon(
            onPressed: canApply ? () => _apply(context) : null,
            icon: const Icon(Icons.check),
            label: const Text('Применить'),
          ),
          if (offline)
            FilledButton.icon(
              onPressed: () => MsqActions.save(context, ref, tune),
              icon: const Icon(Icons.save),
              label: const Text('Сохранить .msq'),
            )
          else
            FilledButton.icon(
              onPressed: permission.allowed && tune.isDirty
                  ? () => BurnActions.confirmAndBurn(context, ref, tune)
                  : null,
              icon: const Icon(Icons.save),
              label: const Text('Записать в ЭБУ'),
            ),
          if (!permission.allowed &&
              result != null &&
              result.changes.isNotEmpty)
            Text(
              permission.reason ?? 'Запись не разрешена.',
              style: theme.textTheme.labelSmall?.copyWith(
                color: StatusPalette.warning,
              ),
            ),
        ],
      ),
    );
  }

  Widget _summary(BuildContext context) {
    final theme = Theme.of(context);
    final result = _result;
    final skipped = result?.skipped.values.fold(0, (a, b) => a + b) ?? 0;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Wrap(
        spacing: 18,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            _busy
                ? 'Чтение ${_logName ?? 'журнала'}...'
                : _logName == null
                ? 'Журнал не выбран'
                : 'Журнал: $_logName',
            style: theme.textTheme.labelLarge,
          ),
          if (result != null && !result.blocked) ...[
            AutotuneStat(label: 'Строки', value: '${result.rows}'),
            AutotuneStat(label: 'Использовано', value: '${result.used}'),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AutotuneStat(label: 'Пропущено', value: '$skipped'),
                if (skipped > 0)
                  TextButton(
                    onPressed: () => _showSkipped(context, result),
                    child: const Text('Почему?'),
                  ),
              ],
            ),
            AutotuneStat(
              label: _applied ? 'Ячеек изменено' : 'Ячеек для изменения',
              value: '${result.changes.length}',
            ),
          ],
        ],
      ),
    );
  }

  Widget _body(BuildContext context, TuneState tune) {
    final result = _result;
    if (_busy) return const Center(child: CircularProgressIndicator());
    if (_logName == null) {
      return const _Message(
        text:
            'Выберите записанный журнал, чтобы увидеть, что он изменит в таблице VE. Ничего не изменится, пока вы не примените.'
            '',
      );
    }
    final preview = result?.preview;
    final before = _before;
    if (result == null || preview == null || before == null) {
      return const SizedBox.shrink();
    }

    final definition = tune.definition;
    final table = definition.tableNamed(definition.veAnalyze!.table);
    final shown = table == null ? null : TableView.of(preview, table);
    final was = table == null ? null : TableView.of(before, table);
    if (shown == null || was == null) {
      return const _Message(text: 'Не удалось определить таблицу VE.');
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  result.changes.isEmpty
                      ? 'Менять нечего: ни в одной ячейке не набралось достаточно показаний с отклонением от цели.'
                            ''
                      : _showCoverage
                      ? 'Заливка показывает, где в журнале были данные.'
                      : 'Таблица в том виде, как её оставит журнал, изменённые ячейки отмечены.'
                            '',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              TextButton.icon(
                onPressed: () => setState(() => _showCoverage = !_showCoverage),
                icon: const Icon(Icons.gradient, size: 18),
                label: Text(_showCoverage ? 'Показать значения' : 'Показать покрытие'),
              ),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: TableGrid(
              view: shown,
              selection: _selection,
              editable: false,
              changes: shown.changesAgainst(was),
              coverage: _showCoverage ? _coverage(result) : null,
              onSelectionChanged: (s) => setState(() => _selection = s),
              onEdit: (_) {},
            ),
          ),
        ),
      ],
    );
  }

  /// Per-cell data volume, scaled against the best-covered cell.
  static Map<({int row, int column}), double> _coverage(
    LogReplayResult result,
  ) {
    var most = 0;
    for (final cell in result.coverage.values) {
      if (cell.samples > most) most = cell.samples;
    }
    if (most == 0) return const {};
    return {
      for (final entry in result.coverage.entries)
        entry.key: entry.value.samples / most,
    };
  }

  Future<void> _chooseLog(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final choice = await showModalBottomSheet<_LogChoice>(
      context: context,
      showDragHandle: true,
      builder: (_) => const _LogPicker(),
    );
    if (choice == null || !mounted) return;

    PickedFile? picked;
    try {
      picked = switch (choice) {
        _RecordedLog(:final file) => PickedFile(
          name: file.path.split(RegExp(r'[/\\]')).last,
          bytes: await file.readAsBytes(),
        ),
        _LogFromFile() =>
          await ref
              .read(fileSavingProvider)
              .pickFile(
                dialogTitle: 'Журнал для воспроизведения',
                extensions: const ['msl'],
              ),
      };
    } on Object catch (error) {
      messenger.showSnackBar(
        SnackBar(
          backgroundColor: StatusPalette.critical,
          content: Text(
            error is WrongFileTypeException
                ? error.message
                : 'Не удалось прочитать журнал: $error',
          ),
        ),
      );
      return;
    }
    if (picked == null || !mounted) return;

    setState(() {
      _logName = picked!.name;
      _logText = picked.text;
    });
    await _analyse();
  }

  Future<void> _analyse() async {
    final tune = _tune;
    final text = _logText;
    if (tune == null || text == null) return;

    final run = ++_run;
    final before = tune.copy();
    setState(() {
      _busy = true;
      _result = null;
      _problem = null;
      _applied = false;
    });

    LogReplayResult? result;
    String? problem;
    try {
      result = await ref.read(logReplayRunnerProvider)(before, text, _settings);
    } on FormatException catch (error) {
      problem = '$_logName: ${error.message}';
    } on Object catch (error) {
      problem = 'Не удалось воспроизвести $_logName: $error';
    }
    if (!mounted || run != _run) return;
    setState(() {
      _busy = false;
      _before = before;
      _result = result;
      _problem = problem;
    });
  }

  Future<void> _editLimits(BuildContext context) async {
    final updated = await AutotuneLimitsDialog.show(context, _settings);
    if (updated == null || !mounted) return;
    setState(() => _settings = updated);
    await _analyse();
  }

  void _apply(BuildContext context) {
    final tune = _tune;
    final result = _result;
    if (tune == null || result == null) return;

    if (!LogReplay.applyTo(tune, result)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Таблица VE изменилась после чтения журнала, поэтому он прочитан заново по таблице в её текущем виде.'
            '',
          ),
        ),
      );
      _analyse();
      return;
    }
    ref.read(tuneProvider.notifier).notifyEdited();
    setState(() => _applied = true);
  }

  void _showSkipped(BuildContext context, LogReplayResult result) {
    final reasons = result.skipped.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                'Строк пропущено',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            for (final reason in reasons)
              ListTile(
                dense: true,
                title: Text(_skipReasonLabel(reason.key)),
                trailing: Text('${reason.value}'),
              ),
          ],
        ),
      ),
    );
  }
}

/// Where a log to replay comes from.
sealed class _LogChoice {
  const _LogChoice();
}

class _RecordedLog extends _LogChoice {
  const _RecordedLog(this.file);
  final File file;
}

class _LogFromFile extends _LogChoice {
  const _LogFromFile();
}

/// FoxTune's own recent logs, and a way to open any other.
class _LogPicker extends ConsumerWidget {
  const _LogPicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final logs = ref.watch(recentLogsProvider).value ?? const <File>[];

    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'Журнал для воспроизведения',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.folder_open),
            title: const Text('Открыть файл...'),
            subtitle: const Text('Журнал .msl из FoxTune или TunerStudio'),
            onTap: () => Navigator.of(context).pop(const _LogFromFile()),
          ),
          for (final file in logs)
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: Text(
                file.path.split(RegExp(r'[/\\]')).last,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(LogFiles.describe(file)),
              onTap: () => Navigator.of(context).pop(_RecordedLog(file)),
            ),
        ],
      ),
    );
  }
}

String _skipReasonLabel(String key) => switch (key) {
  'Settling' => 'Успокоение',
  'Table since changed' => 'Таблица с тех пор изменилась',
  'Off the table' => 'За пределами таблицы',
  'Implausible mixture' => 'Недостоверное показание смеси',
  'Custom filter' => 'Пользовательский фильтр',
  'No time' => 'Нет времени',
  'Unusable' => 'Непригодная строка',
  _ => key,
};

class _Notice extends StatelessWidget {
  const _Notice({required this.text, this.warning = false});

  final String text;
  final bool warning;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colour = warning ? StatusPalette.warning : StatusPalette.good;
    return Container(
      width: double.infinity,
      color: colour.withValues(alpha: 0.12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            warning ? Icons.warning_amber_rounded : Icons.check_circle_outline,
            size: 16,
            color: colour,
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Text(text, textAlign: TextAlign.center),
    ),
  );
}
