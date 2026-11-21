import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../dashboard/appearance_editor.dart';
import '../dashboard/dashboard_editor.dart' show confirm;
import '../dashboard/gauge_appearance.dart';
import '../window/window_app_bar.dart';
import 'app_settings.dart';

/// Where the default look of the dashboard's gauges is chosen: what every
/// gauge follows, in whatever it has not been given a look of its own.
///
/// Every change shows at once on the samples, and is saved as it is made.
class GaugeAppearanceScreen extends ConsumerWidget {
  const GaugeAppearanceScreen({super.key});

  /// Opens it over [context].
  static Future<void> open(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => const GaugeAppearanceScreen()),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final look = ref.watch(
      appSettingsProvider.select((s) => s.gaugeAppearance),
    );
    void update(GaugeAppearance next) => ref
        .read(appSettingsProvider.notifier)
        .update((s) => s.copyWith(gaugeAppearance: next));

    return Scaffold(
      appBar: const WindowAppBar(title: Text('Вид приборов')),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              children: [
                Text(
                  "Как выглядят приборы панели. Любому прибору можно задать собственный вид в его параметрах при редактировании панели; всё, что оставлено «По умолчанию», следует этому."
                  ''
                  '',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                GaugePreview(kinds: allGaugeKinds, look: look),
                GaugeAppearanceEditor(
                  value: look,
                  kinds: allGaugeKinds,
                  onChanged: update,
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton(
                    onPressed: look.isEmpty
                        ? null
                        : () async {
                            if (await confirm(
                              context,
                              title: 'Вернуть встроенный вид?',
                              message:
                                  'Все настройки здесь возвращаются к тому, как FoxTune рисует приборы по умолчанию. Приборы с собственным видом сохраняют его.'
                                  ''
                                  '',
                              action: 'Сбросить',
                            )) {
                              update(const GaugeAppearance());
                            }
                          },
                    child: const Text('Вернуть встроенное'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
