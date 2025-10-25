import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:repoview_flutter/rvg/rvg_models.dart';
import 'package:repoview_flutter/rvg/rvg_persistence_service.dart';
import 'package:repoview_flutter/rvg/rvg_types.dart';
import 'package:repoview_flutter/rvg/rvg_sync_service.dart';

void main() {
  runApp(const GraphApp());
}

class GraphApp extends StatelessWidget {
  const GraphApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Graph Connectivity Playground',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      debugShowCheckedModeBanner: false,
      home: const GraphPage(),
    );
  }
}

class GraphPage extends StatefulWidget {
  const GraphPage({super.key});

  @override
  State<GraphPage> createState() => _GraphPageState();
}

class _GraphPageState extends State<GraphPage> {
  static const Size _canvasSize = Size(1400, 900);

  late final RvgPersistenceService _persistenceService;
  late final GraphUndoManager _undoManager;
  late final File _documentFile;
  late final Directory _workspaceRoot;
  late final RvgSyncService _syncService;
  late final Map<GraphShapeType, GraphShapeDelegate> _shapeRegistry;
  late RvgDocument _document;
  late List<GraphNode> _nodes;
  String? _selectedNodeId;
  bool _isSyncing = false;
  StreamSubscription<FileSystemEvent>? _watchSubscription;
  Timer? _syncDebounce;
  RvgDocument? _dragSnapshot;

  @override
  void initState() {
    super.initState();
    _persistenceService = const RvgPersistenceService();
    _undoManager = GraphUndoManager(capacity: 50);
    _syncService = const RvgSyncService();
    _workspaceRoot = Directory(
      '${Directory.systemTemp.path}/repoview-demo-workspace',
    );
    _documentFile = File('${_workspaceRoot.path}/.repoview.rvg');
    _shapeRegistry = {
      GraphShapeType.rectangle: const RectangleNodeShape(),
      GraphShapeType.circle: const CircleNodeShape(),
    };
    _document = RvgDocument.demo();
    _nodes = _document.nodes.map(GraphNode.fromRvgNode).toList();
    unawaited(_bootstrapWorkspace());
  }

