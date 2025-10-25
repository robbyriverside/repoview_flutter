import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:repoview_flutter/rvg/rvg_models.dart';
import 'package:repoview_flutter/rvg/rvg_sync_service.dart';
import 'package:repoview_flutter/rvg/rvg_types.dart';

void main() {
  group('RvgSyncService', () {
    late Directory tempDir;
    late RvgSyncService syncService;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('rvg-sync-test-');
      syncService = const RvgSyncService();
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'adds nodes for new filesystem entries while preserving manual nodes',
      () async {
        final File fileA = File(p.join(tempDir.path, 'fileA.txt'));
        final Directory folderB = Directory(p.join(tempDir.path, 'folderB'));
        await fileA.writeAsString('hello');
        await folderB.create();

        final RvgDocument startingDocument = RvgDocument(
          version: '1.0.0',
          createdAt: DateTime.utc(2024),
          updatedAt: DateTime.utc(2024),
          nodes: const <RvgNode>[
            RvgNode(
              id: 'manual',
              label: 'Manual Shape',
              visual: RvgVisualType.rectangle,
              position: Offset(10, 10),
              size: Size(120, 80),
              metadata: <String, dynamic>{'custom': true},
            ),
          ],
        );

        final RvgSyncResult result = await syncService.syncWithDirectory(
          document: startingDocument,
          workspaceRoot: tempDir,
        );

        expect(result.addedNodes, 2);
        expect(result.removedNodes, 0);
        expect(result.document.nodes.length, 3);
        final RvgNode manualNode = result.document.nodes.firstWhere(
          (node) => node.id == 'manual',
        );
        expect(manualNode.metadata['custom'], true);

        final Iterable<RvgNode> fsNodes = result.document.nodes.where(
          (node) => node.id.startsWith('fs:'),
        );
        expect(fsNodes.length, 2);
        expect(
          fsNodes.any((node) => node.metadata['relativePath'] == 'fileA.txt'),
          isTrue,
        );
        expect(
          fsNodes.any((node) => node.metadata['relativePath'] == 'folderB'),
          isTrue,
        );
      },
    );

    test('removes nodes when filesystem entries disappear', () async {
      final String fileRelative = 'obsolete.txt';
      final RvgNode managedNode = RvgNode(
        id: 'fs:$fileRelative',
        label: 'obsolete',
        visual: RvgVisualType.file,
        position: const Offset(10, 10),
        size: const Size(120, 80),
        metadata: <String, dynamic>{
          'origin': 'filesystem',
          'rootPath': tempDir.path,
          'relativePath': fileRelative,
          'isDirectory': false,
        },
      );
      final RvgDocument startingDocument = RvgDocument(
        version: '1.0.0',
        createdAt: DateTime.utc(2024),
        updatedAt: DateTime.utc(2024),
        nodes: <RvgNode>[managedNode],
      );

      final RvgSyncResult result = await syncService.syncWithDirectory(
        document: startingDocument,
        workspaceRoot: tempDir,
      );

      expect(result.addedNodes, 0);
      expect(result.removedNodes, 1);
      expect(result.document.nodes, isEmpty);
    });
  });
}
