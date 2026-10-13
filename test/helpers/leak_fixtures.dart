import 'package:leak_sentry/analysis/leak_trace.dart';
import 'package:leak_sentry/analysis/node_status.dart';
import 'package:leak_sentry/core/leak_catalog.dart';
import 'package:leak_sentry/models/creation_site.dart';

/// Where the leaks of the screen tests were "created".
const CreationSite initStateSite = CreationSite(
  uri: 'package:leak_entry_app/main.dart',
  member: '_PageThreeState.initState',
  line: 196,
  column: 11,
);

DateTime at(int minute) => DateTime(2026, 10, 12, 12, minute);

LeakInstance leakInstance({
  String signature = 'signature',
  String type = '_PageThreeState',
  int count = 1,
  int minute = 0,
  CreationSite? created = initStateSite,
  CreationSite? watched,
  CreationSite? declared,
  CreationSiteGap? gap,
  LeakTrace? trace,
}) => LeakInstance(
  signature: signature,
  leakedType: type,
  count: count,
  firstSeen: at(minute),
  lastSeen: at(minute),
  creationSite: created,
  watchSite: watched,
  classSite: declared,
  creationSiteGap: gap,
  trace: trace,
);

/// A trace in which `PageRegistry.pages` holds the leaked object: the likely cause,
/// whose name is what the leak is called. With [internal], the holder is in LeakSentry.
LeakTrace causeTrace({
  String holder = 'PageRegistry',
  String variable = 'pages',
  String leaked = '_PageThreeState',
  bool internal = false,
}) => LeakTrace(
  gcRootType: 'user global',
  fingerprint: '$holder.$variable',
  nodes: [
    TraceNode(
      kind: TraceNodeKind.staticHolder,
      name: holder,
      library: internal ? 'package:leak_sentry/core/engine.dart' : 'package:leak_entry_app/main.dart',
      status: NodeStatus.inUse,
      note: 'A static variable lives as long as the app.',
      reference: TraceReference(
        kind: TraceReferenceKind.staticVariable,
        name: '.$variable',
        genericName: variable,
        isSuspect: true,
      ),
    ),
    TraceNode(
      kind: TraceNodeKind.instance,
      name: leaked,
      status: NodeStatus.shouldBeGone,
      note: 'Expected to be gone: $leaked received State#dispose() callback',
    ),
  ],
);

LeakGroup leakGroup({
  String id = 'sig:one',
  LeakKind kind = LeakKind.retained,
  String type = '_PageThreeState',
  String reason = '_PageThreeState received State#dispose() callback',
  List<LeakInstance>? instances,
  int minute = 0,
  bool unread = true,
}) => LeakGroup(
  id: id,
  kind: kind,
  leakedType: type,
  reason: reason,
  instances: instances ?? [leakInstance(minute: minute)],
  firstSeen: at(minute),
  lastSeen: at(minute),
  isUnread: unread,
);
