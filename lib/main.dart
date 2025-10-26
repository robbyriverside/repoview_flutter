import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:repoview_flutter/rvg/rvg_models.dart';
import 'package:repoview_flutter/rvg/rvg_persistence_service.dart';
import 'package:repoview_flutter/rvg/rvg_types.dart';
import 'package:repoview_flutter/rvg/rvg_sync_service.dart';
import 'package:repoview_flutter/services/file_preview_cache.dart';

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
  static const Set<String> _imageExtensions = <String>{
    '.png',
    '.jpg',
    '.jpeg',
    '.gif',
    '.bmp',
    '.webp',
  };
  static const Set<String> _markdownExtensions = <String>{
    '.md',
    '.markdown',
    '.mdown',
    '.mdx',
  };
  static const Set<String> _textExtensions = <String>{
    '.txt',
    '.json',
    '.yaml',
    '.yml',
    '.csv',
    '.tsv',
    '.dart',
    '.js',
    '.ts',
    '.jsx',
    '.tsx',
    '.java',
    '.kt',
    '.kts',
    '.swift',
    '.py',
    '.rb',
    '.go',
    '.rs',
    '.c',
    '.cc',
    '.cpp',
    '.h',
    '.hpp',
    '.cs',
    '.sh',
    '.bat',
    '.ps1',
  };

  late final RvgPersistenceService _persistenceService;
  late final GraphUndoManager _undoManager;
  late final File _documentFile;
  late final Directory _workspaceRoot;
  late final RvgSyncService _syncService;
  late final FilePreviewCache _previewCache;
  late final Map<GraphShapeType, GraphShapeDelegate> _shapeRegistry;
  late RvgDocument _document;
  late List<GraphNode> _nodes;
  String? _selectedNodeId;
  bool _isSyncing = false;
  StreamSubscription<FileSystemEvent>? _watchSubscription;
  Timer? _syncDebounce;
  RvgDocument? _dragSnapshot;
  final Map<String, CachedPreview?> _nodePreviews = <String, CachedPreview?>{};
  final Set<String> _previewRequests = <String>{};
  late final Map<RvgVisualType, String> _typeDefaultViews;

  @override
  void initState() {
    super.initState();
    _persistenceService = const RvgPersistenceService();
    _undoManager = GraphUndoManager(capacity: 50);
    _syncService = const RvgSyncService();
    _previewCache = FilePreviewCache(maxEntries: 150);
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
    _typeDefaultViews = <RvgVisualType, String>{
      RvgVisualType.file: FileNodeView.preview.id,
      RvgVisualType.folder: FolderNodeView.summary.id,
      RvgVisualType.rectangle: RectangleNodeView.standard.id,
      RvgVisualType.circle: CircleNodeView.standard.id,
      RvgVisualType.external: RectangleNodeView.standard.id,
      RvgVisualType.note: RectangleNodeView.standard.id,
    };
    unawaited(_bootstrapWorkspace());
  }

  @override
  void dispose() {
    _watchSubscription?.cancel();
    _syncDebounce?.cancel();
    _previewCache.clear();
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
    _ensurePreview(node);
    final CachedPreview? preview = _nodePreviews[node.id];
    final List<NodeViewOption> viewOptions = _viewOptionsFor(node, preview);
    if (viewOptions.isEmpty) {
      return const SizedBox.shrink();
    }
    final NodeViewOption activeView = _resolveActiveView(node, viewOptions);

    return Positioned(
      left: node.position.dx,
      top: node.position.dy,
      child: GestureDetector(
        onPanStart: (_) => _beginNodeDrag(),
        onPanEnd: (_) => _endNodeDrag(),
        onTap: () => _handleNodeTap(node),
        onDoubleTap: () => unawaited(_cycleNodeView(node, preview)),
        onSecondaryTapUp:
            (details) => unawaited(
              _showViewMenu(node, preview, activeView, details.globalPosition),
            ),
        onPanUpdate: (details) => _handleNodePan(node.id, details.delta),
        child: _buildNodeShadow(
          node: node,
          isCircle: isCircle,
          child: delegate.buildNode(
            context,
            node,
            isSelected: node.id == _selectedNodeId,
            theme: theme,
            preview: preview,
            view: activeView,
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
      _previewCache.clear();
      _nodePreviews.clear();
      _previewRequests.clear();
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
      _cleanupMissingPreviews(_nodes);
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

  void _ensurePreview(GraphNode node) {
    if (node.visualType != RvgVisualType.file) {
      return;
    }
    if (_nodePreviews.containsKey(node.id) ||
        _previewRequests.contains(node.id)) {
      return;
    }
    final String? absolutePath = _resolveNodeAbsolutePath(node);
    if (absolutePath == null) {
      _nodePreviews[node.id] = null;
      return;
    }
    final String extension = p.extension(absolutePath).toLowerCase();
    final File file = File(absolutePath);
    Future<CachedPreview?>? future;
    if (_imageExtensions.contains(extension)) {
      future = _previewCache.getImagePreview(file);
    } else if (_markdownExtensions.contains(extension)) {
      future = _previewCache.getMarkdownPreview(file);
    } else if (_textExtensions.contains(extension)) {
      future = _previewCache.getTextPreview(file, maxLength: 6000);
    } else {
      _nodePreviews[node.id] = null;
      return;
    }

    _previewRequests.add(node.id);
    future
        .then((CachedPreview? preview) {
          if (!mounted) {
            return;
          }
          setState(() {
            _nodePreviews[node.id] = preview;
          });
        })
        .catchError((Object error, StackTrace stackTrace) {
          debugPrint('Preview load failed for ${node.id}: $error');
          debugPrint('$stackTrace');
        })
        .whenComplete(() {
          _previewRequests.remove(node.id);
        });
  }

  String? _resolveNodeAbsolutePath(GraphNode node) {
    if (node.sourcePath != null && node.sourcePath!.isNotEmpty) {
      return node.sourcePath;
    }
    final String? relative = node.metadata['relativePath'] as String?;
    if (relative == null) {
      return null;
    }
    return p.join(_workspaceRoot.path, relative);
  }

  void _cleanupMissingPreviews(List<GraphNode> nodes) {
    final Set<String> ids = nodes.map((GraphNode node) => node.id).toSet();
    _nodePreviews.removeWhere((String key, CachedPreview? value) {
      return !ids.contains(key);
    });
    _previewRequests.removeWhere((String key) => !ids.contains(key));
  }

  List<NodeViewOption> _viewOptionsFor(GraphNode node, CachedPreview? preview) {
    List<NodeViewOption> candidates;
    switch (node.visualType) {
      case RvgVisualType.file:
        candidates = FileNodeView.all;
        break;
      case RvgVisualType.folder:
        candidates = FolderNodeView.all;
        break;
      case RvgVisualType.circle:
        candidates = const <NodeViewOption>[CircleNodeView.standard];
        break;
      default:
        candidates = const <NodeViewOption>[RectangleNodeView.standard];
        break;
    }
    return <NodeViewOption>[
      for (final NodeViewOption option in candidates)
        if (option.supports == null || option.supports!(node, preview)) option,
    ];
  }

  NodeViewOption _resolveActiveView(
    GraphNode node,
    List<NodeViewOption> options,
  ) {
    NodeViewOption? byId(String? id) {
      if (id == null) return null;
      for (final NodeViewOption option in options) {
        if (option.id == id) {
          return option;
        }
      }
      return null;
    }

    final NodeViewOption? stored = byId(node.metadata['activeView'] as String?);
    if (stored != null) {
      return stored;
    }

    final NodeViewOption? typeDefault = byId(
      _typeDefaultViews[node.visualType],
    );
    if (typeDefault != null) {
      return typeDefault;
    }

    return options.first;
  }

  Future<void> _cycleNodeView(GraphNode node, CachedPreview? preview) async {
    final List<NodeViewOption> options = _viewOptionsFor(node, preview);
    if (options.length <= 1) {
      return;
    }
    final NodeViewOption current = _resolveActiveView(node, options);
    final int index = options.indexOf(current);
    final NodeViewOption next = options[(index + 1) % options.length];
    await _selectNodeView(node, next, preview: preview);
  }

  Future<void> _showViewMenu(
    GraphNode node,
    CachedPreview? preview,
    NodeViewOption activeView,
    Offset position,
  ) async {
    final List<NodeViewOption> options = _viewOptionsFor(node, preview);
    final String? selection = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: [
        for (final NodeViewOption option in options)
          PopupMenuItem<String>(
            value: 'view:${option.id}',
            child: Row(
              children: [
                if (option.id == activeView.id)
                  const Icon(Icons.check, size: 16)
                else
                  const SizedBox(width: 16),
                const SizedBox(width: 8),
                Text(option.label),
              ],
            ),
          ),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          value: 'set-default:${activeView.id}',
          child: Text('Set "${activeView.label}" as default'),
        ),
        PopupMenuItem<String>(
          value: 'open-window:${activeView.id}',
          enabled: activeView.requiresWindow,
          child: const Text('Open view in window'),
        ),
      ],
    );
    if (selection == null) {
      return;
    }
    if (selection.startsWith('view:')) {
      final String id = selection.substring('view:'.length);
      final NodeViewOption option = options.firstWhere(
        (o) => o.id == id,
        orElse: () => activeView,
      );
      await _selectNodeView(node, option, preview: preview);
    } else if (selection.startsWith('set-default:')) {
      final String id = selection.substring('set-default:'.length);
      final NodeViewOption option = options.firstWhere(
        (o) => o.id == id,
        orElse: () => activeView,
      );
      setState(() {
        _typeDefaultViews[node.visualType] = option.id;
      });
      await _selectNodeView(
        node,
        option,
        preview: preview,
        setTypeDefault: true,
      );
    } else if (selection.startsWith('open-window:')) {
      await _openViewWindow(node);
    }
  }

  Future<void> _selectNodeView(
    GraphNode node,
    NodeViewOption option, {
    CachedPreview? preview,
    bool setTypeDefault = false,
    bool recordUndo = true,
  }) async {
    final RvgDocument updated = _document.updateNode(node.id, (
      RvgNode original,
    ) {
      final Map<String, dynamic> metadata = Map<String, dynamic>.from(
        original.metadata,
      );
      metadata['activeView'] = option.id;
      return original.copyWith(metadata: metadata);
    });

    final bool changed = !identical(updated, _document);
    if (changed) {
      _commitDocument(updated, recordUndo: recordUndo);
    } else if (setTypeDefault) {
      setState(() {});
    }

    if (setTypeDefault) {
      setState(() {
        _typeDefaultViews[node.visualType] = option.id;
      });
    }

    if (option.requiresWindow) {
      await _openViewWindow(node);
    }
  }

  Future<void> _openViewWindow(GraphNode node) async {
    final String? absolutePath = _resolveNodeAbsolutePath(node);
    if (absolutePath == null) {
      return;
    }
    final File file = File(absolutePath);
    if (!await file.exists()) {
      return;
    }

    final String extension = p.extension(absolutePath).toLowerCase();
    Widget content;
    if (_imageExtensions.contains(extension)) {
      content = InteractiveViewer(
        minScale: 0.2,
        maxScale: 4,
        child: Image.file(file, fit: BoxFit.contain),
      );
    } else {
      String data;
      try {
        data = await file.readAsString();
      } catch (error) {
        data = 'Unable to load file: $error';
      }
      content = Scrollbar(
        thumbVisibility: true,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: SelectableText(data),
        ),
      );
    }

    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return Dialog(
          child: SizedBox(
            width: 720,
            height: 540,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    node.label,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const Divider(height: 1),
                Expanded(child: content),
              ],
            ),
          ),
        );
      },
    );
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
    BuildContext context,
    GraphNode node, {
    required bool isSelected,
    required ThemeData theme,
    CachedPreview? preview,
    required NodeViewOption view,
  });

  Offset anchorFor(GraphNode node, AnchorSide side);
}

