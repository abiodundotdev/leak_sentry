Automatic memory-leak detection for Flutter.

LeakSentry watches the objects Flutter disposes and tells you which ones something is still holding on to, and what is holding them.

1. **Watch.** When Flutter disposes a `State`, a `Route`, a `ChangeNotifier` or an `AnimationController`, LeakSentry expects it to be garbage collected, and holds a weak reference to it.
2. **Wait five seconds.** If the weak reference hasn't been cleared by then, the object is *retained*. Nothing has forced a GC yet, so this is provisional.
3. **Check.** A retained object schedules a check. It forces a GC, counts again, and then decides: while the app is visible it waits for **5** retained objects (and rechecks every 2 s); once the app is in the background it dumps for any number. It never dumps more than once a minute.
4. **Dump and analyze.** The retained objects are captured, the VM is asked for the retaining path of each distinct leak, and the leaks are reported. An object that was reported is never reported again.

Resources that never get a disposal callback (a raw `StreamController`) are covered by a second detection: [reporting a resource garbage collected without being closed](#detecting-unclosed-resources).

## Getting started

Call `install` once at startup, after the bindings are initialized:

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:leak_sentry/leak_sentry.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kReleaseMode) LeakSentry.install();
  runApp(const MyApp());
}
```

Or wrap your app root in the `LeakSentry` widget, which installs it for you (outside of release builds, and outside of `flutter test`):

```dart
LeakSentry(child: MaterialApp(home: const HomePage()))
```

Add `LeakSentryOverlay` inside it to see leaks in the running app, as [described below](#seeing-leaks-in-the-app).

`install` throws in a release build: a heap dump freezes the app, and a release build has no VM service to analyze it with. If you really want it there, pass `allowInRelease: true`. To only *count* retained objects in release builds, without ever dumping the heap, call `LeakSentry.installObjectWatcher()` and read `LeakSentry.retainedObjectCount`.

### What is watched

Flutter reports object creation and disposal, from inside an `assert`, in **debug builds only**. In a debug build LeakSentry watches:

| Object | Expected to be collected after | Notes |
| --- | --- | --- |
| `State` | `State.dispose()` | The creation site is the `initState` of the leaking `State`. |
| `Route` | `Route.dispose()` | |
| `ChangeNotifier` | `ChangeNotifier.dispose()` | Flutter's own notifiers (`ValueNotifier`, `ScrollController`, `FocusNode`...) do this already. **Your own subclass** has to call `ChangeNotifier.maybeDispatchObjectCreation(this)` in its constructor, which is what makes Flutter report its disposal. |
| `AnimationController` | `AnimationController.dispose()` | |

`Element`, `RenderObject` and `Layer` aren't watched, because Flutter creates thousands of them a second. `AllDisposedObjectsWatcher` watches everything Flutter reports disposed if you want it.

Pass your own `watchers` to `install`, starting from `LeakSentry.defaultWatchers()`, and a reporter that filters out objects you don't want watched:

```dart
LeakSentry.install(
  watchers: LeakSentry.defaultWatchers(
    LeakSentry.objectWatcher.filteringInstances<State>((state) => state is! KnownBadState),
  ),
);
```

### Watching anything else

```dart
@override
void dispose() {
  _myPlainDartObject.tearDown();
  LeakSentry.objectWatcher.watch(_myPlainDartObject, 'MyWidget._myPlainDartObject');
  super.dispose();
}
```

That works in profile builds too, where nothing is watched automatically, as long as a VM service is available. A call made before `install` is ignored, so it's safe to leave in release code.

## Seeing leaks in the app

Put `LeakSentryOverlay` above your app's navigator. It shows nothing until there is something to say, then a small badge with the number of leaks (and, while objects are being held but not yet scanned, a notice that says how many). Tap the badge to open the LeakSentry screen:

```dart
LeakSentry(
  child: MaterialApp(
    builder: (context, child) => LeakSentryOverlay(child: child ?? const SizedBox()),
    home: const HomePage(),
  ),
)
```

Or open it from your own debug menu with `LeakSentry.showScreen(context)`, or embed `LeakSentryScreen` as a page of your own. The screen is a route of your app's navigator, so back, dialogs and text selection work in it.

It has three tabs:

- **Leaks** lists the distinct leaks, the one with the most objects first. Leaks held the same way are one leak, whatever they are and wherever they were created. A row says what is holding the objects (the likely cause), what it holds, where the first of them was created, and when it was last seen.
- **Scans** lists the heap scans: why each started, how many objects were held, how many leaks it found and how many are new, and where each leak came from. It also says whether a scan is running, why none is, and has **Scan now**.
- **Settings** has the switch for scanning automatically, how many held objects to wait for before it does, and clears the list.

Tap a leak to see:

- **Where it was created.** The file and line of every instance, always: see [below](#where-the-leaked-object-was-created).
- **What is holding it.** The path from something that lives as long as the app (a static variable, Dart's timers) to the leaked object, one step at a time. Each step says whether it is *in use*, *should be gone* or *unclear*, and why, and the references that are the likeliest cause are highlighted: start with those.
- **Copy report** and **Print to console**, which give the same as plain text to paste into an issue.

Everything the screen lists is kept for the session only. In a release build the overlay shows nothing unless you installed LeakSentry there on purpose (`allowInRelease`), so the people who use your app never see a leak badge.

## Reading what it found

LeakSentry logs what it is doing and what it finds (set `LeakSentryLog.verbose = true` to also see a line for every object it starts watching, which is a lot: Flutter disposes hundreds on each navigation):

```
LeakSentry: LeakSentry is running and ready to detect memory leaks.
LeakSentry: Found 1 object retained, not dumping heap yet (app is visible & < 5 threshold)
LeakSentry: Found 5 objects retained, dumping heap now (app is visible & >=5 threshold)
LeakSentry: Analysis in progress, 30% done, working on Finding paths to retained objects
====================================
HEAP ANALYSIS RESULT
====================================
1 APPLICATION LEAK

