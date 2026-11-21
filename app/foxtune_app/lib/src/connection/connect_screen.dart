import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart' show EcuFamily;
import 'package:foxtune_transport/foxtune_transport.dart';

import '../app_settings/app_settings_screen.dart';
import '../app_settings/wallpaper_background.dart';
import '../autotune/autotune_controller.dart';
import '../autotune/autotune_screen.dart';
import '../branding/foxtune_logo.dart';
import '../dashboard/dashboard_controller.dart';
import '../dashboard/dashboard_screen.dart';
import '../dashboard/gauge_status.dart';
import '../dashboard/sample_history.dart';
import '../definitions/choose_definition.dart';
import '../definitions/definition_library.dart';
import '../definitions/definitions_screen.dart';
import '../logging/log_controller.dart';
import '../loggers/trigger_logger_controller.dart';
import '../loggers/trigger_logger_screen.dart';
import '../motion/transitions.dart';
import '../settings/settings_screen.dart';
import '../tune/msq_actions.dart';
import '../tune/offline_tune.dart';
import '../tune/recovered_edits.dart';
import '../tune/table_editor_screen.dart';
import '../tune/tune_controller.dart';
import '../window/window_app_bar.dart';
import 'connection_controller.dart';
import 'connection_state.dart';
import 'connection_watchdog.dart';

/// The app shell: pick a port, connect, then hand off to the dashboard and
/// table editor.
///
/// Connecting alone changes nothing on the ECU. Editing requires a signature
/// match and an explicit write-mode opt-in, and nothing is committed until a
/// burn - see [WritePermission].
class ConnectScreen extends ConsumerStatefulWidget {
  const ConnectScreen({super.key});

  @override
  ConsumerState<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends ConsumerState<ConnectScreen> {
  @override
  void initState() {
    super.initState();
    // These live as long as the app: one notices a connection ending, one
    // keeps the screen on while there is one, and one rescues edits that were
    // never burned.
    //
    // Listened to rather than watched. Riverpod pauses a widget's watch while
    // the widget is hidden - as this screen is under any pushed route - and a
    // provider no one is actively listening to is paused with it: its streams
    // stop, and it rebuilds only once read again, not as what it depends on
    // changes. A manual listen is never paused.
    ref.listenManual(connectionWatchdogProvider, (_, _) {});
    ref.listenManual(screenWakeWatcherProvider, (_, _) {});
    ref.listenManual(unburnedEditsGuardProvider, (_, _) {});
  }

  @override
  Widget build(BuildContext context) {
    final connection = ref.watch(connectionProvider);
    // A file open with no ECU takes the port list's place until it is closed.
    final file = connection is EcuDisconnected
        ? ref.watch(offlineTuneProvider)
        : null;

    return Scaffold(
      appBar: WindowAppBar(
        title: const FoxTuneLogo(),
        actions: [
          if (file != null) ...[
            IconButton(
              tooltip: 'Сохранить как .msq',
              icon: const Icon(Icons.save_outlined),
              onPressed: () => MsqActions.save(context, ref, file.tune),
            ),
            IconButton(
              tooltip: 'Закрыть ${file.fileName}',
              icon: const Icon(Icons.close),
              onPressed: () async {
                final open = ref.read(offlineTuneProvider);
                if (open == null) return;
                if (await OfflineTuneController.confirmClose(context, open)) {
                  ref.read(offlineTuneProvider.notifier).close();
                }
              },
            ),
          ] else if (connection is EcuDisconnected ||
              connection is EcuConnectionFailed ||
              connection is EcuConnectionLost)
            IconButton(
              tooltip: 'Повторить поиск портов',
              icon: const Icon(Icons.refresh),
              onPressed: () => ref.invalidate(portsProvider),
            ),
          if (connection is EcuConnected) ...[
            IconButton(
              tooltip: 'Параметры подключения',
              icon: const Icon(Icons.info_outline),
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                showDragHandle: true,
                isScrollControlled: true,
                builder: (_) => _ConnectedView(state: connection),
              ),
            ),
            IconButton(
              tooltip: 'Отключить',
              icon: const Icon(Icons.link_off),
              onPressed: () => confirmDisconnect(context, ref),
            ),
          ],
          // Last, so it sits at the end of the bar in every state - next to
          // the window buttons, where it does not move as the others come and
          // go.
          IconButton(
            tooltip: 'Настройки приложения',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => AppSettingsScreen.open(context),
          ),
        ],
      ),
      body: WallpaperBackground(
        child: SafeArea(
          child: switch (connection) {
            EcuConnecting(:final port, :final stage) => _Busy(
              message:
                  stage ??
                  'FOX1: Начинаю работу. Подключаюсь к ${port.label}...',
            ),
            EcuConnected(definition: null) => _NeedsDefinition(
              state: connection,
            ),
            EcuConnected() => _ConnectedShell(connection: connection),
            EcuConnectionFailed() => _WithRecoveredEdits(
              child: _FailedView(state: connection),
            ),
            EcuConnectionLost() => _WithRecoveredEdits(
              child: _LostView(state: connection),
            ),
            EcuDisconnected() when file != null => const _OfflineShell(),
            EcuDisconnected() => const _WithRecoveredEdits(child: _PortList()),
          },
        ),
      ),
    );
  }
}

