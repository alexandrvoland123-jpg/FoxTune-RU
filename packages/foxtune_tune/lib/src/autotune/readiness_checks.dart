/// Reasons a tune must not be autotuned that no filter can catch sample by
/// sample: they are about how the ECU is set up, not what the engine is doing.
///
/// Where a check needs firmware knowledge the definition does not spell out,
/// it is keyed on the setting's name - Speeduino's `egoType`, rusEFI's
/// `afr_*` - so a definition without that setting is simply not checked for
/// it, and one that has it is checked whichever firmware it came from.
library;

import 'package:foxtune_ini/foxtune_ini.dart';

import '../setting_view.dart';
import '../table_view.dart';
import '../tune_state.dart';
import '../value_resolver.dart';

/// The first reason [config] must not be autotuned on [tune], or `null`.
String? autotuneSetupProblem({
  required TuneState tune,
  required TuneValueResolver resolver,
  required IniVeAnalyze config,
  required TableView table,
  required TableView target,
}) =>
    _unreadableFilter(config) ??
    _sensorProblem(tune, resolver) ??
    _displayUnitAxes(tune, resolver, [table, target]) ??
    _longTermTrims(tune, resolver);

/// Refuses a filter that was declared but could not be read.
///
/// One without an operator or a threshold never rejects anything, so running
/// with it would quietly drop a guard the definition asked for.
String? _unreadableFilter(IniVeAnalyze config) {
  for (final filter in config.channelFilters) {
    if (filter.channel.isEmpty ||
        filter.operator == null ||
        filter.value == null) {
      return 'Фильтр «${filter.displayLabel}» ("${filter.displayLabel}") из определения не удалось прочитать, поэтому он никогда не отклонял бы отсчёты. Автонастройка остаётся выключенной, а не работает без него.'
          ''
          '';
    }
  }
  return null;
}

/// Refuses a sensor that cannot measure how far off target the mixture is.
///
/// A narrowband reports only rich or lean of stoichiometric, but the ECU still
/// publishes it on the same channel as a wideband. Tuning on it would produce
/// a table that is confidently wrong everywhere the engine is not meant to run
/// at stoich - which is everywhere that matters.
String? _sensorProblem(TuneState tune, TuneValueResolver resolver) {
  SettingView? setting(String name) =>
      SettingView.of(tune, name, resolver: resolver);

  // Speeduino says which kind of sensor it has.
  final egoType = setting('egoType');
  if (egoType != null && egoType.isEnumerated) {
    final label = egoType.optionLabel;
    if (label == null || label.toLowerCase().contains('wide')) return null;
    return 'Датчик O2 установлен как «$label». Для автонастройки нужен широкополосный (wideband): узкополосный (narrowband) сообщает только «богаче или беднее» стехиометрии, поэтому по его показаниям нельзя сказать, насколько смесь отличается от цели.'
        ''
        '';
  }

  // rusEFI does not: "Narrow Band" is one of its presets for the analog
  // input's calibration, not a type. A CAN wideband bypasses that input.
  final canWideband = setting('enableAemXSeries');
  if (canWideband?.optionLabel == 'yes') return null;

  final input = setting('afr_hwChannel');
  final v1 = setting('afr_v1')?.value;
  final afr1 = setting('afr_value1')?.value;
  final v2 = setting('afr_v2')?.value;
  final afr2 = setting('afr_value2')?.value;
  if (input == null ||
      v1 == null ||
      afr1 == null ||
      v2 == null ||
      afr2 == null) {
    // A definition that does not describe the sensor cannot be checked, and
    // refusing on that basis would block firmware this simply knows less
    // about.
    return null;
  }

  if (input.optionLabel?.toUpperCase() == 'NONE') {
    return 'Не настроен вход датчика O2 - ни широкополосный по CAN, ни аналоговый - поэтому нет показания смеси для настройки. (No O2 sensor input)'
        '';
  }

  if ((v2 - v1).abs() < 1e-3) {
    return 'Калибровка датчика O2 даёт одно и то же напряжение для обеих точек, поэтому её нельзя прочитать.'
        '';
  }

  // Every wideband controller's output rises with AFR, by two or three AFR a
  // volt across 0-5 V. The Narrow Band preset falls - 15 at 0.1 V, 14 at
  // 0.9 V - because a narrowband's voltage rises as the mixture goes rich.
  final slope = (afr2 - afr1) / (v2 - v1);
  final points = '${_n(afr1)} AFR при ${_n(v1)} В, ${_n(afr2)} AFR при ${_n(v2)} В'
      '';
  if (slope <= 0) {
    return 'Датчик O2 откалиброван как узкополосный (narrowband, $points). Для автонастройки нужен широкополосный (wideband): узкополосный сообщает только «богаче или беднее» стехиометрии, поэтому по его показаниям нельзя сказать, насколько смесь отличается от цели.'
        ''
        ''
        '';
  }
  if (slope < 1) {
    return 'Калибровка датчика O2 ($points) охватывает слишком малый диапазон для широкополосного. Перед автонастройкой убедитесь, что она совпадает с контроллером.'
        '';
  }
  return null;
}

