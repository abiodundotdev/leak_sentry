import 'package:flutter/material.dart';
import 'package:leak_sentry/analysis/node_status.dart';
import 'package:leak_sentry/ui/copy.dart';
import 'package:leak_sentry/ui/format.dart';
import 'package:leak_sentry/ui/tokens.dart';
import 'package:leak_sentry/ui/widgets/status_pill.dart';

/// How a step holds the next one: `.pages`, `[x]`, `{key}`.
class TimelineReference {
  const TimelineReference(this.text, {this.isSuspect = false, this.isFirstSuspect = false});

  final String text;

  /// Whether this is one of the likeliest causes of the leak.
  final bool isSuspect;

  /// Whether this is the first of them, the one to start with.
  final bool isFirstSuspect;
}

/// One step of the path from something that lives as long as the app to the
/// leaked object.
class TimelineStep {
  const TimelineStep({required this.title, this.detail, this.status, this.note, this.reference});

  /// The class, closure or variable, as a developer writes it.
  final String title;

  /// Where it comes from (its library), dim.
  final String? detail;

  final NodeStatus? status;

  /// Why LeakSentry thinks what it thinks of this step.
  final String? note;

  /// How this step holds the next one. Null on the last step.
  final TimelineReference? reference;
}

/// The path to a leaked object, drawn as a vertical timeline: a numbered dot for
/// each step on a rail, a status pill beside it, and the reference to the next
/// step below it. A span of the rail that holds a likely cause is drawn
/// thicker, in coral, instead of plain.
class TraceTimeline extends StatelessWidget {
  const TraceTimeline({super.key, required this.steps, this.startsAt, this.hiddenSteps = 0});

  final List<TimelineStep> steps;

  /// What the path starts at: "Starts at: a static variable".
  final String? startsAt;

  /// How many steps the VM left out between the first one and the root.
  final int hiddenSteps;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (hiddenSteps > 0) _Hint(LeakSentryCopy.moreSteps(hiddenSteps)),
        if (startsAt != null) _Hint(startsAt!),
        for (var i = 0; i < steps.length; i++)
          _StepRow(
            step: steps[i],
            number: i + 1,
            total: steps.length,
            above: i == 0 ? null : _railOf(steps[i - 1].reference),
            below: i == steps.length - 1 ? null : _railOf(steps[i].reference),
          ),
      ],
    );
  }

  static RailStyle _railOf(TimelineReference? reference) =>
      reference != null && reference.isSuspect ? RailStyle.suspect : RailStyle.plain;
}

/// How a piece of the rail is drawn.
@visibleForTesting
enum RailStyle { plain, suspect }

class _Hint extends StatelessWidget {
  const _Hint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(text, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: LeakSentryColors.muted)),
    );
  }
}

const double _railWidth = 40;
const double _dotSize = 28;
const double _dotTop = 2;

class _StepRow extends StatelessWidget {
  const _StepRow({required this.step, required this.number, required this.total, this.above, this.below});

  final TimelineStep step;
  final int number;
  final int total;
  final RailStyle? above;
  final RailStyle? below;

  @override
  Widget build(BuildContext context) {
    final reference = step.reference;
    return Semantics(
      container: true,
      label: 'Step $number of $total',
      child: Stack(
        children: [
          Positioned.fill(
            child: ExcludeSemantics(
              child: CustomPaint(painter: RailPainter(above: above, below: below)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: _railWidth, bottom: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: _dotSize + _dotTop),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(breakable(step.title, after: '.'), style: LeakSentryText.mono(size: 14, weight: FontWeight.w700)),
                        if (step.status != null) StatusPill(step.status!),
                      ],
                    ),
                  ),
                ),
                if (step.detail != null)
                  Text(breakable(step.detail!, after: '/:'), style: LeakSentryText.mono(size: 11, color: LeakSentryColors.muted)),
                if (step.note != null) ...[
                  const SizedBox(height: 4),
                  Text(step.note!, style: const TextStyle(fontSize: 13, height: 1.35, color: LeakSentryColors.muted)),
                ],
                if (reference != null) ...[const SizedBox(height: 10), _ReferenceLine(reference)],
              ],
            ),
          ),
          Positioned(
            left: (_railWidth - _dotSize) / 2,
            top: _dotTop,
            child: _Dot(number: number, status: step.status),
          ),
        ],
      ),
    );
  }
}