class _Busy extends StatelessWidget {
  const _Busy({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 16),
        Text(message, textAlign: TextAlign.center),
      ],
    ),
  );
}

class _PortList extends ConsumerWidget {
  const _PortList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ports = ref.watch(portsProvider);

    return ports.when(
      loading: () => const _Busy(message: 'Поиск последовательных портов...'),
      error: (error, _) => _Message(
        icon: Icons.usb_off,
        title: 'Не удаётся получить список последовательных портов',
        detail: error.toString(),
      ),
      data: (list) {
        if (list.isEmpty) {
          return _Message(
            icon: Icons.usb_off,
            title: 'Последовательные порты не найдены',
            detail: Platform.isAndroid
                ? 'Подключите ЭБУ кабелем USB OTG. Он появится здесь сам - а если Android предложит открыть FoxTune, отметьте «всегда», чтобы он перестал спрашивать разрешение.'
                      ''
                      ''
                      ''
                : 'Подключите ЭБУ по USB и повторите поиск.\n\nВ Linux может потребоваться состоять в группе dialout:\nsudo usermod -aG dialout \$USER'
                      ''
                      '',
            action: Column(
              children: [
                FilledButton.tonalIcon(
                  onPressed: () => ref.invalidate(portsProvider),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Сканировать заново'),
                ),
                const SizedBox(height: 8),
                const _NetworkTile(),
                const _OpenTuneTile(),
              ],
            ),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: list.length + 2,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, index) {
            if (index == list.length) return const _NetworkTile();
            if (index == list.length + 1) return const _OpenTuneTile();
            final port = list[index];
            return ListTile(
              leading: Icon(port.isLikelyEcu ? Icons.memory : Icons.usb),
              title: Text(port.address),
              subtitle: Text(_subtitleFor(port)),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => ref.read(connectionProvider.notifier).connect(port),
            );
          },
        );
      },
    );
  }

  static String _subtitleFor(EcuPort port) {
    final parts = <String>[
      if (port.description?.isNotEmpty ?? false) port.description!,
      if (port.manufacturer?.isNotEmpty ?? false) port.manufacturer!,
      if (port.vendorId != null && port.productId != null)
        '${_hex(port.vendorId!)}:${_hex(port.productId!)}',
    ];
    return parts.isEmpty ? 'Неизвестное устройство' : parts.join(' · ');
  }

  static String _hex(int value) =>
      value.toRadixString(16).padLeft(4, '0').toUpperCase();
}

