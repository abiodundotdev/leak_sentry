import 'package:leak_sentry/analysis/heap_analysis.dart';
import 'package:leak_sentry/core/heap_dump_control.dart';
import 'package:leak_sentry/models/creation_site.dart';
import 'package:leak_sentry/models/leak_report.dart';
import 'package:leak_sentry/ui/format.dart';

/// Every sentence the LeakSentry screens say, in one place.
///
/// The wording is LeakSentry's own: `test/ui/copy_test.dart` fails if a string in
/// `lib/ui` uses a phrase from its `banned` list.
abstract final class LeakSentryCopy {
  // Tabs.
  static const String tabLeaks = 'Leaks';
  static const String tabScans = 'Scans';
  static const String tabSettings = 'Settings';

  // The badge.
  static String badgeLeaks(int leaks) => countOf(leaks, 'leak');
  static const String badgeOpenHint = 'Open LeakSentry';
  static String noticeHeld(int held, int threshold) => '$held held · scans at $threshold';
  static String noticeRecent(int held) => '$held held · scanned moments ago';
  static String noticeSwitchedOff(int held) => '$held held · scanning is off';
  static String noticeFailed(int held) => '$held held · last scan failed';
  static const String noticeAllClear = 'All clear';

  // The screens' titles.
  static const String leakTitle = 'Leak';
  static const String scanTitle = 'Scan';
  static const String leakCleared = 'This leak was cleared';
  static const String leakClearedBody = 'It is no longer in the list, so there is nothing more to show.';
  static const String scanGone = 'This scan is no longer listed';
  static const String scanGoneBody = 'LeakSentry keeps the latest scans only.';

  // The leaks list.
  static String leaksSummary(int leaks, int objects) => '${countOf(leaks, 'leak')} spotted · ${countOf(objects, 'object')}';
  static const String leaksEmptyTitle = 'No leaks so far';
  static const String leaksEmptyBody =
      'LeakSentry watches States, Routes, ChangeNotifiers and AnimationControllers. When one is disposed and '
      'something still holds on to it, it shows up here.';
  static String holds(String type) => 'Holds $type';
  static String seenAgo(String ago) => 'seen $ago';
  static String otherPlaces(int count) => '+$count more';
  static const String tagNew = 'NEW';
  static const String tagResource = 'Resource';
  static const String tagInternal = 'Held by LeakSentry';
  static const String resourceNeverClosed = 'Collected without being closed';

  // A leak.
  static String instances(int count) => countOf(count, 'instance');
  static String lastSeen(String ago) => 'last seen $ago';
  static String firstSeen(String ago) => 'first seen $ago';
  static String seen(String ago) => 'seen $ago';
  static String instanceNumber(int number, int total) => 'Instance $number of $total';
  static String objectsFound(int count) => countOf(count, 'object');

  // Where it was created.
  static const String whereCreated = 'Where it was created';
  static const String createdAt = 'Created at';
  static const String watchedAt = 'Watched at';
  static const String classDeclaredAt = 'Class declared at';
  static const String acquiredAt = 'Acquired at';
  static const String tapToCopy = 'Tap to copy';
  static const String locationCopied = 'Location copied';

  /// Says, in a sentence, why no creation site is known.
  static String creationGap(CreationSiteGap gap) => switch (gap) {
    CreationSiteGap.notDebugBuild => 'Flutter only reports where objects are created in debug builds.',
    CreationSiteGap.web => 'On the web, stack traces do not point at lines of Dart code.',
    CreationSiteGap.notAnnounced =>
      'Flutter never reported this object being created. It may have been created before LeakSentry started, '
          'or its class does not report its creation.',
    CreationSiteGap.onlyFrameworkFrames =>
      'None of your code was running when Flutter reported this object. A State with no initState of its own '
          'looks like this.',
    CreationSiteGap.symbolless =>
      'This build was made with --split-debug-info, so its stack traces carry no file names.',
    CreationSiteGap.unparseable => 'The stack trace recorded for this object could not be read.',
  };