class RectangleNodeShape extends GraphShapeDelegate {
  const RectangleNodeShape();

  @override
  Widget buildNode(
    BuildContext context,
    GraphNode node, {
    required bool isSelected,
    required ThemeData theme,
    CachedPreview? preview,
    required NodeViewOption view,
  }) {
    Color background = isSelected ? Colors.indigo.shade50 : Colors.white;
    Color borderColor = isSelected ? Colors.indigo : Colors.grey.shade400;
    double borderWidth = isSelected ? 3 : 1.6;
    EdgeInsets padding = const EdgeInsets.all(16);
    BorderRadius borderRadius = BorderRadius.circular(14);
    Widget child = _buildDefaultRectangularContent(node, theme, isSelected);

    if (node.visualType == RvgVisualType.folder) {
      background = isSelected ? Colors.amber.shade100 : Colors.amber.shade50;
      borderColor = isSelected ? Colors.amber.shade700 : Colors.amber.shade200;
      borderWidth = isSelected ? 3 : 2;
      padding = const EdgeInsets.fromLTRB(18, 16, 18, 14);
      child = _buildFolderContent(node, theme, view.id);
    } else if (node.visualType == RvgVisualType.file) {
      background =
          isSelected ? Colors.blueGrey.shade100 : Colors.blueGrey.shade50;
      borderColor =
          isSelected ? Colors.blueGrey.shade700 : Colors.blueGrey.shade200;
      borderWidth = isSelected ? 3 : 1.8;
      padding = const EdgeInsets.fromLTRB(18, 14, 18, 14);
      child = _buildFileContent(node, theme, view, preview);
    } else if (node.visualType == RvgVisualType.note) {
      background = isSelected ? Colors.orange.shade100 : Colors.orange.shade50;
      borderColor =
          isSelected ? Colors.orange.shade700 : Colors.orange.shade200;
      borderWidth = isSelected ? 3 : 2;
      padding = const EdgeInsets.fromLTRB(18, 18, 18, 16);
      child = _buildNoteContent(node, theme);
    } else if (node.visualType == RvgVisualType.external) {
      background =
          isSelected ? Colors.teal.shade100 : Colors.tealAccent.shade100;
      borderColor = isSelected ? Colors.teal.shade700 : Colors.teal.shade200;
      borderWidth = isSelected ? 3 : 2;
      padding = const EdgeInsets.fromLTRB(18, 16, 18, 16);
      child = _buildExternalContent(node, theme);
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
    BuildContext context,
    GraphNode node, {
    required bool isSelected,
    required ThemeData theme,
    CachedPreview? preview,
    required NodeViewOption view,
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

Widget _buildFolderContent(GraphNode node, ThemeData theme, String viewId) {
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
  final int? itemCount = (node.metadata['itemCount'] as num?)?.toInt();
  final List<String> sampleChildren =
      ((node.metadata['sampleChildren'] as List?) ?? const <dynamic>[])
          .cast<String>();

  if (viewId == FolderNodeView.children.id) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Contents', style: titleStyle),
        const SizedBox(height: 8),
        Expanded(
          child:
              sampleChildren.isEmpty
                  ? Center(child: Text('No items found', style: bodyStyle))
                  : ListView.separated(
                    physics: const BouncingScrollPhysics(),
                    itemCount: sampleChildren.length,
                    itemBuilder: (BuildContext context, int index) {
                      return Text(
                        sampleChildren[index],
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: bodyStyle,
                      );
                    },
                    separatorBuilder: (_, __) => const Divider(height: 8),
                  ),
        ),
      ],
    );
  }

  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
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
      const SizedBox(height: 8),
      _buildMetadataLine(
        icon: Icons.folder_open,
        iconColor: Colors.amber.shade700,
        text: relativePath,
        style: bodyStyle,
      ),
      if (itemCount != null) ...[
        const SizedBox(height: 4),
        _buildMetadataLine(
          icon: Icons.inventory_2,
          iconColor: Colors.amber.shade400,
          text: '$itemCount item${itemCount == 1 ? '' : 's'}',
          style: bodyStyle,
        ),
      ],
      if (sampleChildren.isNotEmpty) ...[
        const SizedBox(height: 6),
        Flexible(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children:
                  sampleChildren
                      .map(
                        (String name) => Chip(
                          label: Text(name, style: bodyStyle),
                          backgroundColor: Colors.amber.shade100,
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          visualDensity: VisualDensity.compact,
                          side: BorderSide(
                            color: Colors.amber.shade300,
                            width: 0.5,
                          ),
                        ),
                      )
                      .toList(),
            ),
          ),
        ),
      ],
    ],
  );
}