class _ConnectedView extends ConsumerWidget {
  const _ConnectedView({required this.state});
  final EcuConnected state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final definition = state.definition;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _SignatureCard(state: state),
        const SizedBox(height: 16),
        Card(
          child: Column(
            children: [
              _Row(label: 'Порт', value: state.port.address),
              _Row(label: 'Сигнатура', value: state.identification.signature),
              _Row(label: 'Версия', value: state.identification.version),
              if (definition != null) ...[
                _Row(
                  label: 'Определение',
                  value: switch (state.definitionSource) {
                    DefinitionSource.bundled => 'Встроено в FoxTune',
                    DefinitionSource.cached => 'Сохранено на этом устройстве',
                    DefinitionSource.downloaded => 'Скачано для этой сборки',
                    DefinitionSource.picked => 'Выбрано из файла',
                    null => 'Неизвестно',
                  },
                ),
                _Row(
                  label: 'Страницы',
                  value:
                      '${definition.constants.pageCount} (${definition.constants.pageSizes.fold<int>(0, (a, b) => a + b)} байт)'
                      '',
                ),
                _Row(
                  label: 'Фактор блочного чтения',
                  value:
                      '${definition.constants.blockingFactor ?? "неизвестно"} байт',
                ),
                _Row(
                  label: 'Блок реального времени',
                  value:
                      '${definition.outputChannels.blockSize ?? 0} байт, каналов: ${definition.outputChannels.channels.length}'
                      '',
                ),
                _Row(
                  label: 'Таблицы / кривые',
                  value:
                      '${definition.tables.length} / '
                      '${definition.curves.length}',
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 24),
        Builder(
          builder: (context) {
            final permission = ref.watch(writePermissionProvider);
            return Text(
              permission.allowed
                  ? 'Режим записи включён. Изменения проверяются по контрольной сумме самого ЭБУ перед записью во флеш.'
                        ""
                  // Be specific: a signature mismatch reads very differently
                  // from write mode simply being off.
                  : permission.reason ?? 'Только чтение.',
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
            );
          },
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: () async {
            // Ask over the sheet, and close it only once actually
            // disconnected - closing first would leave the question with no
            // screen to be asked on.
            final navigator = Navigator.of(context);
            if (await confirmDisconnect(context, ref)) navigator.pop();
          },
          icon: const Icon(Icons.link_off),
          label: const Text('Отключить'),
        ),
      ],
    );
  }
}

class _SignatureCard extends StatelessWidget {
  const _SignatureCard({required this.state});
  final EcuConnected state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final (
      IconData icon,
      Color color,
      String title,
      String detail,
    ) = switch (state.signatureStatus) {
      SignatureStatus.matched => (
        Icons.verified,
        scheme.primary,
        'Определение совпадает',
        'Загруженное определение описывает эту прошивку, поэтому смещениям страниц можно доверять.'
            '',
      ),
      SignatureStatus.mismatched => (
        Icons.warning_amber,
        scheme.error,
        'Определение не совпадает',
        'ЭБУ сообщает «${state.identification.signature}», а загруженное определение для «${state.expectedSignature}». Смещения могут быть неверны, поэтому запись остаётся отключённой.'
            ''
            '',
      ),
      SignatureStatus.unknown => (
        Icons.help_outline,
        scheme.outline,
        'Определение не загружено',
        'Без определения раскладка страниц неизвестна.',
      ),
    };