  static const String creationUnknown = 'Creation site not recorded';
  static const String creationUnknownNoReason = 'LeakSentry has no record of where this object was created.';

  // The path from something that lives as long as the app to the leaked object.
  static const String pathTitle = 'What is holding it';
  static const String copyReport = 'Copy report';
  static const String printReport = 'Print to console';
  static const String reportCopied = 'Report copied';
  static const String reportPrinted = 'Report printed to the console';
  static const String pathHint =
      'The path starts at something that lives as long as the app and ends at the object that should be gone. '
      'Start with the reference marked "start here". In use means meant to stay alive; unclear means LeakSentry cannot tell.';
  static const String statusInUse = 'In use';
  static const String statusShouldBeGone = 'Should be gone';
  static const String statusUnclear = 'Unclear';
  static String moreSteps(int steps) => '${countOf(steps, 'more step')} to the root';
  static const String likelyCause = 'likely cause';
  static const String startHere = 'start here';
  static String pathOfLatest(int instances) => 'Showing the path of the instance seen last, one of $instances.';

  /// What a path starts at, from the kind of root the VM reports.
  static String startsAt(String gcRootType) => 'Starts at: ${_root(gcRootType)}';

  static String _root(String gcRootType) => switch (gcRootType) {
    'user global' => 'a static variable',
    'class table' => 'a class',
    'stack' => 'a running function',
    'isolate_object store' => 'an object the runtime keeps',
    'local handle' || 'persistent handle' || 'weak persistent handle' => 'a native handle',
    _ => 'something the app keeps alive',
  };

  /// Says, in a sentence, why a leak has no path.
  static String pathGap(RetainingPathGap gap) => switch (gap) {
    RetainingPathGap.disabled => 'Tracing paths is turned off in the LeakSentry config.',
    RetainingPathGap.noVmService => 'There is no VM service to ask, so the path cannot be traced.',
    RetainingPathGap.lookupLimitReached => 'This scan already traced as many paths as it is allowed to.',
    RetainingPathGap.objectUnavailable =>
      'The VM had no handle for this object. It may have been collected since the scan started.',
    RetainingPathGap.lookupFailed => 'The VM service could not be reached, or did not answer.',
  };

  static const String pathUnknown = 'No path was traced for this leak.';

  // Resource leaks.
  static const String resourceExplanation =
      'This resource was garbage collected without being closed. Nothing holds it any more, so there is no path to show: '
      'look at where it was acquired.';

  // The scans.
  static const String scansEmptyTitle = 'No scans yet';
  static const String scansEmptyBody =
      'LeakSentry scans when enough disposed objects are still held, or when you ask it to. Each scan is listed here.';
  static const String scanNow = 'Scan now';
  static const String scanRunning = 'Scanning…';
  static String scanProgress(String step, int percent) => '$step · $percent%';
  static String scanSummary(int held, int leaks, int newLeaks) {
    final found = leaks == 0 ? 'no leaks' : countOf(leaks, 'leak');
    final fresh = newLeaks == 0 ? '' : ' ($newLeaks new)';
    return '$held held · $found$fresh';
  }

  static const String scanFailed = 'Scan failed';
  static const String scanFailedWillRetry = 'Scan failed · trying again soon';
  static String scanReleased(int released) => '${countOf(released, 'object')} released before the scan looked';
  static String scanTook(String duration) => 'took $duration';
  static String scanReason(String reason) => 'Started because of: $reason';
  static const String scanFoundNothing = 'Nothing was left holding on.';
  static const String scanStatusIdle = 'Nothing is being held';
  static const String scanStatusIdleBody = 'LeakSentry is watching. A scan starts when enough disposed objects stay alive.';
  static String scanStatusHeld(int held) => '${countOf(held, 'object')} held';
  static String scanStatusWaiting(int threshold) =>
      'LeakSentry scans when $threshold are held while you use the app, or as soon as you leave it.';
  static const String scanStatusRecent = 'The last scan was moments ago, so the next one waits a little.';
  static const String scanStatusFailed = 'The last scan failed. LeakSentry tries again soon.';
  static const String scanStatusAllClear = 'All clear';
  static const String scanStatusAllClearBody = 'Everything that was held has been collected.';
  static const String nothingHeldOnRequest = 'Nothing is being held, so there was nothing to scan.';
  static const String scanStatusCapturing = 'Capturing what is held';
  static String scanDetailHeld(int held) => 'Held when the scan started: $held';
  static const String scanDetailLeaks = 'Leaks it found';
  static const String scanDetailNoLeaks = 'It found no leaks.';