Widget _buildFileContent(
  GraphNode node,
  ThemeData theme,
  NodeViewOption view,
  CachedPreview? preview,
) {
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
  final int? sizeBytes = (node.metadata['sizeBytes'] as num?)?.toInt();

  if (view.id == FileNodeView.details.id) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Details', style: titleStyle),
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
        if (sizeBytes != null) ...[
          const SizedBox(height: 4),
          _buildMetadataLine(
            icon: Icons.data_object,
            iconColor: Colors.blueGrey.shade300,
            text: _formatSize(sizeBytes),
            style: bodyStyle,
          ),
        ],
        const SizedBox(height: 4),
        _buildMetadataLine(
          icon: Icons.description_outlined,
          iconColor: Colors.blueGrey.shade300,
          text: 'Extension: ${node.metadata['extension'] ?? 'unknown'}',
          style: bodyStyle,
        ),
      ],
    );
  }

  if (view.id == FileNodeView.full.id) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Full View', style: titleStyle),
        const SizedBox(height: 8),
        Text('Open full content from the context menu.', style: bodyStyle),
      ],
    );
  }

  final Widget header = Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
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
      if (sizeBytes != null) ...[
        const SizedBox(height: 4),
        _buildMetadataLine(
          icon: Icons.data_object,
          iconColor: Colors.blueGrey.shade300,
          text: _formatSize(sizeBytes),
          style: bodyStyle,
        ),
      ],
    ],
  );

  if (view.id == FileNodeView.summary.id || preview == null) {
    return header;
  }

  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      header,
      const SizedBox(height: 8),
      Expanded(child: _buildPreviewWidget(preview, theme)),
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