LeakReport(_PageFiveState, LeakConfidence.retainedAfterGc, reason: "_PageFiveState received State#dispose() callback", occurrences: 1, createdAt: _PageFiveState.initState (package:my_app/main.dart:261:11), likelyCause: PageRegistry.pages, retainingPath: _PageFiveState <- held by _GrowableList.0 <- held by PageRegistry.pages (static) <- held by GC root (user global))
```

And in code:

```dart
LeakSentry.leaks.listen((report) => myCrashReporting.log(report));   // Stream<LeakReport>
LeakSentry.leakHistory;                                              // List<LeakReport>, deduped
LeakSentry.expectNoLeaks();                                          // throws if a leak was found
LeakSentry.events.listen(print);                                     // DumpingHeapEvent, HeapDumpEvent, ...
await LeakSentry.dumpHeap();                                         // dump and analyze now; completes once the leaks are in leakHistory
await LeakSentry.runGc();                                            // force a GC, e.g. so a test sees an unclosed resource reported
```

Repeats of the same leak (same type, reason and creation site) are one `LeakReport`, and `occurrenceCount` says how many. Only the first of each costs a retaining-path lookup.

### Where the leaked object was created

Every leak says where to start looking, in the report, in the log and on the screen. `LeakReport.creationSite` names the first stack frame outside the Dart SDK, Flutter and `leak_sentry` at the moment Flutter announced the object's creation:

```
Created at: _PageThreeState.initState (package:my_app/page_three.dart:193:11)
```

When that is not known, there is always the next best thing, in this order:

1. `creationSite`: where the object was created.
2. `watchSite`: where `LeakSentry.objectWatcher.watch` was called, for an object you watched by hand.
3. `classSite`: where the class of the leaked object is declared, as the VM says it.
4. `creationSiteGap`: why none of those is known (`CreationSiteGap`): it is not a debug build, it is the web, Flutter never announced the object (it was created before `install`, or it is a `ChangeNotifier` of yours that does not report its creation), only Flutter code was running when it was created (a `State` with no `initState` of its own looks like this), the stack has no file names (`--split-debug-info`), or the stack could not be read.

A report always has `creationSite`, or `watchSite`, or a `creationSiteGap`: a test checks it. A resource that was never closed says where it was *acquired* instead.

Treat it as a pointer to where to start looking, not a guarantee. It is where the object was *created*, not where whatever retains it stored a reference: that is what the retaining path is for.

### The trace

`LeakReport.retainingPath` is the chain of references the VM gave. `LeakReport.trace` is that chain worked out: every step named as it is written in code, what each step is (`NodeStatus.inUse`, `shouldBeGone`, `unclear`) and why, which references are the likely causes (`TraceReference.isSuspect`), and a `fingerprint` that is the same for the same bug in another scan, run or device. It is null when there is no path.

- The leaked object is always *should be gone*. What holds something that is in use is in use; what a leak holds is a leak; what is in between LeakSentry cannot tell. A reference is a likely cause when its step is unclear, or in use and holding something that is not.
- What tells steps apart: the leaked object, static variables, Dart's own event loop, the framework's singletons, other objects that are watched and retained, and, through their fields as the VM reports them, a `State` that was disposed, an `Element` that left the tree, a `Route` its navigator let go of, a `ChangeNotifier` or `RenderObject` that was disposed, and an `AnimationController` with no ticker.
- The fingerprint is made of the likely causes (`library:Class:reference`, with no index, key or address) and only of what the path alone says, so a question the VM could not answer never turns one leak into two.

## Configuration

```dart
LeakSentry.config = LeakSentry.config.copyWith(retainedVisibleThreshold: 3);
```

| Option | Default | |
| --- | --- | --- |
| `dumpHeap` | `true` | Turn it off to disable dumping, for a demo for example. |
| `retainedVisibleThreshold` | `5` | Retained objects to wait for while the app is visible. |
| `enableRetainingPathAnalysis` | `true` | Look up retaining paths through the VM service. |
| `maxRetainingPathLookups` | `20` | Each lookup walks the whole heap and pauses the app. |
| `heapDumper` | captures the retained set | Replace how the dump is taken. |
| `eventListeners` | log + analyze | Start from `LeakSentry.defaultEventListeners` to add one. |

`install` takes `retainedDelay` (default 5 s), `watchers` and `allowInRelease`.

## Detecting unclosed resources

Swap `StreamController` for `TrackedStreamController` and get detection with no other code changes:

```dart
final _controller = TrackedStreamController<int>(label: 'MyWidget._controller');
```

Or track any other resource manually:

```dart
final _token = LeakSentry.trackResource(mySocket, label: 'MyWidget._socket');
// ... later, on the real close path:
_token.markClosed();
```

If the resource is garbage collected without `markClosed` having been called, a leak is reported with the stack trace of where it started being tracked. It needs no `install`, no VM service, and works in release builds and on web.

## Design notes

How the detection is built, and why:

- **The GC runs only when it can change something.** A Dart GC pauses the isolate that runs the app, so a check skips the GC when every retained object became retained before the last GC started: that GC has already given each of them the chance to be collected. A GC always runs before a dump, and again after a minute.
- **Weak references and the GC.** A cleared `WeakReference` means the collector found the object unreachable. The GC is requested from the VM service, its effect is verified through the VM's reachability barrier, and without a VM service LeakSentry falls back to allocating until the VM collects.
- **Visibility** is the app lifecycle: visible while `resumed` or `inactive`, invisible while `hidden`, `paused` or `detached`.
- **Without a VM service the GC is tried sparingly.** The fallback allocates for up to two seconds, so it is tried once, again after a minute, and before every dump.
- **Nothing can wedge the checks.** The GC, the dump and the event listeners are asynchronous, so a GC or a dump that never answers is given up on after 30 s (and retried), and a listener holding up the chain of events is given up on after 10 s.
- **Test environments:** heap dumping is off under `flutter test` (it checks `FLUTTER_TEST`), and the widget doesn't auto-install there.
- **The heap dump is the retained set.** The retained objects are captured, and for each distinct leak the VM service supplies the retaining path. [The trace](#the-trace) is built from that path (statuses by propagation, likely causes, a fingerprint), and leaks that share a fingerprint are grouped. A step's fields are read from the live VM, so one whose id has expired is left unclear.
- **The analysis runs on the main isolate**, in steps that wait on the VM service, so frames can run between them. Isolates share one GC heap and can't exchange objects, so it can't simply move to another one.
- **Where it works:** a debug build for the automatic watchers; debug and profile for the VM service (forced GC and retaining paths). On the web `install` only counts retained objects (`LeakSentry.retainedObjectCount`), because a GC can't be forced there and nothing could be trusted.
- **Reaching the VM service.** LeakSentry connects to the app's *own* VM service, trying the address Dart reports and, on Android, the same port on the emulator's host address (`10.0.2.2`), because under `flutter run` the Flutter tool's Dart Development Service takes over the service. It re-reads the address each time it reconnects, and leaves the service alone for 15 s after no address worked. If the service can't be reached (for example on a physical device, where that service runs on your computer), LeakSentry forces the GC by allocating and reports leaks without a retaining path.

## Platform notes

### macOS: required entitlement

On macOS, LeakSentry connects to the app's *own* VM service to force garbage collection and resolve retaining paths. App Sandbox blocks this by default with `SocketException: Connection failed (OS Error: Operation not permitted)`, because the default Flutter template only grants `com.apple.security.network.server` (for external tools like DevTools to connect *in*), not `com.apple.security.network.client` (for the app to connect *out*, including to itself on `127.0.0.1`).

Add this to `macos/Runner/DebugProfile.entitlements`:

```xml
<key>com.apple.security.network.client</key>
<true/>
```

Without it LeakSentry still detects leaks, but forces the GC by allocating, which is slower and less certain, and reports no retaining path.

## Performance

`LeakSentry.stats` counts what detection has cost so far: events handled, forced GCs (and how many were skipped), heap dumps, analyses, retaining-path lookups, and the time spent in each.

---

Inspired by [LeakCanary](https://square.github.io/leakcanary/).
