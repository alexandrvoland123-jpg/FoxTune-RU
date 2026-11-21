import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';

import '../app_settings/app_settings.dart';
import '../connection/connection_controller.dart';
import '../connection/connection_state.dart';
import '../dashboard/dashboard_editor.dart' show confirm;
import '../dashboard/gauge_status.dart';
import '../files/file_saving.dart';
import '../window/window_app_bar.dart';
import 'choose_definition.dart';
import 'definition_library.dart';
import 'download_definition.dart';

/// Every ECU definition FoxTune has, and where to add, save and remove them.
///
/// The built-in one first, then those kept on this device: downloaded or
/// chosen when connecting, or added here ahead of time - which is how to have
/// one ready for an ECU somewhere without internet.
class DefinitionsScreen extends ConsumerStatefulWidget {
  const DefinitionsScreen({super.key});

  /// Opens the list over [context].
  static Future<void> open(BuildContext context) => Navigator.of(context)
      .push(MaterialPageRoute<void>(builder: (_) => const DefinitionsScreen()));

  @override
  ConsumerState<DefinitionsScreen> createState() => _DefinitionsScreenState();
}

/// What the screen is busy with, if anything.
enum _Work { adding, downloading }

class _DefinitionsScreenState extends ConsumerState<DefinitionsScreen> {
  _Work? _working;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entries = ref.watch(definitionEntriesProvider);
    final connection = ref.watch(connectionProvider);
    final inUse = connection is EcuConnected
        ? connection.definition?.identity.signature
        : null;
    final downloads = ref.watch(
      appSettingsProvider.select((s) => s.downloadDefinitionsFor),
    );