  @override
  void dispose() {
    _watchSubscription?.cancel();
    _syncDebounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Graph Connectivity Playground'),
        actions: [
          IconButton(
            tooltip: 'Undo',
            icon: const Icon(Icons.undo),
            onPressed: _undoManager.canUndo ? _handleUndo : null,
          ),
          IconButton(
            tooltip: 'Redo',
            icon: const Icon(Icons.redo),
            onPressed: _undoManager.canRedo ? _handleRedo : null,
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Sync workspace',
            icon:
                _isSyncing
                    ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2.2),
                    )
                    : const Icon(Icons.sync),
            onPressed: _isSyncing ? null : () => unawaited(_runSync()),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: InteractiveViewer(
        minScale: 0.6,
        maxScale: 2.8,
        boundaryMargin: const EdgeInsets.all(240),
        constrained: false,
        child: SizedBox(
          width: _canvasSize.width,
          height: _canvasSize.height,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              const Positioned.fill(
                child: CustomPaint(painter: GraphBackgroundPainter()),
              ),
              Positioned.fill(
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: GraphEdgePainter(
                      nodes: _nodes,
                      shapeRegistry: _shapeRegistry,
                      selectedNodeId: _selectedNodeId,
                    ),
                  ),
                ),
              ),
              ..._nodes.map(_buildNodeWidget),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNodeWidget(GraphNode node) {
    final delegate = _shapeRegistry[node.shape];
    if (delegate == null) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final bool isCircle = node.shape == GraphShapeType.circle;

    return Positioned(
      left: node.position.dx,
      top: node.position.dy,
      child: GestureDetector(
        onPanStart: (_) => _beginNodeDrag(),
        onPanEnd: (_) => _endNodeDrag(),
        onTap: () => _handleNodeTap(node),
        onPanUpdate: (details) => _handleNodePan(node.id, details.delta),
        child: _buildNodeShadow(
          node: node,
          isCircle: isCircle,
          child: delegate.buildNode(
            node,
            isSelected: node.id == _selectedNodeId,
            theme: theme,
          ),
        ),
      ),
    );
  }

  Widget _buildNodeShadow({
    required GraphNode node,
    required bool isCircle,
    required Widget child,
  }) {
    final BoxShadow shadow = BoxShadow(
      color: _colorWithOpacity(Colors.black, 0.08),
      blurRadius: 12,
      offset: const Offset(0, 6),
    );

    if (isCircle) {
      final double diameter = node.size.shortestSide;
      return Container(
        width: diameter,
        height: diameter,
        decoration: BoxDecoration(shape: BoxShape.circle, boxShadow: [shadow]),
        child: child,
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(boxShadow: [shadow]),
      child: child,
    );
  }

  Future<void> _bootstrapWorkspace() async {
    try {
      if (!await _workspaceRoot.exists()) {
        await _workspaceRoot.create(recursive: true);
      }
      final File readme = File('${_workspaceRoot.path}/README.md');
      if (!await readme.exists()) {
        await readme.writeAsString(
          '# RepoView Demo Workspace\n\n'
          'This folder is auto-generated so the demo can sync files into the graph.\n',
        );
      }
      final File notes = File('${_workspaceRoot.path}/notes.txt');
      if (!await notes.exists()) {
        await notes.writeAsString(
          'Add files here to see them appear inside the RepoView graph.\n',
        );
      }
    } catch (error, stackTrace) {
      debugPrint('Failed to prepare workspace: $error');
      debugPrint('$stackTrace');
    }

    await _initializeDocumentFromDisk();
    await _runSync(silent: true);
    _startWatching();
  }

  Future<void> _initializeDocumentFromDisk() async {
    try {
      final RvgDocument loaded = await _persistenceService.loadOrCreate(
        _documentFile,
        fallback: _document,
      );
      _undoManager.reset();
      _dragSnapshot = null;
      setState(() {
        _document = loaded;
        _nodes = loaded.nodes.map(GraphNode.fromRvgNode).toList();
      });
    } on RvgPersistenceException catch (error) {
      debugPrint(error.toString());
    } catch (error, stackTrace) {
      debugPrint('Unexpected error loading RVG document: $error');
      debugPrint('$stackTrace');
    }
  }

  void _commitDocument(
    RvgDocument document, {
    bool clearSelection = false,
    String? nextSelection,
    bool recordUndo = false,
    bool persist = true,
  }) {
    if (recordUndo) {
      _undoManager.push(_document);
    }
    setState(() {
      _document = document;
      _nodes = document.nodes.map(GraphNode.fromRvgNode).toList();
      if (clearSelection) {
        _selectedNodeId = null;
      } else if (nextSelection != null) {
        _selectedNodeId = nextSelection;
      }
    });
    if (!persist) {
      return;
    }
    unawaited(_persistDocument(document));
  }

  Future<void> _persistDocument(RvgDocument document) async {
    try {
      await _persistenceService.saveToFile(_documentFile, document);
    } on RvgPersistenceException catch (error) {
      debugPrint(error.toString());
    } catch (error, stackTrace) {
      debugPrint('Unexpected error saving RVG document: $error');
      debugPrint('$stackTrace');
    }
  }

  Future<void> _runSync({bool silent = false}) async {
    if (_isSyncing) {
      return;
    }

    void setSyncing(bool value) {
      if (!mounted) {
        _isSyncing = value;
        return;
      }
      if (silent) {
        _isSyncing = value;
      } else {
        setState(() {
          _isSyncing = value;
        });
      }
    }

    setSyncing(true);
    try {
      final RvgSyncResult result = await _syncService.syncWithDirectory(
        document: _document,
        workspaceRoot: _workspaceRoot,
      );
      if (!identical(result.document, _document)) {
        _commitDocument(result.document);
      }
      for (final String warning in result.warnings) {
        debugPrint('Sync warning: $warning');
      }
    } catch (error, stackTrace) {
      debugPrint('Failed to sync workspace: $error');
      debugPrint('$stackTrace');
    } finally {
      setSyncing(false);
    }
  }

  void _startWatching() {
    _watchSubscription?.cancel();
    _watchSubscription = _workspaceRoot
        .watch(recursive: true)
        .listen(
          (FileSystemEvent event) {
            // Ignore events on the RVG file itself to avoid loops.
            if (event.path == _documentFile.path) {
              return;
            }
            _scheduleSilentSync();
          },
          onError: (Object error, StackTrace stackTrace) {
            debugPrint('Watcher error: $error');
            debugPrint('$stackTrace');
          },
          cancelOnError: false,
        );
  }

  void _scheduleSilentSync() {
    _syncDebounce?.cancel();
    _syncDebounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) {
        return;
      }
      unawaited(_runSync(silent: true));
    });
  }

  GraphNode? _findNodeById(String id) {
    for (final GraphNode node in _nodes) {
      if (node.id == id) {
        return node;
      }
    }
    return null;
  }

  void _handleNodePan(String nodeId, Offset delta) {
    final GraphNode? node = _findNodeById(nodeId);
    if (node == null) {
      return;
    }

    final Offset rawPosition = node.position + delta;
    final double maxX = _canvasSize.width - node.size.width;
    final double maxY = _canvasSize.height - node.size.height;

    final Offset boundedPosition = Offset(
      rawPosition.dx.clamp(0.0, maxX < 0 ? 0.0 : maxX).toDouble(),
      rawPosition.dy.clamp(0.0, maxY < 0 ? 0.0 : maxY).toDouble(),
    );

    final RvgDocument updatedDocument = _document.updateNode(
      nodeId,
      (RvgNode original) => original.copyWith(position: boundedPosition),
    );
    if (!identical(updatedDocument, _document)) {
      _commitDocument(updatedDocument);
    }
  }

  void _handleNodeTap(GraphNode tappedNode) {
    final String tappedId = tappedNode.id;
    final String? activeSource = _selectedNodeId;

    if (activeSource == null) {
      setState(() => _selectedNodeId = tappedId);
      return;
    }

    if (activeSource == tappedId) {
      setState(() => _selectedNodeId = null);
      return;
    }

    final RvgDocument updatedDocument = _document.updateNode(activeSource, (
      RvgNode source,
    ) {
      final bool hasEdge = source.connections.contains(tappedId);
      final List<String> updatedConnections =
          hasEdge
              ? source.connections.where((String id) => id != tappedId).toList()
              : <String>[...source.connections, tappedId];
      return source.copyWith(connections: updatedConnections);
    });
    if (identical(updatedDocument, _document)) {
      setState(() => _selectedNodeId = null);
      return;
    }
    _commitDocument(updatedDocument, clearSelection: true, recordUndo: true);
  }

  void _beginNodeDrag() {
    _dragSnapshot ??= _document;
  }

  void _endNodeDrag() {
    if (_dragSnapshot != null && !identical(_dragSnapshot, _document)) {
      _undoManager.push(_dragSnapshot!);
      setState(() {});
    }
    _dragSnapshot = null;
  }

  void _handleUndo() {
    final RvgDocument? previous = _undoManager.undo(_document);
    if (previous == null) {
      return;
    }
    _commitDocument(previous, clearSelection: true, recordUndo: false);
  }

  void _handleRedo() {
    final RvgDocument? next = _undoManager.redo(_document);
    if (next == null) {
      return;
    }
    _commitDocument(next, clearSelection: true, recordUndo: false);
  }
}