/// Refuses a load axis shown in different units from its live reading.
///
/// rusEFI shows MAP bins in psi when its display is set to Imperial, while
/// the channel that says where the engine is on the axis stays in kPa. Every
/// reading would then be credited to cells far from where the engine was.
/// Detected from the definition rather than assumed: an axis whose scale
/// depends on `useMetricOnInterface`, and differs between its settings.
String? _displayUnitAxes(
  TuneState tune,
  TuneValueResolver resolver,
  List<TableView> tables,
) {
  const switchName = 'useMetricOnInterface';
  final located = tune.locate(switchName);
  final field = located?.field;
  if (field is! IniBitsField) return null;
  final metric = field.options.indexOf('Metric');
  if (metric < 0) return null;

  double? metricResolve(String name) =>
      name == switchName ? metric.toDouble() : resolver.resolve(name);

  for (final view in tables) {
    for (final axis in [view.xField, view.yField]) {
      for (final value in [axis.scale, axis.translate]) {
        if (value is! IniExpression) continue;
        final compiled = CompiledExpression.tryCompile(value.source);
        if (compiled == null || !compiled.references.contains(switchName)) {
          continue;
        }
        final shown = compiled.evaluate(resolver.resolve);
        final inMetric = compiled.evaluate(metricResolve);
        if (shown != inMetric) {
          final label = _dialogLabel(tune.definition, switchName);
          return 'Ось таблицы «${view.table.title}» показана в имперских единицах (Imperial), тогда как ЭБУ сообщает положение двигателя на ней в метрических, поэтому показания были бы отнесены не к тем ячейкам. Для автонастройки задайте «$label» в значение Metric.'
              ''
              ''
              '';
        }
      }
    }
  }
  return null;
}

/// Refuses while long-term fuel trims are applied on top of the VE table.
///
/// The closed-loop trim autotuning reads does not include them, so the VE
/// table would be tuned to absorb them - and be wrong by that much, most
/// likely lean, as soon as they are reset.
String? _longTermTrims(TuneState tune, TuneValueResolver resolver) {
  const name = 'ltft_correctionEnabled';
  final ltft = SettingView.of(tune, name, resolver: resolver);
  if (ltft?.optionLabel != 'yes') return null;
  return 'Долговременные топливные коррекции накладываются поверх таблицы VE, и автонастройка их не видит. Выключите «${_dialogLabel(tune.definition, name)}» ("Apply Correction"), чтобы выполнить автонастройку.'
      ''
      '';
}

/// What the definition's settings screens call [constant].
String _dialogLabel(IniDocument definition, String constant) {
  for (final dialog in definition.dialogs) {
    for (final item in dialog.items) {
      if (item is IniDialogField &&
          item.constant == constant &&
          item.label.trim().isNotEmpty) {
        return item.label.trim();
      }
    }
  }
  return constant;
}

String _n(double value) =>
    value.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');
