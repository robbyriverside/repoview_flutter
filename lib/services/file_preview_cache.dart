import 'dart:io';
import 'dart:typed_data';

class FilePreviewCache {
  FilePreviewCache({this.maxEntries = 200});

  final int maxEntries;
  final Map<String, _CacheEntry> _memoryCache = <String, _CacheEntry>{};

  Future<CachedPreview?> getImagePreview(File file) async {
    final _CacheEntry? entry = _memoryCache[file.path];
    if (entry != null && entry.type == PreviewType.image) {
      return CachedPreview(
        type: entry.type,
        data: entry.bytes,
        generatedAt: entry.generatedAt,
      );
    }

    if (!await file.exists()) {
      _memoryCache.remove(file.path);
      return null;
    }

    final Uint8List bytes = await file.readAsBytes();
    final _CacheEntry newEntry = _CacheEntry.image(bytes);
    _setEntry(file.path, newEntry);
    return CachedPreview(
      type: newEntry.type,
      data: newEntry.bytes,
      generatedAt: newEntry.generatedAt,
    );
  }

  Future<CachedPreview?> getTextPreview(
    File file, {
    int maxLength = 4096,
  }) async {
    final _CacheEntry? entry = _memoryCache[file.path];
    if (entry != null && entry.type == PreviewType.text) {
      return CachedPreview(
        type: entry.type,
        text: entry.text,
        generatedAt: entry.generatedAt,
      );
    }

    if (!await file.exists()) {
      _memoryCache.remove(file.path);
      return null;
    }

    final String contents = await file.readAsString();
    final String truncated =
        contents.length <= maxLength
            ? contents
            : contents.substring(0, maxLength);
    final _CacheEntry newEntry = _CacheEntry.text(truncated);
    _setEntry(file.path, newEntry);
    return CachedPreview(
      type: newEntry.type,
      text: newEntry.text,
      generatedAt: newEntry.generatedAt,
    );
  }

  Future<CachedPreview?> getMarkdownPreview(
    File file, {
    int maxLength = 8192,
  }) async {
    final _CacheEntry? entry = _memoryCache[file.path];
    if (entry != null && entry.type == PreviewType.markdown) {
      return CachedPreview(
        type: entry.type,
        text: entry.text,
        generatedAt: entry.generatedAt,
      );
    }

    if (!await file.exists()) {
      _memoryCache.remove(file.path);
      return null;
    }

    final String contents = await file.readAsString();
    final String truncated =
        contents.length <= maxLength
            ? contents
            : contents.substring(0, maxLength);
    final _CacheEntry newEntry = _CacheEntry.markdown(truncated);
    _setEntry(file.path, newEntry);
    return CachedPreview(
      type: newEntry.type,
      text: newEntry.text,
      generatedAt: newEntry.generatedAt,
    );
  }

  void clear() {
    _memoryCache.clear();
  }

  void prune() {
    if (_memoryCache.length <= maxEntries) {
      return;
    }
    final List<MapEntry<String, _CacheEntry>> entries =
        _memoryCache.entries.toList()..sort(
          (MapEntry<String, _CacheEntry> a, MapEntry<String, _CacheEntry> b) =>
              a.value.generatedAt.compareTo(b.value.generatedAt),
        );
    final int removeCount = _memoryCache.length - maxEntries;
    for (int i = 0; i < removeCount; i++) {
      _memoryCache.remove(entries[i].key);
    }
  }

  void _setEntry(String key, _CacheEntry entry) {
    _memoryCache[key] = entry;
    prune();
  }
}

enum PreviewType { image, text, markdown }

class CachedPreview {
  CachedPreview({
    required this.type,
    this.data,
    this.text,
    required this.generatedAt,
  });

  final PreviewType type;
  final Uint8List? data;
  final String? text;
  final DateTime generatedAt;
}

class _CacheEntry {
  _CacheEntry._(this.type, this.bytes, this.text, this.generatedAt);

  final PreviewType type;
  final Uint8List? bytes;
  final String? text;
  final DateTime generatedAt;

  factory _CacheEntry.image(Uint8List bytes) {
    return _CacheEntry._(
      PreviewType.image,
      bytes,
      null,
      DateTime.now().toUtc(),
    );
  }

  factory _CacheEntry.text(String text) {
    return _CacheEntry._(PreviewType.text, null, text, DateTime.now().toUtc());
  }

  factory _CacheEntry.markdown(String text) {
    return _CacheEntry._(
      PreviewType.markdown,
      null,
      text,
      DateTime.now().toUtc(),
    );
  }
}