enum GraphShapeType { rectangle, circle }

enum AnchorSide { top, right, bottom, left }

class GraphNode {
  const GraphNode({
    required this.id,
    required this.label,
    required this.shape,
    required this.position,
    required this.size,
    this.connections = const <String>[],
    this.visualType = RvgVisualType.rectangle,
    this.sourcePath,
    this.metadata = const <String, dynamic>{},
  });

  final String id;
  final String label;
  final GraphShapeType shape;
  final Offset position;
  final Size size;
  final List<String> connections;
  final RvgVisualType visualType;
  final String? sourcePath;
  final Map<String, dynamic> metadata;

  factory GraphNode.fromRvgNode(RvgNode node) {
    return GraphNode(
      id: node.id,
      label: node.label,
      shape: _shapeFromVisual(node.visual),
      position: node.position,
      size: node.size,
      connections: List<String>.unmodifiable(node.connections),
      visualType: node.visual,
      sourcePath: node.filePath,
      metadata: Map<String, dynamic>.unmodifiable(node.metadata),
    );
  }

  RvgNode toRvgNode() {
    return RvgNode(
      id: id,
      label: label,
      visual: visualType,
      position: position,
      size: size,
      connections: List<String>.from(connections),
      filePath: sourcePath,
      metadata: Map<String, dynamic>.from(metadata),
    );
  }