    return Card(
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 32),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(detail, style: theme.textTheme.bodySmall),
                  if (state.signatureStatus != SignatureStatus.matched) ...[
                    const SizedBox(height: 8),
                    const _DefinitionActions(),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Choosing the definition file, downloading it where its firmware project
/// publishes it, and the list of every definition FoxTune has.
class _DefinitionActions extends ConsumerWidget {
  const _DefinitionActions({this.alignment = WrapAlignment.start});

  final WrapAlignment alignment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connection = ref.watch(connectionProvider);
    final site = connection is EcuConnected
        ? definitionDownloadSite(connection.identification)
        : null;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: alignment,
      children: [
        FilledButton.tonalIcon(
          onPressed: () => chooseDefinition(context, ref),
          icon: const Icon(Icons.file_open_outlined),
          label: const Text('Выберите файл определения'),
        ),
        if (site != null)
          OutlinedButton.icon(
            onPressed: () =>
                ref.read(connectionProvider.notifier).retryDefinition(),
            icon: const Icon(Icons.download_outlined),
            label: Text('Скачать с $site'),
          ),
        TextButton(
          onPressed: () => DefinitionsScreen.open(context),
          child: const Text('Все определения'),
        ),
      ],
    );
  }
}

/// Connected, but with nothing that describes this ECU.
///
/// Without a definition the bytes mean nothing - not a gauge, not a setting -
/// so rather than tabs full of empty screens this says what was tried and
/// what can be done about it.
class _NeedsDefinition extends ConsumerWidget {
  const _NeedsDefinition({required this.state});
  final EcuConnected state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final rusEfi = state.identification.family == EcuFamily.rusefi;
    final where = rusEfi
        ? 'rusEFI создаёт его для каждой платы и сборки. Он находится в пакете прошивки для вашей платы, в виде zip на диске, который rusEFI ЭБУ монтирует по USB (rusefi.ini.zip), или среди созданных файлов, если вы собирали прошивку сами.'
              ''
              ''
              ''
        : 'Поставляется с прошивкой.';
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(24),
          children: [
            Icon(
              Icons.description_outlined,
              size: 48,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              'Этому ЭБУ нужно его определение',
              style: theme.textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            SelectableText(
              state.identification.signature,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            Text(
              '${state.definitionProblem ?? 'Определение не найдено.'}\n\n$where После выбора оно сохраняется, и больше не спрашивается.'
              '',
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            const _DefinitionActions(alignment: WrapAlignment.center),
            const SizedBox(height: 12),
            Center(
              child: TextButton.icon(
                onPressed: () => confirmDisconnect(context, ref),
                icon: const Icon(Icons.link_off),
                label: const Text('Отключить'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Asks before disconnecting over edits that were never burned.
///
/// The edits are kept either way - they can be saved as a `.msq` from the
/// connect screen - but a tuner who meant to burn first deserves the chance.
///
/// Returns whether it disconnected.
Future<bool> confirmDisconnect(BuildContext context, WidgetRef ref) async {
  final tune = ref.read(tuneProvider).value;
  if (tune != null && tune.isDirty) {
    final pages = tune.dirtyPages.length;
    final proceed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: Icon(Icons.warning_amber_rounded, color: StatusPalette.warning),
        title: const Text('Отключиться с незаписанными изменениями?'),
        content: Text(
          'Страниц с изменениями, не записанными во флеш ЭБУ: $pages. Они сохранятся, чтобы вы могли записать их в .msq, но в ЭБУ их не будет.'
          ''
          '',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Отключить'),
          ),
        ],
      ),
    );
    if (proceed != true) return false;
  }
  // Stopped while the link is still there to tell the ECU: Speeduino's
  // logger stands in for its trigger interrupts until it is told to stop.
  await ref.read(triggerLoggerProvider.notifier).stop();
  await ref.read(connectionProvider.notifier).disconnect();
  return true;
}

/// A connection that was working, and stopped.
class _LostView extends ConsumerWidget {
  const _LostView({required this.state});
  final EcuConnectionLost state;

  @override
  Widget build(BuildContext context, WidgetRef ref) => _Message(
    icon: Icons.link_off,
    title: 'Связь потеряна',
    detail: '${state.reason}\n\n${state.port.label}',
    action: Wrap(
      spacing: 12,
      runSpacing: 8,
      alignment: WrapAlignment.center,
      children: [
        FilledButton.icon(
          onPressed: () => ref.read(connectionProvider.notifier).reconnect(),
          icon: const Icon(Icons.refresh),
          label: const Text('Переподключиться'),
        ),
        OutlinedButton(
          onPressed: () => ref.read(connectionProvider.notifier).disconnect(),
          child: const Text('Назад к портам'),
        ),
      ],
    ),
  );
}

/// Puts rescued edits in front of the user until they are dealt with.
class _WithRecoveredEdits extends ConsumerWidget {
  const _WithRecoveredEdits({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recovered = ref.watch(recoveredEditsProvider);
    if (recovered == null) return child;

    final theme = Theme.of(context);
    return Column(
      children: [
        Material(
          color: StatusPalette.warning.withValues(alpha: 0.14),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.edit_note, color: StatusPalette.warning),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Несохранённые изменения на страницах (${recovered.pages.length}) были сохранены при обрыве связи.'
                        '',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                  ],
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton.icon(
                      onPressed: () async {
                        final saved = await MsqActions.save(
                          context,
                          ref,
                          recovered.tune,
                        );
                        if (saved) {
                          ref.read(recoveredEditsProvider.notifier).clear();
                        }
                      },
                      icon: const Icon(Icons.save_alt),
                      label: const Text('Сохранить как .msq'),
                    ),
                    TextButton(
                      onPressed: () =>
                          ref.read(recoveredEditsProvider.notifier).clear(),
                      child: const Text('Отбросить'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        Expanded(child: child),
      ],
    );
  }
}

class _FailedView extends ConsumerWidget {
  const _FailedView({required this.state});
  final EcuConnectionFailed state;

  @override
  Widget build(BuildContext context, WidgetRef ref) => _Message(
    icon: Icons.error_outline,
    title: 'Не удалось подключиться',
    detail: state.message,
    action: Wrap(
      spacing: 12,
      children: [
        if (state.port != null)
          FilledButton.icon(
            // Through reconnect(), so a network ECU is retried over TCP
            // rather than handed to the USB transport by address.
            onPressed: () => ref.read(connectionProvider.notifier).reconnect(),
            icon: const Icon(Icons.refresh),
            label: const Text('Повторить'),
          ),
        OutlinedButton(
          onPressed: () => ref.read(connectionProvider.notifier).disconnect(),
          child: const Text('Назад к портам'),
        ),
      ],
    ),
  );
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.title,
    required this.detail,
    this.action,
  });

  final IconData icon;
  final String title;
  final String detail;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: theme.colorScheme.outline),
            const SizedBox(height: 16),
            Text(title, style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            if (action != null) ...[const SizedBox(height: 24), action!],
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(label, style: theme.textTheme.labelLarge),
          ),
          Expanded(
            child: SelectableText(value, style: theme.textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }
}

/// Entry point for a Speeduino reached over WiFi rather than a cable.
class _NetworkTile extends ConsumerWidget {
  const _NetworkTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) => ListTile(
    leading: const Icon(Icons.wifi),
    title: const Text('Сетевой ЭБУ'),
    subtitle: const Text('Мост WiFi ESP8266/ESP32 по TCP'),
    trailing: const Icon(Icons.chevron_right),
    onTap: () async {
      final address = await showDialog<String>(
        context: context,
        builder: (_) => const _AddressDialog(),
      );
      if (address == null || address.isEmpty) return;
      await ref.read(connectionProvider.notifier).connectToNetwork(address);
    },
  );
}

/// Entry point for editing a saved tune with no ECU.
class _OpenTuneTile extends ConsumerWidget {
  const _OpenTuneTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) => ListTile(
    leading: const Icon(Icons.file_open_outlined),
    title: const Text('Открыть файл тюна'),
    subtitle: const Text('Править .msq без ЭБУ или воспроизвести в нём журнал'),
    trailing: const Icon(Icons.chevron_right),
    onTap: () => OfflineTuneController.pickAndOpen(context, ref),
  );
}

class _AddressDialog extends StatefulWidget {
  const _AddressDialog();

  @override
  State<_AddressDialog> createState() => _AddressDialogState();
}

class _AddressDialogState extends State<_AddressDialog> {
  final _controller = TextEditingController(text: '192.168.4.1:2000');

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text);

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Подключение к сетевому ЭБУ'),
    content: TextField(
      controller: _controller,
      autofocus: true,
      decoration: const InputDecoration(
        labelText: 'Адрес',
        helperText:
            'хост или хост:порт - по умолчанию 2000; симулятор rusEFI слушает 29001'
            '',
        helperMaxLines: 2,
      ),
      onSubmitted: (_) => _submit(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Отмена'),
      ),
      FilledButton(onPressed: _submit, child: const Text('Подключить')),
    ],
  );
}

/// Dashboard, tables, settings and the rest, once connected.
class _ConnectedShell extends ConsumerStatefulWidget {
  const _ConnectedShell({required this.connection});

