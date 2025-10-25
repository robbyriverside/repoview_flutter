import 'dart:io';
import 'dart:ui';

import 'package:path/path.dart' as p;

import 'rvg_models.dart';
import 'rvg_types.dart';

class RvgSyncResult {
  const RvgSyncResult({
    required this.document,
    required this.addedNodes,
    required this.removedNodes,
    this.warnings = const <String>[],
  });

  final RvgDocument document;
  final int addedNodes;
  final int removedNodes;
  final List<String> warnings;
}

class RvgSyncService {
  const RvgSyncService();

  static const String _originKey = 'origin';
  static const String _rootKey = 'rootPath';
  static const String _relativePathKey = 'relativePath';
  static const String _isDirectoryKey = 'isDirectory';
  static const String _originValue = 'filesystem';

  Future<RvgSyncResult> syncWithDirectory({
    required RvgDocument document,
    required Directory workspaceRoot,
  }) async {
    final DateTime start = DateTime.now().toUtc();
    final Map<String, RvgNode> managedNodes = <String, RvgNode>{};
    final List<RvgNode> unmanagedNodes = <RvgNode>[];

    for (final RvgNode node in document.nodes) {
      if (_isManagedNode(node, workspaceRoot)) {
        managedNodes[node.id] = node;
      } else {
        unmanagedNodes.add(node);
      }
    }

    final _DirectorySnapshot snapshot = await _scanDirectory(workspaceRoot);

    int added = 0;
    int removed = 0;
    bool changed = false;
    final Map<String, RvgNode> nextManagedNodes = <String, RvgNode>{};

    int index = 0;
    for (final _FsEntry entry in snapshot.entries) {
      final String nodeId = _nodeIdForEntry(entry.relativePath);
      final RvgNode? existing = managedNodes[nodeId];

      final RvgNode candidate = RvgNode(
        id: nodeId,
        label: entry.displayName,
        visual: entry.isDirectory ? RvgVisualType.folder : RvgVisualType.file,
        position: existing?.position ?? _autoPosition(index, entry.isDirectory),
        size:
            existing?.size ??
            (entry.isDirectory ? const Size(240, 140) : const Size(200, 100)),
        connections: existing?.connections ?? const <String>[],
        filePath: entry.absolutePath,
        metadata: <String, dynamic>{
          _originKey: _originValue,
          _rootKey: workspaceRoot.path,
          _relativePathKey: entry.relativePath,
          _isDirectoryKey: entry.isDirectory,
        },
      );

      if (existing == null) {
        added += 1;
        changed = true;
      } else if (existing != candidate) {
        changed = true;
      }

      nextManagedNodes[nodeId] = candidate;
      index += 1;
    }

    for (final String nodeId in managedNodes.keys) {
      if (!nextManagedNodes.containsKey(nodeId)) {
        removed += 1;
        changed = true;
      }
    }

    if (!changed) {
      return RvgSyncResult(
        document: document,
        addedNodes: 0,
        removedNodes: 0,
        warnings: snapshot.warnings,
      );
    }

    final List<RvgNode> combinedNodes = <RvgNode>[
      ...unmanagedNodes,
      ...nextManagedNodes.values,
    ];

    final RvgDocument nextDocument = document.copyWith(
      nodes: combinedNodes,
      updatedAt: start,
    );

    return RvgSyncResult(
      document: nextDocument,
      addedNodes: added,
      removedNodes: removed,
      warnings: snapshot.warnings,
    );
  }

  bool _isManagedNode(RvgNode node, Directory root) {
    final Map<String, dynamic> metadata = node.metadata;
    return metadata[_originKey] == _originValue &&
        metadata[_rootKey] == root.path;
  }

  Offset _autoPosition(int index, bool isDirectory) {
    const double baseX = 80;
    const double baseY = 120;
    const double columnWidth = 280;
    const double rowHeight = 180;
    final int columns = 4;

    final int column = index % columns;
    final int row = index ~/ columns;

    final double widthOffset = isDirectory ? 20 : 0;
    final double heightOffset = isDirectory ? 10 : 0;

    return Offset(
      baseX + column * columnWidth + widthOffset,
      baseY + row * rowHeight + heightOffset,
    );
  }

  String _nodeIdForEntry(String relativePath) {
    return 'fs:${relativePath.replaceAll('\\', '/')}';
  }

  Future<_DirectorySnapshot> _scanDirectory(Directory root) async {
    final List<_FsEntry> entries = <_FsEntry>[];
    final List<String> warnings = <String>[];
    if (!await root.exists()) {
      warnings.add('Workspace directory ${root.path} does not exist.');
      return _DirectorySnapshot(entries: entries, warnings: warnings);
    }

    try {
      await for (final FileSystemEntity entity in root.list(recursive: false)) {
        final String name = p.basename(entity.path);
        if (_shouldSkipName(name)) {
          continue;
        }
        final bool isDirectory = entity is Directory;
        final String relativePath = p.relative(entity.path, from: root.path);
        entries.add(
          _FsEntry(
            absolutePath: entity.path,
            relativePath: relativePath,
            displayName: name,
            isDirectory: isDirectory,
          ),
        );
      }
    } catch (error) {
      warnings.add('Failed to scan ${root.path}: $error');
    }

    entries.sort((a, b) {
      if (a.isDirectory != b.isDirectory) {
        return a.isDirectory ? -1 : 1;
      }
      return a.relativePath.compareTo(b.relativePath);
    });

    return _DirectorySnapshot(entries: entries, warnings: warnings);
  }

  bool _shouldSkipName(String name) {
    if (name.startsWith('.')) {
      return true;
    }
    if (name == 'build') {
      return true;
    }
    return false;
  }
}

class _DirectorySnapshot {
  const _DirectorySnapshot({
    required this.entries,
    this.warnings = const <String>[],
  });

  final List<_FsEntry> entries;
  final List<String> warnings;
}

class _FsEntry {
  const _FsEntry({
    required this.absolutePath,
    required this.relativePath,
    required this.displayName,
    required this.isDirectory,
  });

  final String absolutePath;
  final String relativePath;
  final String displayName;
  final bool isDirectory;
}