    return Scaffold(
      appBar: const WindowAppBar(title: Text('Определения ЭБУ')),
      body: SafeArea(
        child: entries.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('Не удалось получить список определений: $error'),
            ),
          ),
          data: (list) {
            final kept = [
              for (final entry in list)
                if (!entry.isBuiltIn) entry,
            ];
            return Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: ListView(
                  padding: const EdgeInsets.only(bottom: 16),
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                      child: Text(
                        'ЭБУ читается через определение для его точной сборки прошивки, подбираемое по сообщаемой им сигнатуре. FoxTune ищет его сначала среди встроенных, затем среди сохранённых на этом устройстве, а затем — если разрешено ниже — скачивает.'
                        ''
                        ''
                        ''
                        '',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    const _Heading('Скачивать автоматически'),
                    for (final (family, subtitle) in const [
                      (
                        EcuFamily.speeduino,
                        'С speeduino.com, для релиза, о котором сообщает подключённый Speeduino'
                            '',
                      ),
                      (
                        EcuFamily.rusefi,
                        'С rusefi.com, для точной сборки, о которой сообщает подключённый rusEFI'
                            '',
                      ),
                    ])
                      SwitchListTile(
                        title: Text(
                          family == EcuFamily.rusefi ? 'rusEFI' : 'Speeduino',
                        ),
                        subtitle: Text(subtitle),
                        value: downloads.contains(family),
                        onChanged: (on) => ref
                            .read(appSettingsProvider.notifier)
                            .update((s) => s.withDownloadsFor(family, on: on)),
                      ),
                    const _Heading('Встроенное'),
                    for (final entry in list)
                      if (entry.isBuiltIn)
                        _EntryTile(
                          entry: entry,
                          inUse: entry.signature == inUse,
                          onSave: () => _save(entry),
                        ),
                    const _Heading('На этом устройстве'),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          FilledButton.tonalIcon(
                            onPressed: _working == null ? _add : null,
                            icon: _working == _Work.adding
                                ? const _Spinner()
                                : const Icon(Icons.add),
                            label: const Text('Добавить из файла'),
                          ),
                          FilledButton.tonalIcon(
                            onPressed: _working == null ? _download : null,
                            icon: _working == _Work.downloading
                                ? const _Spinner()
                                : const Icon(Icons.cloud_download_outlined),
                            label: const Text('Скачать'),
                          ),
                        ],
                      ),
                    ),
                    if (kept.isEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                        child: Text(
                          'Пока нет. Определение, скачанное или выбранное при подключении, сохраняется здесь. Если добавить его заранее, ЭБУ, для которого оно предназначено, сможет подключиться без интернета.'
                          ''
                          '',
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                    for (final entry in kept)
                      _EntryTile(
                        entry: entry,
                        inUse: entry.signature == inUse,
                        onSave: entry.problem == null
                            ? () => _save(entry)
                            : null,
                        onRemove: () =>
                            _remove(entry, inUse: entry.signature == inUse),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  void _tell(ScaffoldMessengerState messenger, String message) =>
      tellAboutDefinition(messenger, message);

  void _complain(ScaffoldMessengerState messenger, String message) =>
      tellAboutDefinition(messenger, message, problem: true);

  Future<void> _add() async {
    final messenger = ScaffoldMessenger.of(context);
    final picked = await pickDefinitionFile(
      ref,
      messenger,
      title: 'Добавить определение',
    );
    if (picked == null || !mounted) return;
    final library = ref.read(definitionLibraryProvider);
    await _keep(
      ({required replace}) => library.add(
        decodeDefinition(picked.bytes),
        fileName: picked.name,
        replace: replace,
      ),
      messenger,
      work: _Work.adding,
      source: picked.name,
      replacement: picked.name,
      done: 'Добавлено',
    );
  }

  Future<void> _download() async {
    final messenger = ScaffoldMessenger.of(context);
    final choice = await DownloadDefinitionDialog.ask(context);
    if (choice == null || !mounted) return;
    final library = ref.read(definitionLibraryProvider);
    final rusEfi = choice.family == EcuFamily.rusefi;
    await _keep(
      ({required replace}) => rusEfi
          ? library.downloadRusEfi(choice.version, replace: replace)
          : library.downloadSpeeduino(choice.version, replace: replace),
      messenger,
      work: _Work.downloading,
      source: choice.version,
      replacement: 'определение с ${rusEfi ? 'rusefi.com' : 'speeduino.com'}',
      done: 'Скачано',
    );
  }

  /// Runs [work] with its button showing it is busy.
  ///
  /// Reading a definition holds up the screen while it runs - a rusEFI one is
  /// some 13,000 lines - so the button is drawn busy before it starts, to say
  /// why.
  Future<T> _busy<T>(_Work work, Future<T> Function() run) async {
    setState(() => _working = work);
    await WidgetsBinding.instance.endOfFrame;
    try {
      return await run();
    } finally {
      if (mounted) setState(() => _working = null);
    }
  }

  /// Keeps the definition [keep] reads or downloads, from [source], asking
  /// first before it replaces one kept already with [replacement].
  Future<void> _keep(
    Future<DefinitionEntry> Function({required bool replace}) keep,
    ScaffoldMessengerState messenger, {
    required _Work work,
    required String source,
    required String replacement,
    required String done,
    bool replace = false,
  }) async {
    final DefinitionEntry entry;
    try {
      entry = await _busy(work, () => keep(replace: replace));
    } on DefinitionExistsException catch (error) {
      if (!mounted) return;
      final proceed = await confirm(
        context,
        title: 'Заменить сохранённое определение?',
        message:
            'Определение для «${error.signature}» уже сохранено. Заменить его на $replacement?'
            '',
        action: 'Заменить',
      );
      if (proceed) {
        await _keep(
          keep,
          messenger,
          work: work,
          source: source,
          replacement: replacement,
          done: done,
          replace: true,
        );
      }
      return;
    } on DefinitionRefusedException catch (error) {
      _complain(messenger, '$source: ${error.message}');
      return;
    } on Object catch (error) {
      _complain(
        messenger,
        '$source - не определение, которое FoxTune может прочитать: $error',
      );
      return;
    }
    ref.invalidate(definitionEntriesProvider);

    // An ECU connected and waiting for this very definition takes it at once.
    final connection = ref.read(connectionProvider);
    if (connection is EcuConnected &&
        !connection.definitionMatches &&
        connection.identification.signature.trim() == entry.signature) {
      await ref.read(connectionProvider.notifier).retryDefinition();
      _tell(messenger, '$done ${entry.name}, и теперь оно используется.');
    } else {
      _tell(messenger, '$done ${entry.name}.');
    }
  }

  Future<void> _save(DefinitionEntry entry) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final saved = await ref
          .read(fileSavingProvider)
          .saveBytes(
            dialogTitle: 'Сохранить определение',
            fileName: entry.suggestedFileName,
            extension: 'ini',
            bytes: await ref.read(definitionLibraryProvider).bytesOf(entry),
          );
      if (saved != null) _tell(messenger, 'Сохранено: $saved');
    } on Object catch (error) {
      _complain(messenger, 'Не удалось сохранить определение: $error');
    }
  }

  Future<void> _remove(DefinitionEntry entry, {required bool inUse}) async {
    final messenger = ScaffoldMessenger.of(context);
    final proceed = await confirm(
      context,
      title: 'Убрать ${entry.name}?',
      message: inUse
          ? 'Удаляется с этого устройства. Подключённый ЭБУ продолжит работать с ним до отключения; в следующий раз оно будет искаться снова.'
                ''
                ''
          : 'Удаляется с этого устройства. Нужное ЭБУ определение будет искаться снова при подключении.'
                '',
      action: 'Убрать',
    );
    if (!proceed) return;
    try {
      await ref.read(definitionLibraryProvider).remove(entry);
    } on Object catch (error) {
      _complain(messenger, 'Не удалось удалить: $error');
      return;
    }
    ref.invalidate(definitionEntriesProvider);
    _tell(messenger, 'Убрано: ${entry.name}.');
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Text(
        text,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}

enum _EntryAction { save, remove }

class _EntryTile extends StatelessWidget {
  const _EntryTile({
    required this.entry,
    required this.inUse,
    this.onSave,
    this.onRemove,
  });

  final DefinitionEntry entry;
  final bool inUse;
  final VoidCallback? onSave;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final problem = entry.problem;

    return ListTile(
      leading: Icon(
        problem != null
            ? Icons.error_outline
            : switch (entry.source) {
                DefinitionSource.bundled => Icons.inventory_2_outlined,
                DefinitionSource.downloaded => Icons.cloud_download_outlined,
                DefinitionSource.picked => Icons.insert_drive_file_outlined,
                DefinitionSource.cached => Icons.description_outlined,
              },
        color: problem != null ? StatusPalette.critical : null,
      ),
      title: Text(entry.name, overflow: TextOverflow.ellipsis),
      subtitle: Text(_describe(entry)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (inUse) const _InUse(),
          PopupMenuButton<_EntryAction>(
            tooltip: 'Определение',
            onSelected: (action) => switch (action) {
              _EntryAction.save => onSave?.call(),
              _EntryAction.remove => onRemove?.call(),
            },
            itemBuilder: (_) => [
              if (onSave != null)
                const PopupMenuItem(
                  value: _EntryAction.save,
                  child: Text('Сохранить копию'),
                ),
              if (onRemove != null)
                PopupMenuItem(
                  value: _EntryAction.remove,
                  child: Text(
                    'Убрать',
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  static String _describe(DefinitionEntry entry) {
    if (entry.problem case final problem?) return problem;
    final origin = switch (entry.source) {
      DefinitionSource.bundled => 'Поставляется с FoxTune',
      DefinitionSource.downloaded =>
        'Скачано с ${entry.url?.host ?? 'сайта проекта прошивки'}',
      DefinitionSource.picked =>
        entry.fileName == null
            ? 'Добавлено из файла'
            : 'Добавлено из ${entry.fileName}',
      DefinitionSource.cached => 'Сохранено с прошлого подключения',
    };
    return [
      origin,
      if (entry.added case final added?)
        '${added.year}-${_two(added.month)}-${_two(added.day)}',
      if (entry.sizeBytes case final bytes?) _size(bytes),
    ].join(' · ');
  }

  static String _size(int bytes) => bytes >= 1024 * 1024
      ? '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB'
      : '${(bytes / 1024).toStringAsFixed(0)} kB';

  static String _two(int value) => value.toString().padLeft(2, '0');
}

/// Small enough to stand in for a button's icon.
class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) => const SizedBox.square(
    dimension: 16,
    child: CircularProgressIndicator(strokeWidth: 2),
  );
}

/// Marks the definition the connected ECU is being read through.
class _InUse extends StatelessWidget {
  const _InUse();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Text(
          'Используется',
          style: theme.textTheme.labelSmall?.copyWith(
            color: scheme.onPrimaryContainer,
          ),
        ),
      ),
    );
  }
}