Widget _buildPreviewWidget(CachedPreview preview, ThemeData theme) {
  if (preview.type == PreviewType.image) {
    if (preview.data == null) {
      return const SizedBox.shrink();
    }
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: SizedBox.expand(
            child: Image.memory(
              preview.data!,
              fit: BoxFit.cover,
              filterQuality: FilterQuality.medium,
            ),
          ),
        );
      },
    );
  }

  if (preview.type == PreviewType.markdown ||
      preview.type == PreviewType.text) {
    final String snippet = _formatPreviewText(preview.text ?? '');
    if (snippet.isEmpty) {
      return const SizedBox.shrink();
    }
    final TextStyle style =
        theme.textTheme.bodyMedium?.copyWith(
          color: Colors.blueGrey.shade800,
          fontFamily: 'monospace',
          height: 1.3,
        ) ??
        TextStyle(
          color: Colors.blueGrey.shade800,
          fontFamily: 'monospace',
          height: 1.3,
        );
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.blueGrey.shade50,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.blueGrey.shade100, width: 1),
      ),
      child: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        child: Text(
          snippet,
          maxLines: 6,
          overflow: TextOverflow.ellipsis,
          softWrap: true,
          style: style,
        ),
      ),
    );
  }

  return const SizedBox.shrink();
}

