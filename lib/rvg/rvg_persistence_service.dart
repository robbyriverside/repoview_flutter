import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'rvg_models.dart';

class RvgPersistenceException implements Exception {
  RvgPersistenceException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() {
    if (cause == null) {
      return 'RvgPersistenceException: $message';
    }
    return 'RvgPersistenceException: $message (cause: $cause)';
  }
}

class RvgPersistenceService {
  const RvgPersistenceService();

  Future<RvgDocument> loadFromFile(File file) async {
    try {
      final String raw = await file.readAsString();
      final dynamic decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('RVG payload must be a JSON object.');
      }
      return RvgDocument.fromJson(decoded);
    } catch (error) {
      throw RvgPersistenceException(
        'Failed to load RVG document from ${file.path}',
        error,
      );
    }
  }

  Future<void> saveToFile(
    File file,
    RvgDocument document, {
    bool createBackup = true,
  }) async {
    try {
      if (!await file.parent.exists()) {
        await file.parent.create(recursive: true);
      }
      if (createBackup && await file.exists()) {
        await _writeBackup(file);
      }
      final String serialized = const JsonEncoder.withIndent(
        '  ',
      ).convert(document.toJson());
      await file.writeAsString(serialized);
    } catch (error) {
      throw RvgPersistenceException(
        'Failed to save RVG document to ${file.path}',
        error,
      );
    }
  }

  Future<RvgDocument> loadOrCreate(
    File file, {
    required RvgDocument fallback,
  }) async {
    if (!await file.exists()) {
      await saveToFile(file, fallback);
      return fallback;
    }
    return loadFromFile(file);
  }

  Future<void> _writeBackup(File file) async {
    final DateTime now = DateTime.now().toUtc();
    final String timestamp =
        '${now.year.toString().padLeft(4, '0')}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';
    final String baseName = p.basename(file.path);
    final String backupName = '$baseName.$timestamp.bak';
    final File backupFile = File(p.join(file.parent.path, backupName));
    try {
      await file.copy(backupFile.path);
    } catch (error) {
      throw RvgPersistenceException(
        'Failed to create backup for ${file.path}',
        error,
      );
    }
  }
}
