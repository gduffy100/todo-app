/// Fractional indexing: string sort keys that always leave room between
/// neighbours, so moving an item only rewrites that one row (sync-friendly).
///
/// Keys use base-62 digits in ASCII order, so plain string comparison
/// (and SQLite's BINARY collation) sorts them correctly. Keys never end
/// in '0', which guarantees a key can always be generated before any other.
library;

const _digits =
    '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';

/// Returns a key strictly between [before] and [after].
/// Pass null for [before] to insert at the start, null for [after] for the end.
String keyBetween(String? before, String? after) {
  final a = before ?? '';
  if (after != null && a.compareTo(after) >= 0) {
    throw ArgumentError('before ($before) must sort before after ($after)');
  }
  return _midpoint(a, after);
}

/// Returns [count] ascending keys, evenly spread from the start of the space.
List<String> initialKeys(int count) {
  final keys = <String>[];
  String? last;
  for (var i = 0; i < count; i++) {
    last = keyBetween(last, null);
    keys.add(last);
  }
  return keys;
}

String _midpoint(String a, String? b) {
  if (b != null) {
    // Skip the common prefix (treating a as zero-padded).
    var n = 0;
    while (n < b.length && (n < a.length ? a[n] : '0') == b[n]) {
      n++;
    }
    if (n > 0) {
      return b.substring(0, n) +
          _midpoint(n < a.length ? a.substring(n) : '', b.substring(n));
    }
  }
  final digitA = a.isNotEmpty ? _digits.indexOf(a[0]) : 0;
  final digitB = b != null ? _digits.indexOf(b[0]) : _digits.length;
  if (digitB - digitA > 1) {
    return _digits[((digitA + digitB) / 2).round()];
  }
  // Adjacent first digits: extend.
  if (b != null && b.length > 1) return b.substring(0, 1);
  return _digits[digitA] + _midpoint(a.length > 1 ? a.substring(1) : '', null);
}