  GraphNode copyWith({
    String? id,
    String? label,
    GraphShapeType? shape,
    Offset? position,
    Size? size,
    List<String>? connections,
    RvgVisualType? visualType,
    String? sourcePath,
    Map<String, dynamic>? metadata,
  }) {
    final GraphShapeType resolvedShape = shape ?? this.shape;
    final RvgVisualType resolvedVisualType =
        visualType ??
        (shape != null ? _visualFromShape(shape) : this.visualType);
    return GraphNode(
      id: id ?? this.id,
      label: label ?? this.label,
      shape: resolvedShape,
      position: position ?? this.position,
      size: size ?? this.size,
      connections: connections ?? List<String>.from(this.connections),
      visualType: resolvedVisualType,
      sourcePath: sourcePath ?? this.sourcePath,
      metadata: metadata ?? Map<String, dynamic>.from(this.metadata),
    );
  }

  static GraphShapeType _shapeFromVisual(RvgVisualType visual) {
    switch (visual) {
      case RvgVisualType.circle:
        return GraphShapeType.circle;
      case RvgVisualType.rectangle:
      case RvgVisualType.folder:
      case RvgVisualType.file:
      case RvgVisualType.external:
      case RvgVisualType.note:
        return GraphShapeType.rectangle;
    }
  }

  static RvgVisualType _visualFromShape(GraphShapeType shape) {
    switch (shape) {
      case GraphShapeType.circle:
        return RvgVisualType.circle;
      case GraphShapeType.rectangle:
        return RvgVisualType.rectangle;
    }
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is GraphNode &&
        other.id == id &&
        other.label == label &&
        other.shape == shape &&
        other.position == position &&
        other.size == size &&
        listEquals(other.connections, connections) &&
        other.visualType == visualType &&
        other.sourcePath == sourcePath &&
        mapEquals(other.metadata, metadata);
  }

  @override
  int get hashCode => Object.hashAll(<Object?>[
    id,
    label,
    shape,
    position.dx,
    position.dy,
    size.width,
    size.height,
    Object.hashAll(connections),
    visualType,
    sourcePath,
    Object.hashAll(
      metadata.entries.map(
        (MapEntry<String, dynamic> entry) =>
            Object.hash(entry.key, entry.value),
      ),
    ),
  ]);
}

@immutable
class AnchorPair {
  const AnchorPair(this.start, this.end);

  final AnchorSide start;
  final AnchorSide end;
}

abstract class GraphShapeDelegate {
  const GraphShapeDelegate();

  Widget buildNode(
    GraphNode node, {
    required bool isSelected,
    required ThemeData theme,
  });

  Offset anchorFor(GraphNode node, AnchorSide side);
}

class RectangleNodeShape extends GraphShapeDelegate {
  const RectangleNodeShape();