  final EcuConnected connection;

  @override
  ConsumerState<_ConnectedShell> createState() => _ConnectedShellState();
}

class _ConnectedShellState extends ConsumerState<_ConnectedShell> {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    // These have to keep up while connected, whatever is on screen - even
    // with a screen pushed over the tabs, which pauses everything the tabs
    // watch. The feed itself, so a screen shown again catches up at once
    // rather than replaying what arrived meanwhile; the graph history, or a
    // graph would have a gap; autotuning, which keeps correcting; and the
    // datalogger, which closes its file when the link drops. Listened to
    // rather than watched, as in [ConnectScreen].
    ref.listenManual(realtimeProvider, (_, _) {});
    ref.listenManual(sampleHistoryProvider, (_, _) {});
    ref.listenManual(autotuneProvider, (_, _) {});
    ref.listenManual(logSessionProvider, (_, _) {});
  }

  /// Where the trigger logger's tab is, when the definition has loggers.
  static const _triggersTab = 4;

  @override
  Widget build(BuildContext context) {
    final triggers = triggerLoggersOf(widget.connection.definition).isNotEmpty;
    final pages = [
      DashboardScreen(connection: widget.connection),
      const TableEditorScreen(),
      const SettingsScreen(),
      AutotuneScreen(connection: widget.connection),
      if (triggers) TriggerLoggerScreen(connection: widget.connection),
    ];
    final index = _index < pages.length ? _index : 0;

    return Column(
      children: [
        Expanded(
          // Kept alive so switching tabs does not restart polling or discard
          // an in-progress edit - and faded in as it is shown.
          child: FadeIndexedStack(index: index, children: pages),
        ),
        NavigationBar(
          selectedIndex: index,
          height: 60,
          onDestinationSelected: (i) {
            // A running logger shares the link with the live data, so it
            // does not carry on unseen.
            if (index == _triggersTab && i != _triggersTab) {
              ref.read(triggerLoggerProvider.notifier).stop();
            }
            setState(() => _index = i);
          },
          destinations: [
            const NavigationDestination(
              icon: Icon(Icons.speed_outlined),
              selectedIcon: Icon(Icons.speed),
              label: 'Приборная панель',
            ),
            const NavigationDestination(
              icon: Icon(Icons.grid_on_outlined),
              selectedIcon: Icon(Icons.grid_on),
              label: 'Таблицы',
            ),
            const NavigationDestination(
              icon: Icon(Icons.tune_outlined),
              selectedIcon: Icon(Icons.tune),
              label: 'Настройки',
            ),
            const NavigationDestination(
              icon: Icon(Icons.auto_graph_outlined),
              selectedIcon: Icon(Icons.auto_graph),
              label: 'Автонастройка',
            ),
            if (triggers)
              const NavigationDestination(
                icon: Icon(Icons.monitor_heart_outlined),
                selectedIcon: Icon(Icons.monitor_heart),
                label: 'Триггеры',
              ),
          ],
        ),
      ],
    );
  }
}

/// Tables, settings and log replay for a file opened with no ECU.
///
/// Only what works without one: no dashboard or trigger logger, which have
/// nothing to show, and no live autotuning.
class _OfflineShell extends ConsumerStatefulWidget {
  const _OfflineShell();

