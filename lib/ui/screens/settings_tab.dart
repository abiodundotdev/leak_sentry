import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:leak_sentry/core/heap_dump_control.dart';
import 'package:leak_sentry/core/internal_leak_sentry.dart';
import 'package:leak_sentry/models/leak_sentry_internal.dart';
import 'package:leak_sentry/ui/copy.dart';
import 'package:leak_sentry/ui/skin.dart';
import 'package:leak_sentry/ui/tokens.dart';
import 'package:leak_sentry/ui/widgets/page_column.dart';
import 'package:leak_sentry/ui/widgets/section_card.dart';

/// The switches, what LeakSentry can and cannot do right now, and where to clear
/// everything.
class SettingsTab extends StatefulWidget {
  const SettingsTab({super.key, required this.engine});

  final InternalLeakSentry engine;

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> implements LeakSentryInternal {
  // The switch and the config say nothing when they change, so what is written
  // here is shown by building again.
  static const int _minThreshold = 1;
  static const int _maxThreshold = 50;

  late final Future<bool> _vmReachable = widget.engine.vmServiceReachable();

  InternalLeakSentry get _engine => widget.engine;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    final threshold = _engine.config.retainedVisibleThreshold;
    final permission = _engine.heapDumpPermission;
    return ListView(
      primary: false,
      padding: EdgeInsets.only(bottom: bottom + 16),
      children: [
        PageColumn(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(LeakSentryMetrics.pagePadding, 4, LeakSentryMetrics.pagePadding, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SectionCard(
                  title: LeakSentryCopy.settingsScansSection,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text(LeakSentryCopy.settingsScanAutomatically),
                        subtitle: const Text(
                          LeakSentryCopy.settingsScanAutomaticallyHint,
                          style: TextStyle(fontSize: 13, height: 1.35, color: LeakSentryColors.muted),
                        ),
                        value: _engine.dumpEnabledInAboutScreen,
                        onChanged: (value) => setState(() => _engine.dumpEnabledInAboutScreen = value),
                      ),
                      const Divider(height: 24),
                      Row(
                        children: [
                          const Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(LeakSentryCopy.settingsThreshold, style: TextStyle(fontSize: 16, color: LeakSentryColors.text)),
                                SizedBox(height: 2),
                                Text(
                                  LeakSentryCopy.settingsThresholdHint,
                                  style: TextStyle(fontSize: 13, height: 1.35, color: LeakSentryColors.muted),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: LeakSentryCopy.settingsThresholdLess,
                            onPressed: threshold > _minThreshold ? () => _nudgeThreshold(-1) : null,
                            icon: const Icon(Icons.remove_circle_outline),
                          ),
                          Text('$threshold', style: LeakSentryText.mono(size: 16, weight: FontWeight.w700)),
                          IconButton(
                            tooltip: LeakSentryCopy.settingsThresholdMore,
                            onPressed: threshold < _maxThreshold ? () => _nudgeThreshold(1) : null,
                            icon: const Icon(Icons.add_circle_outline),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                SectionCard(
                  title: LeakSentryCopy.settingsStatus,
                  child: Column(
                    children: [
                      FutureBuilder<bool>(
                        future: _vmReachable,
                        builder: (context, snapshot) => _StatusRow(
                          label: LeakSentryCopy.settingsVmReachable,
                          value: !snapshot.hasData
                              ? '…'
                              : (snapshot.data! ? LeakSentryCopy.settingsVmYes : LeakSentryCopy.settingsVmNo),
                          warn: snapshot.hasData && !snapshot.data!,
                        ),
                      ),
                      _StatusRow(
                        label: LeakSentryCopy.settingsScanning,
                        value: permission is Nope ? LeakSentryCopy.blockShort(permission.block) : LeakSentryCopy.settingsScanningOn,
                        warn: permission is Nope,
                      ),
                      const _StatusRow(
                        label: LeakSentryCopy.settingsBuildMode,
                        value: kReleaseMode
                            ? LeakSentryCopy.settingsBuildRelease
                            : (kProfileMode ? LeakSentryCopy.settingsBuildProfile : LeakSentryCopy.settingsBuildDebug),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                SectionCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _confirmClear,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: LeakSentryColors.dangerText,
                          side: const BorderSide(color: LeakSentryColors.dangerLine),
                        ),
                        icon: const Icon(Icons.delete_outline, size: 18),
                        label: const Text(LeakSentryCopy.settingsClear),
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        LeakSentryCopy.thisSession,
                        style: TextStyle(fontSize: 12, color: LeakSentryColors.dim),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // Reads the config as it is when the button is pressed, not as it was when the
  // button was built, so two quick presses count twice.
  void _nudgeThreshold(int step) {
    final value = (_engine.config.retainedVisibleThreshold + step).clamp(_minThreshold, _maxThreshold);
    setState(() => _engine.config = _engine.config.copyWith(retainedVisibleThreshold: value));
  }

  Future<void> _confirmClear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => LeakSentrySkin(
        child: AlertDialog(
          backgroundColor: LeakSentryColors.surfaceHigh,
          title: const Text(LeakSentryCopy.settingsClearConfirmTitle),
          content: const Text(LeakSentryCopy.settingsClearConfirmBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text(LeakSentryCopy.settingsClearCancel),
            ),
            // It cannot be undone, so it is not the colour of what is good to press.
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: LeakSentryColors.danger,
                foregroundColor: LeakSentryColors.onAccent,
              ),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text(LeakSentryCopy.settingsClearConfirm),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    _engine.clearLeaks();
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text(LeakSentryCopy.settingsCleared)));
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.label, required this.value, this.warn = false});

  final String label;
  final String value;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(child: Text(label, style: const TextStyle(fontSize: 14, color: LeakSentryColors.muted))),
          const SizedBox(width: 12),
          // The value gives way before the label does, and wraps instead of running off the edge.
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: warn ? LeakSentryColors.caution : LeakSentryColors.text,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