  @override
  Widget buildNode(
    GraphNode node, {
    required bool isSelected,
    required ThemeData theme,
  }) {
    Color background = isSelected ? Colors.indigo.shade50 : Colors.white;
    Color borderColor = isSelected ? Colors.indigo : Colors.grey.shade400;
    double borderWidth = isSelected ? 3 : 1.6;
    EdgeInsets padding = const EdgeInsets.all(16);
    BorderRadius borderRadius = BorderRadius.circular(14);
    Widget child = _buildDefaultRectangularContent(node, theme, isSelected);

    switch (node.visualType) {
      case RvgVisualType.folder:
        background = isSelected ? Colors.amber.shade100 : Colors.amber.shade50;
        borderColor =
            isSelected ? Colors.amber.shade700 : Colors.amber.shade200;
        borderWidth = isSelected ? 3 : 2;
        padding = const EdgeInsets.fromLTRB(18, 16, 18, 14);
        child = _buildFolderContent(node, theme);
        break;
      case RvgVisualType.file:
        background =
            isSelected ? Colors.blueGrey.shade100 : Colors.blueGrey.shade50;
        borderColor =
            isSelected ? Colors.blueGrey.shade700 : Colors.blueGrey.shade200;
        borderWidth = isSelected ? 3 : 1.8;
        padding = const EdgeInsets.fromLTRB(18, 14, 18, 14);
        child = _buildFileContent(node, theme);
        break;
      case RvgVisualType.note:
        background =
            isSelected ? Colors.orange.shade100 : Colors.orange.shade50;
        borderColor =
            isSelected ? Colors.orange.shade700 : Colors.orange.shade200;
        borderWidth = isSelected ? 3 : 2;
        padding = const EdgeInsets.fromLTRB(18, 18, 18, 16);
        child = _buildNoteContent(node, theme);
        break;
      case RvgVisualType.external:
        background =
            isSelected ? Colors.teal.shade100 : Colors.tealAccent.shade100;
        borderColor = isSelected ? Colors.teal.shade700 : Colors.teal.shade200;
        borderWidth = isSelected ? 3 : 2;
        padding = const EdgeInsets.fromLTRB(18, 16, 18, 16);
        child = _buildExternalContent(node, theme);
        break;
      case RvgVisualType.rectangle:
      case RvgVisualType.circle:
        // Use defaults; circle handled by CircleNodeShape.
        break;
    }

    return Container(
      width: node.size.width,
      height: node.size.height,
      padding: padding,
      decoration: BoxDecoration(
        color: background,
        borderRadius: borderRadius,
        border: Border.all(color: borderColor, width: borderWidth),
      ),
      child: child,
    );
  }

  @override
  Offset anchorFor(GraphNode node, AnchorSide side) {
    final rect = Rect.fromLTWH(
      node.position.dx,
      node.position.dy,
      node.size.width,
      node.size.height,
    );
    switch (side) {
      case AnchorSide.top:
        return Offset(rect.center.dx, rect.top);
      case AnchorSide.right:
        return Offset(rect.right, rect.center.dy);
      case AnchorSide.bottom:
        return Offset(rect.center.dx, rect.bottom);
      case AnchorSide.left:
        return Offset(rect.left, rect.center.dy);
    }
  }
}

class CircleNodeShape extends GraphShapeDelegate {
  const CircleNodeShape();

  @override
  Widget buildNode(
    GraphNode node, {
    required bool isSelected,
    required ThemeData theme,
  }) {
    final double diameter = node.size.shortestSide;
    return Container(
      width: diameter,
      height: diameter,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: [
            _colorWithOpacity(Colors.indigo.shade300, isSelected ? 0.9 : 0.7),
            _colorWithOpacity(Colors.indigo.shade600, isSelected ? 0.95 : 0.8),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(
          color: isSelected ? Colors.indigoAccent : Colors.indigo.shade100,
          width: isSelected ? 4 : 2,
        ),
      ),
      alignment: Alignment.center,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: Text(
          node.label,
          textAlign: TextAlign.center,
          style:
              theme.textTheme.titleMedium?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ) ??
              const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
        ),
      ),
    );
  }

  @override
  Offset anchorFor(GraphNode node, AnchorSide side) {
    final double diameter = node.size.shortestSide;
    final Offset center = node.position + Offset(diameter / 2, diameter / 2);
    switch (side) {
      case AnchorSide.top:
        return center.translate(0, -diameter / 2);
      case AnchorSide.right:
        return center.translate(diameter / 2, 0);
      case AnchorSide.bottom:
        return center.translate(0, diameter / 2);
      case AnchorSide.left:
        return center.translate(-diameter / 2, 0);
    }
  }
}