  @override
  ConsumerState<_OfflineShell> createState() => _OfflineShellState();
}

class _OfflineShellState extends ConsumerState<_OfflineShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final file = ref.watch(offlineTuneProvider);
    // Rebuilt as edits land, for the unsaved marker.
    ref.watch(tuneProvider);
    if (file == null) return const SizedBox.shrink();

    return Column(
      children: [
        Material(
          color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.5),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                const Icon(Icons.description_outlined, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${file.fileName}${file.unsaved ? ' - есть несохранённые изменения' : ''}. ЭБУ нет: чтобы отправить в него, подключитесь, загрузите этот файл на вкладке «Таблицы» и запишите во флеш.'
                    ''
                    '',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: FadeIndexedStack(
            index: _index,
            children: const [
              TableEditorScreen(),
              SettingsScreen(),
              OfflineAutotunePane(),
            ],
          ),
        ),
        NavigationBar(
          selectedIndex: _index,
          height: 60,
          onDestinationSelected: (i) => setState(() => _index = i),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.grid_on_outlined),
              selectedIcon: Icon(Icons.grid_on),
              label: 'Таблицы',
            ),
            NavigationDestination(
              icon: Icon(Icons.tune_outlined),
              selectedIcon: Icon(Icons.tune),
              label: 'Настройки',
            ),
            NavigationDestination(
              icon: Icon(Icons.auto_graph_outlined),
              selectedIcon: Icon(Icons.auto_graph),
              label: 'Автонастройка',
            ),
          ],
        ),
      ],
    );
  }
}
