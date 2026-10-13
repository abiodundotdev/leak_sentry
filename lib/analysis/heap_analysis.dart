import 'package:leak_sentry/core/heap_dumper.dart';
import 'package:leak_sentry/models/leak_report.dart';

/// The steps of an analysis, reported through `HeapAnalysisProgressEvent`.
///
/// Only `findingRetainedObjects`, `findingPathsToRetainedObjects`,
/// `buildingLeakTraces` and `reportingHeapAnalysis` are reported: the analysis
/// works from the retained set and the VM's retaining paths, so the steps that
/// would parse a heap file or measure retained sizes never happen. Every value
/// takes its share of [progressPercent] all the same.
enum AnalysisStep {
  parsingHeapDump('Parsing heap dump'),
  extractingMetadata('Extracting metadata'),
  findingRetainedObjects('Finding retained objects'),
  findingPathsToRetainedObjects('Finding paths to retained objects'),
  findingDominators('Finding dominators'),
  inspectingObjects('Inspecting objects'),
  computingNativeRetainedSize('Computing native retained size'),
  computingRetainedSize('Computing retained size'),
  buildingLeakTraces('Building leak traces'),
  reportingHeapAnalysis('Reporting heap analysis');

  const AnalysisStep(this.humanReadableName);

  final String humanReadableName;

  /// How far along the analysis is when this step starts, from 0 to 1.
  double get progressPercent => index / AnalysisStep.values.length;
}

/// The outcome of analysing a [RetainedObjectsDump].
sealed class HeapAnalysis {
  const HeapAnalysis({required this.dump, required this.analysisDuration});

  final RetainedObjectsDump dump;
  final Duration analysisDuration;
}

class HeapAnalysisSuccess extends HeapAnalysis {
  const HeapAnalysisSuccess({
    required super.dump,
    required super.analysisDuration,
    required this.leaks,
    this.unreachableObjectCount = 0,
    this.metadata = const {},
  });

  /// One report per distinct leak found in the dump.
  final List<LeakReport> leaks;

  /// How many retained objects nothing retained anymore by the time the
  /// analysis looked: garbage the VM hadn't collected yet, or objects released
  /// since the dump. They are not leaks.
  final int unreachableObjectCount;

  /// Facts about the app and platform at analysis time.
  final Map<String, String> metadata;

  @override
  String toString() {
    final buffer = StringBuffer()
      ..writeln('====================================')
      ..writeln('HEAP ANALYSIS RESULT')
      ..writeln('====================================')
      ..writeln('${leaks.length} APPLICATION ${leaks.length == 1 ? 'LEAK' : 'LEAKS'}');
    for (final leak in leaks) {
      buffer
        ..writeln()
        ..writeln(leak);
    }
    buffer
      ..writeln('====================================')
      ..writeln('$unreachableObjectCount UNREACHABLE ${unreachableObjectCount == 1 ? 'OBJECT' : 'OBJECTS'}')
      ..writeln()
      ..writeln('An unreachable object is still in memory but LeakSentry could not find a strong reference path')
      ..writeln('from GC roots.');
    if (metadata.isNotEmpty) {
      buffer
        ..writeln('====================================')
        ..writeln('METADATA')
        ..writeln()
        ..writeln('Please include this in bug reports and Stack Overflow questions.');
      metadata.forEach((key, value) => buffer.writeln('$key: $value'));
    }
    buffer
      ..writeln('Analysis duration: ${analysisDuration.inMilliseconds} ms')
      ..write('====================================');
    return buffer.toString();
  }
}

class HeapAnalysisFailure extends HeapAnalysis {
  const HeapAnalysisFailure({
    required super.dump,
    required super.analysisDuration,
    required this.exception,
    this.stackTrace,
  });

  final Object exception;
  final StackTrace? stackTrace;

  @override
  String toString() =>
      '====================================\n'
      'HEAP ANALYSIS FAILED\n'
      '====================================\n'
      '$exception';
}