Widget _buildDefaultRectangularContent(
  GraphNode node,
  ThemeData theme,
  bool isSelected,
) {
  final TextStyle style =
      theme.textTheme.titleMedium?.copyWith(
        color: Colors.black87,
        fontWeight: FontWeight.w600,
      ) ??
      const TextStyle(fontSize: 16, fontWeight: FontWeight.w600);
  return Center(
    child: Text(
      node.label,
      textAlign: TextAlign.center,
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
      style: style,
    ),
  );
}

Widget _buildFolderContent(GraphNode node, ThemeData theme) {
  final TextStyle titleStyle =
      theme.textTheme.titleMedium?.copyWith(
        color: Colors.amber.shade900,
        fontWeight: FontWeight.w700,
      ) ??
      TextStyle(
        color: Colors.amber.shade900,
        fontSize: 16,
        fontWeight: FontWeight.w700,
      );
  final TextStyle bodyStyle =
      theme.textTheme.bodyMedium?.copyWith(color: Colors.brown.shade600) ??
      TextStyle(color: Colors.brown.shade600, fontSize: 13);
  final String relativePath = _relativePathFor(node);

  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      Row(
        children: [
          Icon(Icons.folder, color: Colors.amber.shade700),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              node.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: titleStyle,
            ),
          ),
        ],
      ),
      const SizedBox(height: 10),
      _buildMetadataLine(
        icon: Icons.folder_open,
        iconColor: Colors.amber.shade700,
        text: relativePath,
        style: bodyStyle,
      ),
    ],
  );
}

Widget _buildFileContent(GraphNode node, ThemeData theme) {
  final TextStyle titleStyle =
      theme.textTheme.titleMedium?.copyWith(
        color: Colors.blueGrey.shade900,
        fontWeight: FontWeight.w700,
      ) ??
      TextStyle(
        color: Colors.blueGrey.shade900,
        fontSize: 16,
        fontWeight: FontWeight.w700,
      );
  final TextStyle bodyStyle =
      theme.textTheme.bodyMedium?.copyWith(color: Colors.blueGrey.shade600) ??
      TextStyle(color: Colors.blueGrey.shade600, fontSize: 13);
  final String relativePath = _relativePathFor(node);
  final String origin = (node.metadata['origin'] as String?) ?? 'manual';

  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      Row(
        children: [
          Icon(
            Icons.insert_drive_file_outlined,
            color: Colors.blueGrey.shade700,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              node.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: titleStyle,
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      _buildMetadataLine(
        icon: Icons.folder,
        iconColor: Colors.blueGrey.shade400,
        text: relativePath,
        style: bodyStyle,
      ),
      const SizedBox(height: 4),
      _buildMetadataLine(
        icon: Icons.link,
        iconColor: Colors.blueGrey.shade400,
        text: origin == 'filesystem' ? 'Synced file' : 'Linked asset',
        style: bodyStyle,
      ),
    ],
  );
}

Widget _buildNoteContent(GraphNode node, ThemeData theme) {
  final TextStyle titleStyle =
      theme.textTheme.titleMedium?.copyWith(
        color: Colors.deepOrange.shade900,
        fontWeight: FontWeight.w700,
      ) ??
      TextStyle(
        color: Colors.deepOrange.shade900,
        fontSize: 16,
        fontWeight: FontWeight.w700,
      );
  final TextStyle bodyStyle =
      theme.textTheme.bodyMedium?.copyWith(color: Colors.deepOrange.shade600) ??
      TextStyle(color: Colors.deepOrange.shade600, fontSize: 13);
  final String? noteBody = node.metadata['body'] as String?;

  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      Row(
        children: [
          Icon(Icons.sticky_note_2_outlined, color: Colors.deepOrange.shade400),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              node.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: titleStyle,
            ),
          ),
        ],
      ),
      if (noteBody != null && noteBody.trim().isNotEmpty) ...[
        const SizedBox(height: 10),
        Text(
          noteBody.trim(),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: bodyStyle,
        ),
      ],
    ],
  );
}

