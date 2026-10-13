import 'package:leak_sentry/models/creation_site.dart';

/// How long ago [then] was, as a short phrase: "just now", "5 min ago",
/// "3 h ago", "yesterday", "4 days ago", and after a month the date.
///
/// A time that is in the future (the clock moved) is "just now".
String formatAgo(DateTime then, DateTime now) {
  final elapsed = now.difference(then);
  if (elapsed < const Duration(seconds: 45)) return 'just now';
  if (elapsed < const Duration(hours: 1)) return '${elapsed.inMinutes < 1 ? 1 : elapsed.inMinutes} min ago';
  if (elapsed < const Duration(days: 1)) return '${elapsed.inHours} h ago';
  if (elapsed < const Duration(days: 2)) return 'yesterday';
  if (elapsed < const Duration(days: 30)) return '${elapsed.inDays} days ago';
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final date = '${months[then.month - 1]} ${then.day}';
  return then.year == now.year ? date : '$date, ${then.year}';
}

/// How long something took: "30 ms", or "1.4 s" from a second on.
String formatDuration(Duration duration) {
  if (duration < const Duration(seconds: 1)) return '${duration.inMilliseconds} ms';
  return '${(duration.inMilliseconds / 1000).toStringAsFixed(1)} s';
}

/// The file of [site] and its line, with its folder so that it can be told from another
/// file of the same name: `screens/home_page.dart:42`, and `lib/main.dart:196` for a file
/// straight in `lib`. It is what fits on a row; [fullLocation] is what a developer pastes.
String shortLocation(CreationSite site) {
  final path = _shortPath(site.uri);
  return site.line == null ? path : '$path:${site.line}';
}

String _shortPath(String uri) {
  final end = uri.indexOf('?');
  final clean = end < 0 ? uri : uri.substring(0, end);
  final segments = [
    for (final segment in clean.split('/'))
      if (segment.isNotEmpty) segment,
  ];
  if (clean.startsWith('package:')) {
    // The first segment is the package, which is not part of the path in the project.
    final inner = segments.skip(1).toList();
    if (inner.isEmpty) return clean;
    return inner.length == 1 ? 'lib/${inner.single}' : inner.sublist(inner.length - 2).join('/');
  }
  return segments.length <= 2 ? segments.join('/') : segments.sublist(segments.length - 2).join('/');
}

/// The file of [site], its line and its column, as the VM reported them:
/// `package:leak_entry_app/main.dart:196:11`.
String fullLocation(CreationSite site) {
  final line = site.line;
  if (line == null) return site.uri;
  final column = site.column;
  return column == null ? '${site.uri}:$line' : '${site.uri}:$line:$column';
}

/// The directory and package of [site]: `package:leak_entry_app`, shown dim
/// next to the file name.
String locationPackage(CreationSite site) {
  final uri = site.uri;
  final slash = uri.lastIndexOf('/');
  return slash < 0 ? '' : uri.substring(0, slash);
}

/// [text] with places to break the line after each of the characters in [after]:
/// `_CustomZone.bindUnaryCallback.<anonymous closure>` wraps at its dots instead of
/// in the middle of a word, and `<anonymous closure>` is kept in one piece. It is for
/// showing: what is copied is [text] itself.
String breakable(String text, {required String after}) {
  text = text.replaceAll('<anonymous closure>', '<anonymous\u00A0closure>');
  final buffer = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    final character = text[i];
    buffer.write(character);
    final next = i + 1 < text.length ? text[i + 1] : null;
    if (after.contains(character) && next != null && !after.contains(next) && next != ' ') buffer.write('\u200B');
  }
  return buffer.toString();
}

/// [count] and the noun that goes with it: "1 object", "3 objects".
String countOf(int count, String one, [String? many]) => '$count ${count == 1 ? one : (many ?? '${one}s')}';

/// A list of types as a phrase: `A`, `A and B`, `A, B and 2 more`.
String describeTypes(List<String> types) => switch (types.length) {
  0 => '',
  1 => types[0],
  2 => '${types[0]} and ${types[1]}',
  _ => '${types[0]}, ${types[1]} and ${types.length - 2} more',
};

/// [phrase] with a line never ending on its "and": `A and B` may wrap before the "and",
/// not after it. It is for showing: what is copied is [phrase] itself.
String glueAnd(String phrase) => phrase.replaceAll(' and ', ' and\u00A0');