  /// What an analysis step is, in a few plain words.
  static String analysisStep(AnalysisStep step) => switch (step) {
    AnalysisStep.findingRetainedObjects => 'Collecting what is held',
    AnalysisStep.findingPathsToRetainedObjects => 'Tracing what holds it',
    AnalysisStep.buildingLeakTraces => 'Building the report',
    AnalysisStep.reportingHeapAnalysis => 'Wrapping up',
    _ => 'Working',
  };

  /// Says, in a sentence, what keeps LeakSentry from scanning by itself.
  static String blockSentence(HeapDumpBlock block) => switch (block) {
    HeapDumpBlock.notInstalled => 'LeakSentry is not installed, so nothing is being watched.',
    HeapDumpBlock.switchedOffInSettings =>
      'Automatic scanning is switched off in Settings. Scan now still scans by hand.',
    HeapDumpBlock.disabledByConfig =>
      'The app turned scanning off in its LeakSentry config (dumpHeap: false). Scan now still scans by hand.',
    HeapDumpBlock.runningTests => 'Scanning is off while tests run.',
  };
  static String blockShort(HeapDumpBlock block) => switch (block) {
    HeapDumpBlock.notInstalled => 'Not installed',
    HeapDumpBlock.switchedOffInSettings => 'Switched off',
    HeapDumpBlock.disabledByConfig => 'Off in the config',
    HeapDumpBlock.runningTests => 'Off in tests',
  };

  // Settings.
  static const String settingsScansSection = 'Automatic scanning';
  static const String settingsScanAutomatically = 'Scan automatically';
  static const String settingsScanAutomaticallyHint =
      'When off, LeakSentry only scans when you tap Scan now.';
  static const String settingsThreshold = 'Objects held before scanning';
  static const String settingsThresholdLess = 'Wait for one object fewer';
  static const String settingsThresholdMore = 'Wait for one object more';
  static const String settingsThresholdHint =
      'While you use the app, LeakSentry waits until this many objects are held. Leaving the app scans at once.';
  static const String settingsClear = 'Clear leaks and scans';
  static const String settingsClearConfirmTitle = 'Clear leaks and scans?';
  static const String settingsClearConfirmBody = 'This forgets every leak and scan LeakSentry has listed this session.';
  static const String settingsClearConfirm = 'Clear';
  static const String settingsClearCancel = 'Keep them';
  static const String settingsCleared = 'Leaks cleared';
  static const String settingsStatus = 'Status';
  static const String settingsVmReachable = 'VM service';
  static const String settingsVmYes = 'Reachable';
  static const String settingsVmNo = 'Not reachable';
  static const String settingsBuildMode = 'Build';
  static const String settingsScanning = 'Scanning';
  static const String settingsScanningOn = 'On';
  static const String settingsBuildDebug = 'Debug';
  static const String settingsBuildProfile = 'Profile';
  static const String settingsBuildRelease = 'Release';
  static const String thisSession = 'Everything here is kept for this session only.';

  // The report, as text.
  static const String reportHeading = 'LeakSentry report';
  static String reportInstance(int number, int total, String type, int objects) =>
      'Instance $number of $total · $type · ${countOf(objects, 'object')}';
  static String reportCreationUnknown(String reason) => '$creationUnknown: $reason';
  static const String reportPath = 'Path (from the root to the leaked object)';
  static String reportPathUnknown(String reason) => 'Path not traced: $reason';
  static const String reportLeakedObject = 'the leaked object';
  static const String reportAcquisitionStack = 'Stack when it was acquired';
  static const String reportLikelyCause = 'likely cause';
  static String writtenAt(String location) => 'written at $location';
}