Widget _buildExternalContent(GraphNode node, ThemeData theme) {
  final TextStyle titleStyle =
      theme.textTheme.titleMedium?.copyWith(
        color: Colors.teal.shade900,
        fontWeight: FontWeight.w700,
      ) ??
      TextStyle(
        color: Colors.teal.shade900,
        fontSize: 16,
        fontWeight: FontWeight.w700,
      );
  final TextStyle bodyStyle =
      theme.textTheme.bodyMedium?.copyWith(color: Colors.teal.shade700) ??
      TextStyle(color: Colors.teal.shade700, fontSize: 13);
  final String source =
      node.sourcePath ??
      (node.metadata['source'] as String?) ??
      'External reference';

  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      Row(
        children: [
          Icon(Icons.public, color: Colors.teal.shade600),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              node.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: titleStyle,
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      _buildMetadataLine(
        icon: Icons.link,
        iconColor: Colors.teal.shade400,
        text: source,
        style: bodyStyle,
      ),
    ],
  );
}

Widget _buildMetadataLine({
  required IconData icon,
  required Color iconColor,
  required String text,
  required TextStyle style,
}) {
  return Row(
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      Icon(icon, size: 18, color: iconColor),
      const SizedBox(width: 6),
      Expanded(
        child: Text(
          text,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: style,
        ),
      ),
    ],
  );
}

String _relativePathFor(GraphNode node) {
  return (node.metadata['relativePath'] as String?) ?? node.label;
}

class GraphEdgePainter extends CustomPainter {
  GraphEdgePainter({
    required this.nodes,
    required this.shapeRegistry,
    required this.selectedNodeId,
  });

  final List<GraphNode> nodes;
  final Map<GraphShapeType, GraphShapeDelegate> shapeRegistry;
  final String? selectedNodeId;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint edgePaint =
        Paint()
          ..color = Colors.indigo.shade400
          ..strokeWidth = 2.4
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round;

    final Paint arrowPaint =
        Paint()
          ..color = Colors.indigo.shade500
          ..style = PaintingStyle.fill;

    final Map<String, GraphNode> nodeById = {
      for (final node in nodes) node.id: node,
    };

    for (final node in nodes) {
      final bool isSourceSelected = node.id == selectedNodeId;
      edgePaint.color =
          isSourceSelected ? Colors.indigo.shade700 : Colors.indigo.shade400;

      for (final targetId in node.connections) {
        final targetNode = nodeById[targetId];
        if (targetNode == null) continue;

        final AnchorPair pair = _resolveAnchors(node, targetNode);
        final GraphShapeDelegate? sourceShape = shapeRegistry[node.shape];
        final GraphShapeDelegate? targetShape = shapeRegistry[targetNode.shape];

        if (sourceShape == null || targetShape == null) continue;

        final Offset start = sourceShape.anchorFor(node, pair.start);
        final Offset end = targetShape.anchorFor(targetNode, pair.end);

        _drawArrow(canvas, start, end, edgePaint, arrowPaint);
      }
    }
  }

  void _drawArrow(
    Canvas canvas,
    Offset start,
    Offset end,
    Paint linePaint,
    Paint headPaint,
  ) {
    final Offset direction = end - start;
    final double distance = direction.distance;
    if (distance < 8) {
      return;
    }

    final Offset unit = Offset(
      direction.dx / distance,
      direction.dy / distance,
    );
    const double arrowHeadLength = 16;
    const double arrowHeadWidth = 10;
    final Offset adjustedEnd = end - unit * arrowHeadLength * 0.6;

    final Path linePath =
        Path()
          ..moveTo(start.dx, start.dy)
          ..lineTo(adjustedEnd.dx, adjustedEnd.dy);
    canvas.drawPath(linePath, linePaint);

    final Offset perpendicular = Offset(-unit.dy, unit.dx);
    final Offset tip = end;
    final Offset base = end - unit * arrowHeadLength;
    final Offset left = base + perpendicular * (arrowHeadWidth / 2);
    final Offset right = base - perpendicular * (arrowHeadWidth / 2);

    final Path arrowHead =
        Path()
          ..moveTo(tip.dx, tip.dy)
          ..lineTo(left.dx, left.dy)
          ..lineTo(right.dx, right.dy)
          ..close();
    canvas.drawPath(arrowHead, headPaint);
  }

  AnchorPair _resolveAnchors(GraphNode from, GraphNode to) {
    final Offset fromCenter = _nodeCenter(from);
    final Offset toCenter = _nodeCenter(to);
    final Offset delta = toCenter - fromCenter;

    final double horizontalBias = delta.dx.abs();
    final double verticalBias = delta.dy.abs();

    if (horizontalBias > verticalBias * 1.1) {
      final AnchorSide fromSide =
          delta.dx >= 0 ? AnchorSide.right : AnchorSide.left;
      final AnchorSide toSide =
          delta.dx >= 0 ? AnchorSide.left : AnchorSide.right;
      return AnchorPair(fromSide, toSide);
    }

    if (verticalBias > horizontalBias * 1.1) {
      final AnchorSide fromSide =
          delta.dy >= 0 ? AnchorSide.bottom : AnchorSide.top;
      final AnchorSide toSide =
          delta.dy >= 0 ? AnchorSide.top : AnchorSide.bottom;
      return AnchorPair(fromSide, toSide);
    }

    // Near-diagonal: prefer the longer axis but bias towards direction.
    if (delta.dx >= 0 && delta.dy >= 0) {
      return const AnchorPair(AnchorSide.bottom, AnchorSide.top);
    } else if (delta.dx >= 0 && delta.dy < 0) {
      return const AnchorPair(AnchorSide.right, AnchorSide.left);
    } else if (delta.dx < 0 && delta.dy >= 0) {
      return const AnchorPair(AnchorSide.left, AnchorSide.right);
    } else {
      return const AnchorPair(AnchorSide.top, AnchorSide.bottom);
    }
  }

  Offset _nodeCenter(GraphNode node) {
    return node.position + Offset(node.size.width / 2, node.size.height / 2);
  }

  @override
  bool shouldRepaint(covariant GraphEdgePainter oldDelegate) {
    return !listEquals(oldDelegate.nodes, nodes) ||
        oldDelegate.selectedNodeId != selectedNodeId;
  }
}