String _formatPreviewText(String raw) {
  if (raw.isEmpty) {
    return raw;
  }
  final List<String> lines =
      raw
          .replaceAll('\r\n', '\n')
          .split('\n')
          .map((String line) {
            String trimmed = line.trim();
            trimmed = trimmed.replaceFirst(RegExp(r'^#{1,6}\s*'), '');
            trimmed = trimmed.replaceFirst(RegExp(r'^[-*+]\s+'), '• ');
            return trimmed;
          })
          .where((String line) => line.isNotEmpty)
          .take(8)
          .toList();
  String combined = lines.join('\n');
  if (combined.length > 400) {
    combined = '${combined.substring(0, 400)}…';
  }
  return combined;
}

String _formatSize(int bytes) {
  const List<String> units = <String>['B', 'KB', 'MB', 'GB', 'TB'];
  double value = bytes.toDouble();
  int unitIndex = 0;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex += 1;
  }
  final String formatted =
      unitIndex == 0 ? value.toStringAsFixed(0) : value.toStringAsFixed(1);
  return '$formatted ${units[unitIndex]}';
}

class NodeViewOption {
  const NodeViewOption({
    required this.id,
    required this.label,
    this.requiresWindow = false,
    this.supports,
  });

  final String id;
  final String label;
  final bool requiresWindow;
  final bool Function(GraphNode node, CachedPreview? preview)? supports;
}

class FileNodeView {
  static const NodeViewOption preview = NodeViewOption(
    id: 'file.preview',
    label: 'Preview',
    supports: _supportsPreview,
  );
  static const NodeViewOption summary = NodeViewOption(
    id: 'file.summary',
    label: 'Summary',
  );
  static const NodeViewOption details = NodeViewOption(
    id: 'file.details',
    label: 'Details',
  );
  static const NodeViewOption full = NodeViewOption(
    id: 'file.full',
    label: 'Full Content',
    requiresWindow: true,
  );

  static bool _supportsPreview(GraphNode node, CachedPreview? preview) {
    return preview != null;
  }

  static const List<NodeViewOption> all = <NodeViewOption>[
    preview,
    summary,
    details,
    full,
  ];
}

class FolderNodeView {
  static const NodeViewOption summary = NodeViewOption(
    id: 'folder.summary',
    label: 'Summary',
  );
  static const NodeViewOption children = NodeViewOption(
    id: 'folder.children',
    label: 'Child List',
    supports: _supportsChildren,
  );

  static bool _supportsChildren(GraphNode node, CachedPreview? preview) {
    final dynamic sample = node.metadata['sampleChildren'];
    return sample is List && sample.isNotEmpty;
  }

  static const List<NodeViewOption> all = <NodeViewOption>[summary, children];
}

class RectangleNodeView {
  static const NodeViewOption standard = NodeViewOption(
    id: 'rect.standard',
    label: 'Standard',
  );
}

class CircleNodeView {
  static const NodeViewOption standard = NodeViewOption(
    id: 'circle.standard',
    label: 'Standard',
  );
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