class _ReferenceLine extends StatelessWidget {
  const _ReferenceLine(this.reference);

  final TimelineReference reference;

  @override
  Widget build(BuildContext context) {
    if (!reference.isSuspect) {
      return Text(reference.text, style: LeakSentryText.mono(size: 13, color: LeakSentryColors.muted));
    }
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            color: LeakSentryColors.dangerDeep,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: LeakSentryColors.dangerLine),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            child: Text(
              reference.text,
              style: LeakSentryText.mono(size: 13, color: LeakSentryColors.dangerText, weight: FontWeight.w700),
            ),
          ),
        ),
        reference.isFirstSuspect
            ? const Text(
                LeakSentryCopy.startHere,
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: LeakSentryColors.accent),
              )
            : const Text(LeakSentryCopy.likelyCause, style: TextStyle(fontSize: 11, color: LeakSentryColors.dim)),
      ],
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.number, required this.status});

  final int number;
  final NodeStatus? status;

  @override
  Widget build(BuildContext context) {
    final (border, fill, text) = switch (status) {
      NodeStatus.inUse => (LeakSentryColors.inUse, LeakSentryColors.inUseDeep, LeakSentryColors.inUse),
      NodeStatus.shouldBeGone => (LeakSentryColors.danger, LeakSentryColors.dangerDeep, LeakSentryColors.dangerText),
      NodeStatus.unclear => (LeakSentryColors.caution, LeakSentryColors.cautionDeep, LeakSentryColors.caution),
      null => (LeakSentryColors.outline, LeakSentryColors.surfaceHigh, LeakSentryColors.muted),
    };
    return Container(
      width: _dotSize,
      height: _dotSize,
      alignment: Alignment.center,
      decoration: BoxDecoration(shape: BoxShape.circle, color: fill, border: Border.all(color: border, width: 2)),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text('$number', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: text)),
      ),
    );
  }
}

/// Draws the rail through one step: the piece above its dot and the piece below
/// it. A plain piece is a thin slate line. A piece that holds a likely cause is a
/// solid coral rail, thicker, on a band of a darker coral.
@visibleForTesting
class RailPainter extends CustomPainter {
  const RailPainter({required this.above, required this.below});

  final RailStyle? above;
  final RailStyle? below;

  @override
  void paint(Canvas canvas, Size size) {
    final above = this.above;
    if (above != null) _piece(canvas, above, 0, _dotTop);
    final below = this.below;
    if (below != null) _piece(canvas, below, _dotTop + _dotSize, size.height);
  }

  void _piece(Canvas canvas, RailStyle rail, double from, double to) {
    const x = _railWidth / 2;
    if (to <= from) return;
    switch (rail) {
      case RailStyle.plain:
        canvas.drawLine(
          Offset(x, from),
          Offset(x, to),
          Paint()
            ..color = LeakSentryColors.outline
            ..strokeWidth = 2,
        );
      case RailStyle.suspect:
        canvas.drawRRect(
          RRect.fromLTRBR(x - 4, from, x + 4, to, const Radius.circular(4)),
          Paint()..color = LeakSentryColors.dangerDeep,
        );
        canvas.drawRRect(
          RRect.fromLTRBR(x - 1.75, from, x + 1.75, to, const Radius.circular(1.75)),
          Paint()..color = LeakSentryColors.danger,
        );
    }
  }

  @override
  bool shouldRepaint(RailPainter old) => old.above != above || old.below != below;
}