class GraphBackgroundPainter extends CustomPainter {
  const GraphBackgroundPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final Paint majorLinePaint =
        Paint()
          ..color = _colorWithOpacity(Colors.indigo, 0.08)
          ..strokeWidth = 1.4;
    final Paint minorLinePaint =
        Paint()
          ..color = _colorWithOpacity(Colors.indigo, 0.04)
          ..strokeWidth = 1;

    const double majorSpacing = 200;
    const double minorSpacing = 50;

    for (double x = 0; x <= size.width; x += minorSpacing) {
      final bool isMajor =
          (x / minorSpacing) % (majorSpacing / minorSpacing) == 0;
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        isMajor ? majorLinePaint : minorLinePaint,
      );
    }

    for (double y = 0; y <= size.height; y += minorSpacing) {
      final bool isMajor =
          (y / minorSpacing) % (majorSpacing / minorSpacing) == 0;
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        isMajor ? majorLinePaint : minorLinePaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class GraphUndoManager {
  GraphUndoManager({this.capacity = 50});

  final int capacity;
  final List<RvgDocument> _undoStack = <RvgDocument>[];
  final List<RvgDocument> _redoStack = <RvgDocument>[];

  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;

  void push(RvgDocument snapshot) {
    if (_undoStack.length == capacity) {
      _undoStack.removeAt(0);
    }
    _undoStack.add(snapshot);
    _redoStack.clear();
  }

  RvgDocument? undo(RvgDocument current) {
    if (_undoStack.isEmpty) {
      return null;
    }
    final RvgDocument previous = _undoStack.removeLast();
    _redoStack.add(current);
    return previous;
  }

  RvgDocument? redo(RvgDocument current) {
    if (_redoStack.isEmpty) {
      return null;
    }
    final RvgDocument next = _redoStack.removeLast();
    _undoStack.add(current);
    return next;
  }

  void reset() {
    _undoStack.clear();
    _redoStack.clear();
  }
}

Color _colorWithOpacity(Color color, double opacity) {
  final double boundedOpacity = opacity.clamp(0.0, 1.0);
  final int alpha = (boundedOpacity * 255).round();
  return color.withAlpha(alpha);
}
