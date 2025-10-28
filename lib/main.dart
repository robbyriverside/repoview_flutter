import 'dart:async';
import 'dart:io';

import 'package:cross_file/cross_file.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:repoview_flutter/rvg/rvg_models.dart';
import 'package:repoview_flutter/rvg/rvg_persistence_service.dart';
import 'package:repoview_flutter/rvg/rvg_types.dart';
import 'package:repoview_flutter/rvg/rvg_sync_service.dart';
import 'package:repoview_flutter/services/ai_assistant_service.dart';
import 'package:repoview_flutter/services/automation_manager.dart';
import 'package:repoview_flutter/services/file_preview_cache.dart';
import 'package:repoview_flutter/services/git_status_service.dart';
import 'package:repoview_flutter/services/layout_formatter_service.dart';
import 'package:repoview_flutter/services/rvg_merge_service.dart';
import 'package:repoview_flutter/services/rvg_template_service.dart';
import 'package:repoview_flutter/services/telemetry_service.dart';

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
  static const Duration _gitRefreshInterval = Duration(seconds: 8);
  static const Duration _remoteRefreshInterval = Duration(minutes: 2);

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
  final GitStatusService _gitStatusService = const GitStatusService();
  final RvgMergeService _mergeService = const RvgMergeService();
  final LayoutFormatterService _layoutService = const LayoutFormatterService();
  final AiAssistantService _aiService = const AiAssistantService();
  late final RvgTemplateService _templateService;
  late final RvgTemplateProvider _templateProvider;
  late final AutomationManager _automationManager;
  late TelemetryService _telemetry;
  GitStatusSnapshot? _gitSnapshot;
  Timer? _gitStatusTimer;
  GitRemoteStatus? _remoteStatus;
  Timer? _remoteStatusTimer;
  bool _isCommitInFlight = false;
  bool _isFetchingRemote = false;
  bool _isHistoryVisible = false;
  bool _isLoadingHistory = false;
  bool _isMergeSummaryLoading = false;
  List<GitCommit> _commitHistory = const <GitCommit>[];
  bool _isTelemetryVisible = false;
  List<TelemetryEvent> _telemetryEvents = const <TelemetryEvent>[];
  bool _isDropHovering = false;
  final TransformationController _viewController = TransformationController();
  final GlobalKey _interactiveViewerKey = GlobalKey();

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
    _templateService = const RvgTemplateService();
    _templateProvider = RvgTemplateProvider(
      templates: <String, RvgDocument>{
        for (final RvgTemplate template in _templateService.templates)
          template.id: template.document,
      },
    );
    _automationManager = AutomationManager(templateProvider: _templateProvider);
    _telemetry = TelemetryService(
      sink: File(p.join(_workspaceRoot.path, '.repoview_telemetry.jsonl')),
    );
    _shapeRegistry = {
      GraphShapeType.rectangle: const RectangleNodeShape(),
      GraphShapeType.circle: const RectangleNodeShape(),
    };
    _document = RvgDocument.demo();
    _nodes = _document.nodes.map(GraphNode.fromRvgNode).toList();
    _typeDefaultViews = <RvgVisualType, String>{
      RvgVisualType.file: WindowNodeView.shrinkable.id,
      RvgVisualType.folder: WindowNodeView.scrollable.id,
      RvgVisualType.rectangle: WindowNodeView.shrinkable.id,
      RvgVisualType.circle: WindowNodeView.shrinkable.id,
      RvgVisualType.external: WindowNodeView.icon.id,
      RvgVisualType.note: WindowNodeView.shrinkable.id,
    };
    _gitStatusTimer = Timer.periodic(
      _gitRefreshInterval,
      (_) => unawaited(_refreshGitStatus()),
    );
    _remoteStatusTimer = Timer.periodic(
      _remoteRefreshInterval,
      (_) => unawaited(_refreshRemoteStatus()),
    );
    unawaited(_refreshGitStatus());
    unawaited(_refreshRemoteStatus());
    unawaited(_bootstrapWorkspace());
    _telemetryEvents = _telemetry.recent();
  }

  @override
  void dispose() {
    _watchSubscription?.cancel();
    _syncDebounce?.cancel();
    _gitStatusTimer?.cancel();
    _remoteStatusTimer?.cancel();
    _previewCache.clear();
    unawaited(_telemetry.close());
    _viewController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _buildAppBarTitle(),
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
          IconButton(
            tooltip: 'Apply layout',
            icon: const Icon(Icons.auto_graph),
            onPressed: () => unawaited(_showLayoutPicker()),
          ),
          const SizedBox(width: 8),
          PopupMenuButton<String>(
            tooltip: 'Templates',
            icon: const Icon(Icons.layers),
            itemBuilder: (BuildContext context) {
              return _templateService.templates
                  .map(
                    (RvgTemplate template) => PopupMenuItem<String>(
                      value: template.id,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            template.label,
                            style: Theme.of(context).textTheme.bodyLarge
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            template.description,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  )
                  .toList();
            },
            onSelected: (String id) => unawaited(_handleTemplateSelection(id)),
          ),
          const SizedBox(width: 8),
          PopupMenuButton<String>(
            tooltip: 'Automations',
            icon: const Icon(Icons.auto_fix_high),
            itemBuilder: (BuildContext context) {
              return _automationManager.scripts
                  .map(
                    (AutomationDescriptor descriptor) => PopupMenuItem<String>(
                      value: descriptor.id,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            descriptor.label,
                            style: Theme.of(context).textTheme.bodyLarge
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            descriptor.description,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  )
                  .toList();
            },
            onSelected: (String id) => unawaited(_runAutomationScript(id)),
          ),
          IconButton(
            tooltip: 'Commit staged changes',
            icon:
                _isCommitInFlight
                    ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2.2),
                    )
                    : const Icon(Icons.commit),
            onPressed:
                _gitSnapshot == null || !_canCommit()
                    ? null
                    : () => _handleCommitPressed(),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip:
                _isTelemetryVisible ? 'Hide activity log' : 'Show activity log',
            icon: const Icon(Icons.bar_chart),
            onPressed:
                () => setState(() {
                  _isTelemetryVisible = !_isTelemetryVisible;
                  if (_isTelemetryVisible) {
                    _telemetryEvents = _telemetry.recent();
                  }
                }),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip:
                _isFetchingRemote
                    ? 'Fetching remote metadata...'
                    : 'Fetch remote and refresh remote status',
            icon: Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(
                  _remoteStatus?.hasDivergence == true
                      ? Icons.cloud_sync
                      : Icons.cloud_outlined,
                ),
                if ((_remoteStatus?.behind ?? 0) > 0)
                  Positioned(
                    right: -4,
                    top: -4,
                    child: _buildStatusDot(color: Colors.orange.shade600),
                  ),
              ],
            ),
            onPressed:
                _isFetchingRemote ? null : () => unawaited(_handleRemoteSync()),
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
          IconButton(
            tooltip:
                _isHistoryVisible
                    ? 'Hide commit history'
                    : 'Show commit history',
            icon: const Icon(Icons.history),
            onPressed: () => unawaited(_toggleCommitHistory()),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: DropTarget(
        onDragEntered: (details) {
          setState(() {
            _isDropHovering = true;
          });
        },
        onDragExited: (details) {
          setState(() {
            _isDropHovering = false;
          });
        },
        onDragDone: (details) => unawaited(_handleDrop(details)),
        child: Stack(
          children: [
            InteractiveViewer(
              key: _interactiveViewerKey,
              transformationController: _viewController,
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
            if (_isHistoryVisible) _buildCommitHistoryPanel(),
            if (_shouldShowRemoteBanner) _buildRemotePresenceBanner(),
            if (_isTelemetryVisible) _buildTelemetryPanel(),
            if (_isDropHovering) _buildDropOverlay(),
          ],
        ),
      ),
    );
  }

  Widget _buildAppBarTitle() {
    final String? branch = _gitSnapshot?.branch;
    if (branch == null || branch.isEmpty) {
      return const Text('Graph Connectivity Playground');
    }

    final int dirtyCount = _dirtyGitChangeCount();
    final bool hasChanges = dirtyCount > 0;
    final Color branchColor = Colors.indigo.shade500;
    final Color statusColor =
        hasChanges ? Colors.orange.shade600 : Colors.green.shade600;
    final Color backgroundColor =
        hasChanges ? Colors.orange.shade50 : Colors.green.shade50;
    final Color borderColor =
        hasChanges ? Colors.orange.shade200 : Colors.green.shade200;
    final String tooltip =
        hasChanges
            ? '$dirtyCount pending change${dirtyCount == 1 ? '' : 's'}'
            : 'Working tree clean';

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('Graph Connectivity Playground'),
        const SizedBox(width: 16),
        Tooltip(
          message: 'Branch $branch • $tooltip',
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: backgroundColor,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: borderColor),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.merge_type, size: 16, color: branchColor),
                const SizedBox(width: 6),
                Text(
                  branch,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: branchColor,
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  hasChanges ? Icons.change_circle : Icons.check_circle,
                  size: 16,
                  color: statusColor,
                ),
                if (hasChanges) ...[
                  const SizedBox(width: 4),
                  Text(
                    '$dirtyCount',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: statusColor,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  bool get _shouldShowRemoteBanner =>
      _remoteStatus != null && (_remoteStatus!.behind > 0);

  Widget _buildStatusDot({required Color color, double size = 12}) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 1.5),
      ),
    );
  }

  Widget _buildCommitHistoryPanel() {
    final ThemeData theme = Theme.of(context);
    return Positioned(
      top: 16,
      right: 16,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340, maxHeight: 420),
        child: Material(
          elevation: 8,
          borderRadius: BorderRadius.circular(16),
          color: theme.colorScheme.surface,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 8, 6),
                child: Row(
                  children: [
                    Text(
                      'Commit history',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: 'Refresh history',
                      icon: const Icon(Icons.refresh),
                      onPressed:
                          _isLoadingHistory
                              ? null
                              : () => unawaited(_loadCommitHistory()),
                    ),
                    IconButton(
                      tooltip: 'Close history',
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        setState(() {
                          _isHistoryVisible = false;
                        });
                      },
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              if (_isLoadingHistory)
                const Expanded(
                  child: Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: CircularProgressIndicator(),
                    ),
                  ),
                )
              else if (_commitHistory.isEmpty)
                const Expanded(
                  child: Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('No commits available.'),
                    ),
                  ),
                )
              else
                Expanded(
                  child: Scrollbar(
                    thumbVisibility: true,
                    child: ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                      itemCount: _commitHistory.length,
                      separatorBuilder: (_, __) => const Divider(height: 16),
                      itemBuilder: (BuildContext context, int index) {
                        final GitCommit commit = _commitHistory[index];
                        return _CommitListTile(commit: commit);
                      },
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRemotePresenceBanner() {
    final ThemeData theme = Theme.of(context);
    final GitRemoteStatus status = _remoteStatus!;
    final GitCommit? latest = status.latestCommit;
    final String subtitle =
        latest == null
            ? '${status.behind} remote change${status.behind == 1 ? '' : 's'} pending'
            : '${latest.author} • ${latest.relativeTime}';
    final String title =
        latest == null ? 'Remote updates available' : latest.message;
    return Positioned(
      left: 16,
      bottom: 16,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 250),
        opacity: _isMergeSummaryLoading ? 0.6 : 1,
        child: Material(
          elevation: 6,
          borderRadius: BorderRadius.circular(18),
          color: theme.colorScheme.surface,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      _buildStatusDot(color: Colors.orange.shade600, size: 14),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          title,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (status.remoteUrl != null && status.remoteUrl!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        status.remoteUrl!,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.primary,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed:
                              _isMergeSummaryLoading
                                  ? null
                                  : () =>
                                      unawaited(_handleReviewRemoteChanges()),
                          icon:
                              _isMergeSummaryLoading
                                  ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                  : const Icon(Icons.document_scanner_outlined),
                          label: const Text('Review remote changes'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _toggleCommitHistory() async {
    if (_isHistoryVisible) {
      setState(() {
        _isHistoryVisible = false;
      });
      return;
    }
    setState(() {
      _isHistoryVisible = true;
      _isLoadingHistory = true;
    });
    await _loadCommitHistory();
  }

  Future<void> _loadCommitHistory() async {
    try {
      final List<GitCommit> commits = await _gitStatusService.loadHistory(
        _workspaceRoot,
        limit: 40,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _commitHistory = commits;
      });
    } on GitCommandException catch (error) {
      if (mounted) {
        _showSnack(
          error.stderr.isNotEmpty ? error.stderr : error.toString(),
          error: true,
        );
      }
    } catch (error) {
      if (mounted) {
        _showSnack('Unable to load history: $error', error: true);
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingHistory = false;
        });
      }
    }
  }

  Future<void> _handleRemoteSync() async {
    setState(() {
      _isFetchingRemote = true;
    });
    try {
      final GitFetchResult result = await _gitStatusService.fetchRemote(
        _workspaceRoot,
      );
      if (!mounted) return;
      if (result.success) {
        _showSnack('Remote metadata fetched.');
        await _recordTelemetry('git.fetch', <String, dynamic>{
          'stdout': result.stdout,
        });
      } else {
        final String message =
            result.stderr.isNotEmpty ? result.stderr : 'Remote fetch failed.';
        _showSnack(message, error: true);
      }
    } on GitCommandException catch (error) {
      if (mounted) {
        _showSnack(
          error.stderr.isNotEmpty ? error.stderr : error.toString(),
          error: true,
        );
      }
    } catch (error) {
      if (mounted) {
        _showSnack('Remote fetch failed: $error', error: true);
      }
    } finally {
      if (mounted) {
        setState(() {
          _isFetchingRemote = false;
        });
      }
    }
    await _refreshRemoteStatus();
    await _refreshGitStatus();
  }

  Future<void> _refreshRemoteStatus() async {
    GitRemoteStatus? status;
    try {
      status = await _gitStatusService.loadRemoteStatus(_workspaceRoot);
    } on GitCommandException catch (error) {
      debugPrint('Remote status failed: $error');
      status = null;
    } catch (error, stackTrace) {
      debugPrint('Remote status error: $error');
      debugPrint('$stackTrace');
      status = null;
    }
    if (!mounted) {
      _remoteStatus = status;
      return;
    }
    setState(() {
      _remoteStatus = status;
    });
  }

  Future<void> _handleReviewRemoteChanges() async {
    final GitRemoteStatus? status = _remoteStatus;
    if (status == null) {
      _showSnack('No remote tracking branch configured.');
      return;
    }
    final String remoteRef =
        status.remoteBranch.isEmpty
            ? status.remoteName
            : '${status.remoteName}/${status.remoteBranch}';
    setState(() {
      _isMergeSummaryLoading = true;
    });
    try {
      final RvgMergeSummary summary = await _mergeService.summarizeRemoteDiff(
        workspaceRoot: _workspaceRoot,
        remoteRef: remoteRef,
        localDocument: _document,
      );
      if (!mounted) {
        return;
      }
      await _showMergeSummaryDialog(remoteRef: remoteRef, summary: summary);
      await _recordTelemetry('remote.review', <String, dynamic>{
        'remoteRef': remoteRef,
        'diffCount': summary.entries.length,
      });
    } catch (error, stackTrace) {
      debugPrint('Merge summary failed: $error');
      debugPrint('$stackTrace');
      if (mounted) {
        _showSnack('Failed to review remote changes: $error', error: true);
      }
    } finally {
      if (mounted) {
        setState(() {
          _isMergeSummaryLoading = false;
        });
      }
    }
  }

  Future<void> _showMergeSummaryDialog({
    required String remoteRef,
    required RvgMergeSummary summary,
  }) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        final ThemeData theme = Theme.of(context);
        return AlertDialog(
          title: Text('Remote snapshot • $remoteRef'),
          content: SizedBox(
            width: 540,
            child:
                summary.remoteDocument == null
                    ? const Text(
                      'Unable to load the remote .repoview.rvg file. '
                      'Fetch the remote branch and try again.',
                    )
                    : summary.entries.isEmpty
                    ? const Text(
                      'No differences detected between the local and remote RVG documents.',
                    )
                    : Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Differences',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 12),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 320),
                          child: Scrollbar(
                            thumbVisibility: true,
                            child: ListView.separated(
                              shrinkWrap: true,
                              itemCount: summary.entries.length,
                              separatorBuilder:
                                  (_, __) => const Divider(height: 16),
                              itemBuilder: (BuildContext context, int index) {
                                final RvgDiffEntry entry =
                                    summary.entries[index];
                                return _DiffEntryTile(entry: entry);
                              },
                            ),
                          ),
                        ),
                      ],
                    ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
            if (summary.remoteDocument != null)
              FilledButton(
                onPressed: () => _applyRemoteDocument(summary.remoteDocument!),
                child: const Text('Apply remote snapshot'),
              ),
          ],
        );
      },
    );
  }

  Future<void> _showLayoutPicker() async {
    if (_document.nodes.isEmpty) {
      _showSnack('Nothing to layout – add nodes first.');
      return;
    }
    final LayoutStyle? style = await showModalBottomSheet<LayoutStyle>(
      context: context,
      builder: (BuildContext context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.grid_view),
                title: const Text('Apply grid layout'),
                subtitle: const Text('Arrange nodes in a balanced matrix'),
                onTap: () => Navigator.of(context).pop(LayoutStyle.grid),
              ),
              ListTile(
                leading: const Icon(Icons.hub_outlined),
                title: const Text('Apply mind map layout'),
                subtitle: const Text(
                  'Radial presentation around the first node',
                ),
                onTap: () => Navigator.of(context).pop(LayoutStyle.mindMap),
              ),
              ListTile(
                leading: const Icon(Icons.alt_route),
                title: const Text('Apply orthogonal layout'),
                subtitle: const Text(
                  'Alternating horizontal and vertical flow',
                ),
                onTap: () => Navigator.of(context).pop(LayoutStyle.orthogonal),
              ),
            ],
          ),
        );
      },
    );
    if (style == null) {
      return;
    }
    await _applyLayout(style);
  }

  Future<void> _applyLayout(LayoutStyle style) async {
    final LayoutConfig config;
    switch (style) {
      case LayoutStyle.grid:
        config = LayoutConfig(
          style: style,
          horizontalSpacing: 260,
          verticalSpacing: 200,
        );
        break;
      case LayoutStyle.mindMap:
        config = LayoutConfig(
          style: style,
          mindMapRadiusStep: 220,
          mindMapSpread: 1.2,
        );
        break;
      case LayoutStyle.orthogonal:
        config = LayoutConfig(
          style: style,
          horizontalSpacing: 240,
          verticalSpacing: 220,
        );
        break;
    }
    final RvgDocument updated = _layoutService.applyLayout(_document, config);
    if (identical(updated, _document)) {
      _showSnack('Layout unchanged.');
      return;
    }
    _commitDocument(updated, recordUndo: true);
    _showSnack('Applied ${style.name} layout.');
    await _recordTelemetry('layout.apply', <String, dynamic>{
      'style': style.name,
      'nodeCount': updated.nodes.length,
    });
  }

  Future<void> _handleTemplateSelection(String id) async {
    final RvgTemplate? template = _templateService.findById(id);
    if (template == null) {
      return;
    }
    final bool? replace = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text('Insert "${template.label}" template?'),
          content: const Text(
            'Choose whether to replace the current diagram or append the template nodes.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(null),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Append'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Replace'),
            ),
          ],
        );
      },
    );
    if (replace == null) {
      return;
    }
    await _applyTemplate(template, replace: replace);
  }

  Future<void> _applyTemplate(
    RvgTemplate template, {
    required bool replace,
  }) async {
    final DateTime now = DateTime.now().toUtc();
    RvgDocument updated;
    if (replace || _document.nodes.isEmpty) {
      updated = template.document.copyWith(createdAt: now, updatedAt: now);
    } else {
      updated = _mergeTemplateDocument(template);
    }
    _commitDocument(updated, clearSelection: true, recordUndo: true);
    _showSnack('Template "${template.label}" applied.');
    await _recordTelemetry('template.apply', <String, dynamic>{
      'template': template.id,
      'replace': replace,
      'nodeCount': updated.nodes.length,
    });
  }

  RvgDocument _mergeTemplateDocument(RvgTemplate template) {
    final RvgDocument source = template.document;
    final List<RvgNode> merged = <RvgNode>[..._document.nodes];
    final Set<String> existingIds =
        _document.nodes.map((RvgNode node) => node.id).toSet();
    int sequence = 0;
    for (final RvgNode node in source.nodes) {
      String candidate = node.id;
      int suffix = 1;
      while (existingIds.contains(candidate)) {
        candidate = '${node.id}_$suffix';
        suffix += 1;
      }
      existingIds.add(candidate);
      final double deltaX = 80.0 * (sequence % 5);
      final double deltaY = 60.0 * (sequence ~/ 5);
      merged.add(
        node.copyWith(
          id: candidate,
          position: node.position.translate(deltaX, deltaY),
        ),
      );
      sequence += 1;
    }
    return _document.copyWith(
      nodes: merged,
      updatedAt: DateTime.now().toUtc(),
      attributes: <String, dynamic>{
        ..._document.attributes,
        'templates':
            <String>{
              ...((_document.attributes['templates'] as List?)
                      ?.cast<String>() ??
                  const <String>[]),
              template.id,
            }.toList(),
      },
    );
  }

  Future<void> _runAutomationScript(String id) async {
    final AutomationDescriptor? descriptor = _automationManager.descriptorFor(
      id,
    );
    if (descriptor == null) {
      _showSnack('Automation not found.', error: true);
      return;
    }
    try {
      final AutomationContext context = AutomationContext(
        branchName: _gitSnapshot?.branch ?? '',
        templates: _templateProvider,
        now: DateTime.now(),
      );
      final RvgDocument updated = await _automationManager.run(
        id,
        _document,
        context: context,
      );
      if (identical(updated, _document)) {
        _showSnack('Automation "${descriptor.label}" made no changes.');
        return;
      }
      _commitDocument(updated, recordUndo: true);
      _showSnack('Automation "${descriptor.label}" completed.');
      await _recordTelemetry('automation.run', <String, dynamic>{
        'automationId': descriptor.id,
        'nodeCount': updated.nodes.length,
      });
    } catch (error, stackTrace) {
      debugPrint('Automation failed: $error');
      debugPrint('$stackTrace');
      _showSnack('Automation failed: $error', error: true);
    }
  }

  Future<void> _applyRemoteDocument(RvgDocument remoteDocument) async {
    if (!mounted) return;
    Navigator.of(context).pop();
    final DateTime now = DateTime.now();
    final RvgDocument updated = remoteDocument.copyWith(updatedAt: now);
    _commitDocument(updated, clearSelection: true, recordUndo: true);
    _showSnack('Applied remote snapshot locally.');
    await _refreshGitStatus();
    await _refreshRemoteStatus();
    await _recordTelemetry('remote.apply', <String, dynamic>{
      'nodeCount': updated.nodes.length,
    });
  }

  Future<void> _handleAiSuggestion(GraphNode node) async {
    try {
      final NodeInsight insight = await _aiService.analyseNode(
        node.toRvgNode(),
      );
      final RvgDocument updated = _document.updateNode(node.id, (
        RvgNode value,
      ) {
        final Map<String, dynamic> metadata = <String, dynamic>{
          ...value.metadata,
          'summary': insight.suggestion.summary,
          'tags': insight.suggestion.tags,
          'aiConfidence': insight.suggestion.confidence,
        };
        return value.copyWith(metadata: metadata);
      });
      if (identical(updated, _document)) {
        _showSnack('AI assistant found no new insights for ${node.label}.');
        return;
      }
      _commitDocument(updated, recordUndo: true);
      _showSnack('AI suggestions applied to ${node.label}.');
      await _recordTelemetry('ai.suggest', <String, dynamic>{
        'nodeId': node.id,
        'tags': insight.suggestion.tags,
        'confidence': insight.suggestion.confidence,
      });
    } catch (error) {
      _showSnack('AI suggestion failed: $error', error: true);
    }
  }

  Widget _buildTelemetryPanel() {
    final ThemeData theme = Theme.of(context);
    return Positioned(
      bottom: 16,
      right: 16,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320, maxHeight: 320),
        child: Material(
          elevation: 8,
          borderRadius: BorderRadius.circular(16),
          color: theme.colorScheme.surface,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 8, 6),
                child: Row(
                  children: [
                    Text(
                      'Activity log',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: 'Refresh activity log',
                      icon: const Icon(Icons.refresh),
                      onPressed:
                          () => setState(() {
                            _telemetryEvents = _telemetry.recent();
                          }),
                    ),
                    IconButton(
                      tooltip: 'Close activity log',
                      icon: const Icon(Icons.close),
                      onPressed:
                          () => setState(() {
                            _isTelemetryVisible = false;
                          }),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child:
                    _telemetryEvents.isEmpty
                        ? const Center(
                          child: Padding(
                            padding: EdgeInsets.all(16),
                            child: Text('No events recorded yet.'),
                          ),
                        )
                        : Scrollbar(
                          thumbVisibility: true,
                          child: ListView.separated(
                            padding: const EdgeInsets.all(16),
                            itemCount: _telemetryEvents.length,
                            separatorBuilder:
                                (_, __) => const Divider(height: 16),
                            itemBuilder: (BuildContext context, int index) {
                              final TelemetryEvent event =
                                  _telemetryEvents[index];
                              final TimeOfDay tod = TimeOfDay.fromDateTime(
                                event.timestamp.toLocal(),
                              );
                              final String time = tod.format(context);
                              final String payload = event.payload.entries
                                  .map(
                                    (MapEntry<String, dynamic> entry) =>
                                        '${entry.key}: ${entry.value}',
                                  )
                                  .join(', ');
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    event.type,
                                    style: theme.textTheme.bodyLarge?.copyWith(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '$time • ${event.timestamp.toUtc().toIso8601String()}',
                                    style: theme.textTheme.bodySmall,
                                  ),
                                  if (payload.isNotEmpty) ...[
                                    const SizedBox(height: 4),
                                    Text(
                                      payload,
                                      style: theme.textTheme.labelSmall,
                                    ),
                                  ],
                                ],
                              );
                            },
                          ),
                        ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _recordTelemetry(
    String type,
    Map<String, dynamic> payload,
  ) async {
    await _telemetry.record(type, payload);
    if (_isTelemetryVisible) {
      setState(() {
        _telemetryEvents = _telemetry.recent();
      });
    }
  }

  Future<void> _handleDrop(DropDoneDetails details) async {
    setState(() {
      _isDropHovering = false;
    });
    final List<XFile> files = List<XFile>.from(details.files);
    if (files.isEmpty) {
      return;
    }
    final Set<LogicalKeyboardKey> keys = RawKeyboard.instance.keysPressed;
    final bool linkOnly =
        keys.contains(LogicalKeyboardKey.shiftLeft) ||
        keys.contains(LogicalKeyboardKey.shiftRight) ||
        keys.contains(LogicalKeyboardKey.shift);

    int imported = 0;
    int linked = 0;
    int workspaceRefs = 0;
    final List<String> errors = <String>[];
    bool needsSync = false;
    final Offset? baseScenePosition = _scenePositionForDrop(details);
    const Offset spreadStep = Offset(36, 28);
    int fileIndex = 0;
    final Map<String, Offset> positionOverrides = <String, Offset>{};

    for (final XFile file in files) {
      final String path = file.path;
      if (path.isEmpty) {
        errors.add('Dropped item is not a valid file.');
        fileIndex += 1;
        continue;
      }
      final Offset? scenePosition =
          baseScenePosition == null
              ? null
              : baseScenePosition +
                  Offset(
                    spreadStep.dx * fileIndex,
                    spreadStep.dy * fileIndex,
                  );
      final FileSystemEntityType type = FileSystemEntity.typeSync(
        path,
        followLinks: true,
      );
      final bool insideWorkspace = _isPathInsideWorkspace(path);
      if (!linkOnly && insideWorkspace) {
        workspaceRefs += 1;
        needsSync = true;
        await _recordTelemetry('drop.workspace', <String, dynamic>{
          'path': path,
        });
        fileIndex += 1;
        continue;
      }
      final bool shouldLink = linkOnly || type != FileSystemEntityType.file;
      try {
        if (shouldLink) {
          final Size nodeSize = const Size(240, 220);
          final Offset? dropPosition =
              scenePosition == null ? null : _positionForDrop(scenePosition, nodeSize);
          final bool linkedNow = await _linkExternalFile(
            file,
            type: type,
            dropPosition: dropPosition,
          );
          if (linkedNow) {
            linked += 1;
          }
        } else {
          final String? relativePath = await _importDroppedFile(file);
          if (relativePath != null) {
            final Size nodeSize = const Size(240, 220);
            final Offset? dropPosition =
                scenePosition == null ? null : _positionForDrop(scenePosition, nodeSize);
            if (dropPosition != null) {
              positionOverrides[_nodeIdForRelativePath(relativePath)] = dropPosition;
            }
            imported += 1;
            needsSync = true;
          }
        }
      } catch (error) {
        errors.add('Failed to process ${p.basename(path)}: $error');
      }
      fileIndex += 1;
    }

    if (needsSync || positionOverrides.isNotEmpty) {
      await _runSync(
        silent: true,
        positionOverrides:
            positionOverrides.isEmpty ? null : Map<String, Offset>.unmodifiable(positionOverrides),
      );
      await _refreshGitStatus();
    }

    if (imported > 0) {
      _showSnack(
        'Imported $imported file${imported == 1 ? '' : 's'} into workspace.',
      );
    }
    if (linked > 0) {
      _showSnack('Linked $linked external file${linked == 1 ? '' : 's'}');
    }
    if (workspaceRefs > 0) {
      _showSnack(
        '$workspaceRefs item${workspaceRefs == 1 ? '' : 's'} already exist in workspace; refreshed view.',
      );
    }
    if (errors.isNotEmpty) {
      _showSnack(errors.first, error: true);
    }
  }

  Future<String?> _importDroppedFile(XFile file) async {
    final String sourcePath = file.path;
    final String baseName = p.basename(sourcePath);
    final String uniqueName = _uniqueFileName(baseName);
    final String destinationPath = p.join(_workspaceRoot.path, uniqueName);
    await file.saveTo(destinationPath);
    await _recordTelemetry('drop.import', <String, dynamic>{
      'source': sourcePath,
      'destination': destinationPath,
    });
    return uniqueName;
  }

  Future<bool> _linkExternalFile(
    XFile file, {
    required FileSystemEntityType type,
    Offset? dropPosition,
  }) async {
    final String path = file.path;
    if (_document.nodes.any((RvgNode node) => node.filePath == path)) {
      return false;
    }
    final bool isDirectory = type == FileSystemEntityType.directory;
    final RvgNode node = RvgNode(
      id: 'ext:${DateTime.now().microsecondsSinceEpoch}',
      label: p.basename(path),
      visual: isDirectory ? RvgVisualType.folder : RvgVisualType.file,
      position: dropPosition ?? _suggestManualNodePosition(),
      size: const Size(240, 220),
      connections: const <String>[],
      filePath: path,
      metadata: <String, dynamic>{
        'origin': 'external-link',
        'absolutePath': path,
        'extension': p.extension(path).toLowerCase(),
        'isDirectory': isDirectory,
      },
    );
    final RvgDocument updated = _document.copyWith(
      nodes: <RvgNode>[..._document.nodes, node],
      updatedAt: DateTime.now().toUtc(),
    );
    _commitDocument(updated, recordUndo: true);
    await _recordTelemetry('drop.link', <String, dynamic>{
      'path': path,
      'type': isDirectory ? 'directory' : 'file',
    });
    return true;
  }

  bool _isPathInsideWorkspace(String path) {
    return p.isWithin(_workspaceRoot.path, path) ||
        p.equals(_workspaceRoot.path, path);
  }

  String _uniqueFileName(String baseName) {
    final String name = p.basenameWithoutExtension(baseName);
    final String extension = p.extension(baseName);
    String candidate = baseName;
    int index = 1;
    while (File(p.join(_workspaceRoot.path, candidate)).existsSync()) {
      candidate = '$name-$index$extension';
      index += 1;
    }
    return candidate;
  }

  Offset _suggestManualNodePosition() {
    const double baseX = 160;
   const double baseY = 140;
   const double spacingX = 260;
   const double spacingY = 200;
   const int columns = 5;
   final int count = _document.nodes.length;
   final int column = count % columns;
   final int row = count ~/ columns;
   return Offset(baseX + column * spacingX, baseY + row * spacingY);
 }

  Offset? _scenePositionForDrop(DropDoneDetails details) {
    final BuildContext? viewerContext = _interactiveViewerKey.currentContext;
    if (viewerContext == null) {
      return null;
    }
    final RenderBox? renderBox =
        viewerContext.findRenderObject() as RenderBox?;
    if (renderBox == null) {
      return null;
    }
    final Offset localToViewer =
        renderBox.globalToLocal(details.globalPosition);
    return _viewController.toScene(localToViewer);
  }

  Offset _positionForDrop(Offset scenePoint, Size nodeSize) {
    return Offset(
      scenePoint.dx - nodeSize.width / 2,
      scenePoint.dy - nodeSize.height / 2,
    );
  }

  String _nodeIdForRelativePath(String relativePath) {
    return 'fs:${relativePath.replaceAll('\\', '/')}';
  }

  Widget _buildDropOverlay() {
    final ThemeData theme = Theme.of(context);
    return Positioned.fill(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.primary.withValues(alpha: 0.08),
          border: Border.all(
            color: theme.colorScheme.primary.withValues(alpha: 0.6),
            width: 2,
          ),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: const [
              Icon(Icons.file_download, size: 48),
              SizedBox(height: 12),
              Text(
                'Drop files to add to RepoView',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
              SizedBox(height: 4),
              Text('Hold Shift to link without copying'),
            ],
          ),
        ),
      ),
    );
  }

  int _dirtyGitChangeCount() {
    final GitStatusSnapshot? snapshot = _gitSnapshot;
    if (snapshot == null) {
      return 0;
    }
    int total = 0;
    for (final GitFileStatus status in snapshot.files.values) {
      if (status.change == GitFileChangeType.ignored) {
        continue;
      }
      total += 1;
    }
    return total;
  }

  Future<void> _refreshGitStatus() async {
    GitStatusSnapshot snapshot;
    try {
      snapshot = await _gitStatusService.loadStatus(_workspaceRoot);
    } catch (error, stackTrace) {
      debugPrint('Git status failed: $error');
      debugPrint('$stackTrace');
      if (!mounted) {
        _gitSnapshot = null;
      } else {
        setState(() {
          _gitSnapshot = null;
        });
      }
      return;
    }

    final GitStatusSnapshot normalizedSnapshot = GitStatusSnapshot(
      branch: snapshot.branch,
      files: _normalizeGitStatusPaths(snapshot.files),
    );

    if (!mounted) {
      _gitSnapshot = normalizedSnapshot;
      return;
    }
    setState(() {
      _gitSnapshot = normalizedSnapshot;
    });
  }

  Map<String, GitFileStatus> _normalizeGitStatusPaths(
    Map<String, GitFileStatus> raw,
  ) {
    final Map<String, GitFileStatus> normalized = <String, GitFileStatus>{};
    raw.forEach((String path, GitFileStatus status) {
      final String normalizedPath = _normalizePath(path);
      normalized[normalizedPath] = GitFileStatus(
        path: normalizedPath,
        change: status.change,
        originalPath:
            status.originalPath != null
                ? _normalizePath(status.originalPath!)
                : null,
        indexCode: status.indexCode,
        workTreeCode: status.workTreeCode,
      );
    });
    return normalized;
  }

  String _normalizePath(String input) {
    return input.replaceAll('\\', '/').replaceFirst(RegExp(r'^\./'), '');
  }

  String? _gitPathForNode(GraphNode node) {
    final String? relative = node.metadata['relativePath'] as String?;
    if (relative != null && relative.isNotEmpty) {
      return _normalizePath(relative);
    }
    final String? source = node.sourcePath;
    if (source != null && source.startsWith(_workspaceRoot.path)) {
      final String derived = p
          .relative(source, from: _workspaceRoot.path)
          .replaceAll('\\', '/');
      if (derived.isNotEmpty) {
        return _normalizePath(derived);
      }
    }
    return null;
  }

  List<GitFileStatus> _gitStatusesForNode(GraphNode node) {
    final GitStatusSnapshot? snapshot = _gitSnapshot;
    if (snapshot == null || snapshot.files.isEmpty) {
      return const <GitFileStatus>[];
    }
    final String? path = _gitPathForNode(node);
    if (path == null) {
      return const <GitFileStatus>[];
    }
    final bool isFolder = node.visualType == RvgVisualType.folder;
    final String normalized = _normalizePath(path);
    final String prefix =
        normalized.endsWith('/') ? normalized : '$normalized/';

    final Set<String> seen = <String>{};
    final List<GitFileStatus> matches = <GitFileStatus>[];

    bool includeStatus(GitFileStatus status) {
      final String statusPath = _normalizePath(status.path);
      if (statusPath == normalized) {
        return true;
      }
      if (isFolder && statusPath.startsWith(prefix)) {
        return true;
      }
      if (status.originalPath != null) {
        final String original = _normalizePath(status.originalPath!);
        if (original == normalized) {
          return true;
        }
        if (isFolder && original.startsWith(prefix)) {
          return true;
        }
      }
      return false;
    }

    for (final GitFileStatus status in snapshot.files.values) {
      if (!includeStatus(status)) {
        continue;
      }
      final String key =
          '${status.path}::${status.indexCode}${status.workTreeCode}';
      if (seen.add(key)) {
        matches.add(status);
      }
    }
    return matches;
  }

  GitFileChangeType? _gitStatusForNode(GraphNode node) {
    final List<GitFileStatus> statuses = _gitStatusesForNode(node);
    if (statuses.isEmpty) {
      return null;
    }
    GitFileChangeType? best;
    int bestScore = -1;
    for (final GitFileStatus status in statuses) {
      if (status.change == GitFileChangeType.ignored) {
        continue;
      }
      final int score = _gitStatusPriority(status.change);
      if (score > bestScore) {
        best = status.change;
        bestScore = score;
      }
    }
    return best;
  }

  int _gitStatusPriority(GitFileChangeType change) {
    switch (change) {
      case GitFileChangeType.conflicted:
        return 6;
      case GitFileChangeType.deleted:
        return 5;
      case GitFileChangeType.modified:
        return 4;
      case GitFileChangeType.renamed:
        return 3;
      case GitFileChangeType.added:
        return 2;
      case GitFileChangeType.untracked:
        return 1;
      case GitFileChangeType.ignored:
        return 0;
    }
  }

  bool _hasStagedChanges() {
    final GitStatusSnapshot? snapshot = _gitSnapshot;
    if (snapshot == null || snapshot.files.isEmpty) {
      return false;
    }
    for (final GitFileStatus status in snapshot.files.values) {
      if (status.hasIndexChange && !status.isIgnored) {
        return true;
      }
    }
    return false;
  }

  bool _canCommit() {
    return !_isCommitInFlight && _hasStagedChanges();
  }

  void _showSnack(String message, {bool error = false}) {
    if (!mounted) return;
    final ThemeData theme = Theme.of(context);
    final Color? backgroundColor =
        error ? theme.colorScheme.error.withValues(alpha: 0.9) : null;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: backgroundColor,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _handleCommitPressed() async {
    final String? message = await _promptCommitMessage();
    if (message == null || message.trim().isEmpty) {
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _isCommitInFlight = true;
    });
    try {
      final String summary = await _gitStatusService.commit(
        _workspaceRoot,
        message.trim(),
      );
      _showSnack(
        summary.isEmpty ? 'Commit created.' : summary.split('\n').first,
      );
      await _recordTelemetry('git.commit', <String, dynamic>{
        'message': message.trim(),
        'summary': summary,
      });
    } on GitCommandException catch (error) {
      _showSnack(
        error.stderr.isNotEmpty ? error.stderr : error.toString(),
        error: true,
      );
    } catch (error) {
      _showSnack('Commit failed: $error', error: true);
    } finally {
      if (mounted) {
        setState(() {
          _isCommitInFlight = false;
        });
      }
    }
    await _refreshGitStatus();
  }

  Future<String?> _promptCommitMessage() async {
    final TextEditingController controller = TextEditingController();
    String? result;
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Commit staged changes'),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLines: 3,
            decoration: const InputDecoration(hintText: 'Commit message'),
            textInputAction: TextInputAction.done,
            onSubmitted: (String value) {
              result = controller.text;
              Navigator.of(context).pop();
            },
          ),
          actions: [
            TextButton(
              onPressed: () {
                controller.clear();
                Navigator.of(context).pop();
              },
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                result = controller.text;
                Navigator.of(context).pop();
              },
              child: const Text('Commit'),
            ),
          ],
        );
      },
    );
    controller.dispose();
    return result;
  }

  Widget _decorateNodeWithGitStatus({
    required bool isCircle,
    required Widget child,
    required GitFileChangeType? gitStatus,
  }) {
    if (gitStatus == null) {
      return child;
    }
    final Color statusColor = _gitStatusColor(gitStatus);
    final IconData statusIcon = _gitStatusIcon(gitStatus);
    final String statusLabel = _gitStatusLabel(gitStatus);
    final OutlinedBorder outline =
        isCircle
            ? const CircleBorder()
            : RoundedRectangleBorder(borderRadius: BorderRadius.circular(18));

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          decoration: const BoxDecoration(),
          foregroundDecoration: ShapeDecoration(
            color: Colors.transparent,
            shape: outline.copyWith(
              side: BorderSide(color: statusColor, width: 3),
            ),
          ),
          child: child,
        ),
        Positioned(
          right: -6,
          top: -6,
          child: Tooltip(
            message: statusLabel,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: statusColor,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.25),
                    blurRadius: 8,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: SizedBox(
                width: 26,
                height: 26,
                child: Icon(statusIcon, color: Colors.white, size: 14),
              ),
            ),
          ),
        ),
      ],
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
    final GitFileChangeType? gitStatus = _gitStatusForNode(node);
    final Widget nodeContent = delegate.buildNode(
      context,
      node,
      isSelected: node.id == _selectedNodeId,
      theme: theme,
      preview: preview,
      view: activeView,
    );
    final Widget decoratedContent = _decorateNodeWithGitStatus(
      isCircle: isCircle,
      child: nodeContent,
      gitStatus: gitStatus,
    );

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
          child: decoratedContent,
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

  Future<void> _runSync({
    bool silent = false,
    Map<String, Offset>? positionOverrides,
  }) async {
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
        positionOverrides: positionOverrides,
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
      unawaited(_refreshGitStatus());
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
    final List<NodeViewOption> candidates = WindowNodeView.all;
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

    final NodeViewOption desired = _optionForWindowMode(node.window.mode);
    final NodeViewOption? modeMatch = byId(desired.id);
    if (modeMatch != null) {
      return modeMatch;
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
    final List<GitFileStatus> gitStatuses = _gitStatusesForNode(node);
    final GitFileChangeType? gitStatus =
        gitStatuses.isEmpty ? null : _gitStatusForNode(node);
    Widget swatch(Color color) {
      if (color.a <= 0.0001) {
        return Container(
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: Colors.grey.shade400),
          ),
          child: Icon(
            Icons.not_interested,
            size: 12,
            color: Colors.grey.shade500,
          ),
        );
      }
      return Container(
        width: 18,
        height: 18,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: Colors.black.withValues(alpha: 0.15)),
        ),
      );
    }

    final List<PopupMenuEntry<String>> menuItems = <PopupMenuEntry<String>>[
      if (gitStatus != null)
        PopupMenuItem<String>(
          enabled: false,
          child: Row(
            children: [
              Icon(
                _gitStatusIcon(gitStatus),
                size: 16,
                color: _gitStatusColor(gitStatus),
              ),
              const SizedBox(width: 8),
              Text('Git: ${_gitStatusLabel(gitStatus)}'),
            ],
          ),
        ),
      if (gitStatus != null) const PopupMenuDivider(),
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
      const PopupMenuDivider(),
      const PopupMenuItem<String>(
        enabled: false,
        child: Text('Window'),
      ),
      CheckedPopupMenuItem<String>(
        value: 'window:border:toggle',
        checked: node.window.borderVisible,
        child: const Text('Show border'),
      ),
      const PopupMenuItem<String>(
        enabled: false,
        child: Text('Background'),
      ),
      for (final _WindowColorPreset preset in _windowBackgroundPresets)
        PopupMenuItem<String>(
          value:
              'window:bg:${WindowSettings._encodeColor(preset.color).toRadixString(16).padLeft(8, '0')}',
          child: Row(
            children: [
              swatch(preset.color),
              const SizedBox(width: 8),
              Expanded(child: Text(preset.label)),
              if (node.window.backgroundColor == preset.color)
                const Icon(Icons.check, size: 16),
            ],
          ),
        ),
      const PopupMenuItem<String>(
        enabled: false,
        child: Text('Border color'),
      ),
      for (final _WindowColorPreset preset in _windowBorderPresets)
        PopupMenuItem<String>(
          value:
              'window:borderColor:${WindowSettings._encodeColor(preset.color).toRadixString(16).padLeft(8, '0')}',
          child: Row(
            children: [
              swatch(preset.color),
              const SizedBox(width: 8),
              Expanded(child: Text(preset.label)),
              if (node.window.borderColor == preset.color)
                const Icon(Icons.check, size: 16),
            ],
          ),
        ),
      const PopupMenuDivider(),
      const PopupMenuItem<String>(
        enabled: false,
        child: Text('Stacking'),
      ),
      const PopupMenuItem<String>(
        value: 'window:stack:front',
        child: Text('Bring to front'),
      ),
      const PopupMenuItem<String>(
        value: 'window:stack:forward',
        child: Text('Bring forward'),
      ),
      const PopupMenuItem<String>(
        value: 'window:stack:backward',
        child: Text('Send backward'),
      ),
      const PopupMenuItem<String>(
        value: 'window:stack:back',
        child: Text('Send to back'),
      ),
      const PopupMenuDivider(),
      const PopupMenuItem<String>(
        value: 'ai:suggest',
        child: Text('AI: Suggest tags & summary'),
      ),
    ];
    final List<PopupMenuEntry<String>> gitActionItems = _buildGitMenuItems(
      node,
      gitStatuses,
    );
    if (gitActionItems.isNotEmpty) {
      menuItems.add(const PopupMenuDivider());
      menuItems.addAll(gitActionItems);
    }
    final String? selection = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: menuItems,
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
    } else if (selection == 'window:border:toggle') {
      await _updateWindowSettings(
        node,
        (WindowSettings settings) =>
            settings.copyWith(borderVisible: !settings.borderVisible),
      );
    } else if (selection.startsWith('window:bg:')) {
      final String hex = selection.substring('window:bg:'.length);
      final int? value = int.tryParse(hex, radix: 16);
      if (value != null) {
        await _updateWindowSettings(
          node,
          (WindowSettings settings) =>
              settings.copyWith(backgroundColor: Color(value)),
        );
      }
    } else if (selection.startsWith('window:borderColor:')) {
      final String hex = selection.substring('window:borderColor:'.length);
      final int? value = int.tryParse(hex, radix: 16);
      if (value != null) {
        await _updateWindowSettings(
          node,
          (WindowSettings settings) =>
              settings.copyWith(borderColor: Color(value)),
        );
      }
    } else if (selection == 'window:stack:front') {
      await _reorderNode(node, _StackOrderAction.toFront);
    } else if (selection == 'window:stack:back') {
      await _reorderNode(node, _StackOrderAction.toBack);
    } else if (selection == 'window:stack:forward') {
      await _reorderNode(node, _StackOrderAction.forward);
    } else if (selection == 'window:stack:backward') {
      await _reorderNode(node, _StackOrderAction.backward);
    } else if (selection == 'ai:suggest') {
      await _handleAiSuggestion(node);
    } else if (selection == 'git:stage') {
      await _stageNode(node);
    } else if (selection == 'git:unstage') {
      await _unstageNode(node);
    } else if (selection == 'git:diff') {
      await _showGitDiff(node, staged: false);
    } else if (selection == 'git:diff-staged') {
      await _showGitDiff(node, staged: true);
    }
  }

  List<PopupMenuEntry<String>> _buildGitMenuItems(
    GraphNode node,
    List<GitFileStatus> statuses,
  ) {
    if (statuses.isEmpty) {
      return const <PopupMenuEntry<String>>[];
    }
    final bool canStage = statuses.any(
      (GitFileStatus status) => status.canStage,
    );
    final bool canUnstage = statuses.any(
      (GitFileStatus status) => status.canUnstage,
    );
    final bool hasUnstagedDiff = statuses.any(
      (GitFileStatus status) => status.hasUnstagedDiff,
    );
    final bool hasStagedDiff = statuses.any(
      (GitFileStatus status) => status.hasIndexChange,
    );

    final List<PopupMenuEntry<String>> items = <PopupMenuEntry<String>>[];
    if (canStage) {
      items.add(
        const PopupMenuItem<String>(
          value: 'git:stage',
          child: Text('Git: Stage changes'),
        ),
      );
    }
    if (canUnstage) {
      items.add(
        const PopupMenuItem<String>(
          value: 'git:unstage',
          child: Text('Git: Unstage changes'),
        ),
      );
    }
    if (hasUnstagedDiff || hasStagedDiff) {
      if (items.isNotEmpty) {
        items.add(const PopupMenuDivider());
      }
      if (hasUnstagedDiff) {
        items.add(
          const PopupMenuItem<String>(
            value: 'git:diff',
            child: Text('Git: View diff'),
          ),
        );
      }
      if (hasStagedDiff) {
        items.add(
          const PopupMenuItem<String>(
            value: 'git:diff-staged',
            child: Text('Git: View staged diff'),
          ),
        );
      }
    }
    return items;
  }

  Future<void> _stageNode(GraphNode node) async {
    final String? gitPath = _gitPathForNode(node);
    if (gitPath == null) {
      _showSnack('Unable to stage: no Git path for ${node.label}', error: true);
      return;
    }
    try {
      await _gitStatusService.stagePath(_workspaceRoot, gitPath);
      _showSnack('Staged $gitPath');
    } on GitCommandException catch (error) {
      _showSnack(
        error.stderr.isNotEmpty ? error.stderr : error.toString(),
        error: true,
      );
    } catch (error) {
      _showSnack('Stage failed: $error', error: true);
    }
    await _refreshGitStatus();
  }

  Future<void> _unstageNode(GraphNode node) async {
    final String? gitPath = _gitPathForNode(node);
    if (gitPath == null) {
      _showSnack(
        'Unable to unstage: no Git path for ${node.label}',
        error: true,
      );
      return;
    }
    try {
      await _gitStatusService.unstagePath(_workspaceRoot, gitPath);
      _showSnack('Unstaged $gitPath');
    } on GitCommandException catch (error) {
      _showSnack(
        error.stderr.isNotEmpty ? error.stderr : error.toString(),
        error: true,
      );
    } catch (error) {
      _showSnack('Unstage failed: $error', error: true);
    }
    await _refreshGitStatus();
  }

  Future<void> _showGitDiff(GraphNode node, {required bool staged}) async {
    final List<GitFileStatus> statuses = _gitStatusesForNode(node);
    if (statuses.isEmpty) {
      _showSnack('No Git changes detected for ${node.label}.');
      return;
    }
    final bool untrackedOnly =
        statuses.isNotEmpty &&
        statuses.every((GitFileStatus s) => s.isUntracked);
    if (!staged && untrackedOnly) {
      _showSnack(
        'Diff is unavailable for untracked files. Stage the file first.',
      );
      return;
    }
    final bool hasRelevantDiff =
        staged
            ? statuses.any((GitFileStatus status) => status.hasIndexChange)
            : statuses.any((GitFileStatus status) => status.hasUnstagedDiff);
    if (!hasRelevantDiff) {
      _showSnack(
        'No ${staged ? 'staged' : 'working tree'} diff for ${node.label}.',
      );
      return;
    }
    final String? gitPath = _gitPathForNode(node);
    if (gitPath == null) {
      _showSnack(
        'Unable to load diff: no Git path for ${node.label}.',
        error: true,
      );
      return;
    }
    GitDiffResult diff;
    try {
      diff = await _gitStatusService.diffPath(
        _workspaceRoot,
        gitPath,
        staged: staged,
      );
    } on GitCommandException catch (error) {
      _showSnack(
        error.stderr.isNotEmpty ? error.stderr : error.toString(),
        error: true,
      );
      return;
    } catch (error) {
      _showSnack('Failed to load diff: $error', error: true);
      return;
    }
    if (diff.isEmpty) {
      _showSnack('Diff is empty for ${node.label}.');
      return;
    }
    if (!mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(
            staged ? 'Staged diff: ${node.label}' : 'Diff: ${node.label}',
          ),
          content: SizedBox(
            width: 720,
            child: Scrollbar(
              thumbVisibility: true,
              child: SingleChildScrollView(
                child: SelectableText(
                  diff.content,
                  style:
                      Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontFamily: 'monospace',
                      ) ??
                      const TextStyle(fontFamily: 'monospace'),
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
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
      final WindowSettings currentSettings = WindowSettings.fromMetadata(metadata);
      final WindowSettings nextSettings = currentSettings.copyWith(
        mode: _windowModeForOption(option),
      );
      metadata[WindowSettings.metadataKey] = nextSettings.toMetadata();
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

  Future<void> _updateWindowSettings(
    GraphNode node,
    WindowSettings Function(WindowSettings settings) transform, {
    bool recordUndo = true,
  }) async {
    final RvgDocument updated = _document.updateNode(node.id, (RvgNode original) {
      final Map<String, dynamic> metadata = Map<String, dynamic>.from(original.metadata);
      final WindowSettings current = WindowSettings.fromMetadata(metadata);
      final WindowSettings next = transform(current);
      metadata[WindowSettings.metadataKey] = next.toMetadata();
      metadata['activeView'] = _optionForWindowMode(next.mode).id;
      return original.copyWith(metadata: metadata);
    });

    if (!identical(updated, _document)) {
      _commitDocument(updated, recordUndo: recordUndo);
    }
  }

  Future<void> _reorderNode(GraphNode node, _StackOrderAction action) async {
    final List<RvgNode> currentNodes = List<RvgNode>.from(_document.nodes);
    final int index = currentNodes.indexWhere((RvgNode element) => element.id == node.id);
    if (index == -1) {
      return;
    }

    int targetIndex = index;
    switch (action) {
      case _StackOrderAction.toFront:
        targetIndex = currentNodes.length - 1;
        break;
      case _StackOrderAction.toBack:
        targetIndex = 0;
        break;
      case _StackOrderAction.forward:
        targetIndex = (index + 1).clamp(0, currentNodes.length - 1);
        break;
      case _StackOrderAction.backward:
        targetIndex = (index - 1).clamp(0, currentNodes.length - 1);
        break;
    }

    if (targetIndex == index) {
      return;
    }

    final RvgNode moving = currentNodes.removeAt(index);
    currentNodes.insert(targetIndex, moving);

    final RvgDocument updated = _document.copyWith(
      nodes: currentNodes,
      updatedAt: DateTime.now().toUtc(),
    );
    _commitDocument(updated, recordUndo: true);
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

enum WindowViewMode { shrinkable, scrollable, icon }

enum _StackOrderAction { toFront, toBack, forward, backward }

class WindowSettings {
  const WindowSettings({
    this.mode = WindowViewMode.shrinkable,
    this.borderVisible = true,
    this.backgroundColor = const Color(0xFFFFFFFF),
    this.borderColor = const Color(0xFFB0BEC5),
  });

  final WindowViewMode mode;
  final bool borderVisible;
  final Color backgroundColor;
  final Color borderColor;

  static const String metadataKey = 'window';

  WindowSettings copyWith({
    WindowViewMode? mode,
    bool? borderVisible,
    Color? backgroundColor,
    Color? borderColor,
  }) {
    return WindowSettings(
      mode: mode ?? this.mode,
      borderVisible: borderVisible ?? this.borderVisible,
      backgroundColor: backgroundColor ?? this.backgroundColor,
      borderColor: borderColor ?? this.borderColor,
    );
  }

  Map<String, dynamic> toMetadata() {
    return <String, dynamic>{
      'mode': mode.name,
      'borderVisible': borderVisible,
      'background': _encodeColor(backgroundColor),
      'border': _encodeColor(borderColor),
    };
  }

  static WindowSettings fromMetadata(Map<String, dynamic> metadata) {
    final Map<String, dynamic>? rawWindow =
        (metadata[metadataKey] as Map?)?.cast<String, dynamic>();
    if (rawWindow == null) {
      return WindowSettings(
        mode:
            _modeFromLegacy(metadata['activeView'] as String?) ??
            WindowViewMode.shrinkable,
      );
    }
    return WindowSettings(
      mode: _modeFromName(rawWindow['mode'] as String?) ??
          _modeFromLegacy(metadata['activeView'] as String?) ??
          WindowViewMode.shrinkable,
      borderVisible: (rawWindow['borderVisible'] as bool?) ?? true,
      backgroundColor: _colorFromMetadata(
        rawWindow['background'],
        const Color(0xFFFFFFFF),
      ),
      borderColor: _colorFromMetadata(
        rawWindow['border'],
        const Color(0xFFB0BEC5),
      ),
    );
  }

  static WindowViewMode? _modeFromName(String? value) {
    if (value == null) {
      return null;
    }
    for (final WindowViewMode mode in WindowViewMode.values) {
      if (mode.name == value) {
        return mode;
      }
    }
    return null;
  }

  static WindowViewMode? _modeFromLegacy(String? value) {
    switch (value) {
      case 'window.shrinkable':
        return WindowViewMode.shrinkable;
      case 'window.scrollable':
        return WindowViewMode.scrollable;
      case 'window.icon':
        return WindowViewMode.icon;
      case 'file.full':
      case 'folder.children':
        return WindowViewMode.scrollable;
      case 'file.summary':
      case 'rect.standard':
      case 'circle.standard':
      case 'folder.summary':
        return WindowViewMode.icon;
      case 'file.preview':
      case 'file.details':
      default:
        return null;
    }
  }

  static Color _colorFromMetadata(dynamic value, Color fallback) {
    if (value is int) {
      return Color(value);
    }
    if (value is String) {
      final String sanitized = value.startsWith('#') ? value.substring(1) : value;
      final int? parsed = int.tryParse(sanitized, radix: 16);
      if (parsed != null) {
        if (sanitized.length <= 6) {
          return Color(0xFF000000 | parsed);
        }
        return Color(parsed);
      }
    }
    return fallback;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is WindowSettings &&
        other.mode == mode &&
        other.borderVisible == borderVisible &&
        _encodeColor(other.backgroundColor) == _encodeColor(backgroundColor) &&
        _encodeColor(other.borderColor) == _encodeColor(borderColor);
  }

  @override
  int get hashCode => Object.hash(
        mode,
        borderVisible,
        _encodeColor(backgroundColor),
        _encodeColor(borderColor),
      );
  static int _encodeColor(Color color) {
    final int a = (color.a * 255).round().clamp(0, 255);
    final int r = (color.r * 255).round().clamp(0, 255);
    final int g = (color.g * 255).round().clamp(0, 255);
    final int b = (color.b * 255).round().clamp(0, 255);
    return (a << 24) | (r << 16) | (g << 8) | b;
  }
}

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
    this.window = const WindowSettings(),
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
  final WindowSettings window;

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
      window: WindowSettings.fromMetadata(node.metadata),
    );
  }

  RvgNode toRvgNode() {
    final Map<String, dynamic> nextMetadata = Map<String, dynamic>.from(metadata)
      ..[WindowSettings.metadataKey] = window.toMetadata()
      ..['activeView'] = _optionForWindowMode(window.mode).id;
    return RvgNode(
      id: id,
      label: label,
      visual: visualType,
      position: position,
      size: size,
      connections: List<String>.from(connections),
      filePath: sourcePath,
      metadata: nextMetadata,
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
    WindowSettings? window,
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
      window: window ?? this.window,
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
        mapEquals(other.metadata, metadata) &&
        other.window == window;
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
    window.hashCode,
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
    final WindowSettings window = node.window;
    final BorderRadius radius = BorderRadius.circular(16);
    final Color highlight = theme.colorScheme.primary.withValues(alpha: 0.12);
    final Color background = isSelected
        ? Color.alphaBlend(highlight, window.backgroundColor)
        : window.backgroundColor;
    final bool showBorder = window.borderVisible || isSelected;
    final double borderWidth = isSelected ? 3 : 2;
    final Color borderColor = isSelected
        ? theme.colorScheme.primary
        : window.borderColor;

    final Widget surface = DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        borderRadius: radius,
        border: showBorder ? Border.all(color: borderColor, width: borderWidth) : null,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
        child: _buildWindowPanel(
          node: node,
          theme: theme,
          preview: preview,
        ),
      ),
    );

    return ClipRRect(
      borderRadius: radius,
      child: SizedBox(
        width: node.size.width,
        height: node.size.height,
        child: surface,
      ),
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

Widget _buildWindowPanel({
  required GraphNode node,
  required ThemeData theme,
  CachedPreview? preview,
}) {
  final TextStyle titleStyle =
      theme.textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w700,
        color: theme.colorScheme.onSurface,
      ) ??
      const TextStyle(fontSize: 16, fontWeight: FontWeight.w700);
  final TextStyle subtitleStyle =
      theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ) ??
      const TextStyle(fontSize: 12, color: Color(0xFF5F6368));

  final String? subtitle = _windowSubtitleForNode(node);
  final Widget body = _buildWindowModeContent(
    node: node,
    theme: theme,
    preview: preview,
  );

  final List<Widget> children = <Widget>[
    Text(
      node.label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: titleStyle,
    ),
  ];

  if (subtitle != null && subtitle.isNotEmpty) {
    children
      ..add(const SizedBox(height: 4))
      ..add(
        Text(
          subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: subtitleStyle,
        ),
      );
  }

  children
    ..add(const SizedBox(height: 12))
    ..add(Expanded(child: body));

  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: children,
  );
}

Widget _buildWindowModeContent({
  required GraphNode node,
  required ThemeData theme,
  CachedPreview? preview,
}) {
  switch (node.window.mode) {
    case WindowViewMode.shrinkable:
      return _buildShrinkableWindowContent(node, theme, preview);
    case WindowViewMode.scrollable:
      return _buildScrollableWindowContent(node, theme, preview);
    case WindowViewMode.icon:
      return _buildIconWindowContent(node, theme, preview);
  }
}

Widget _buildShrinkableWindowContent(
  GraphNode node,
  ThemeData theme,
  CachedPreview? preview,
) {
  if (preview != null && preview.type == PreviewType.image && preview.data != null) {
    return _buildShrinkableImage(preview.data!);
  }
  if (preview != null &&
      (preview.type == PreviewType.text || preview.type == PreviewType.markdown)) {
    final String snippet = _formatPreviewText(preview.text ?? '');
    if (snippet.isNotEmpty) {
      return _buildShrinkableText(snippet, theme);
    }
  }
  final String? noteBody = _noteBodyFor(node);
  if (noteBody != null && noteBody.trim().isNotEmpty) {
    return _buildShrinkableText(noteBody.trim(), theme);
  }
  return _buildEmptyWindowState(theme);
}

Widget _buildScrollableWindowContent(
  GraphNode node,
  ThemeData theme,
  CachedPreview? preview,
) {
  if (preview != null && preview.type == PreviewType.image && preview.data != null) {
    return _buildScrollableImage(preview.data!);
  }
  if (preview != null &&
      (preview.type == PreviewType.text || preview.type == PreviewType.markdown)) {
    final String text = preview.text ?? '';
    if (text.isNotEmpty) {
      return _buildScrollableText(text, theme);
    }
  }
  final String? noteBody = _noteBodyFor(node);
  if (noteBody != null && noteBody.trim().isNotEmpty) {
    return _buildScrollableText(noteBody.trim(), theme);
  }
  return _buildEmptyWindowState(theme);
}

Widget _buildIconWindowContent(
  GraphNode node,
  ThemeData theme,
  CachedPreview? preview,
) {
  final IconData icon = _iconForNode(node);
  final String? extension = _fileExtension(node);
  final TextStyle captionStyle =
      theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        letterSpacing: 0.8,
        fontWeight: FontWeight.w600,
      ) ??
      const TextStyle(fontSize: 12, letterSpacing: 0.8, fontWeight: FontWeight.w600);

  return Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 48, color: theme.colorScheme.primary),
        if (extension != null && extension.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(extension.toUpperCase(), style: captionStyle),
          ),
      ],
    ),
  );
}

Widget _buildShrinkableImage(Uint8List data) {
  return LayoutBuilder(
    builder: (BuildContext context, BoxConstraints constraints) {
      return FittedBox(
        fit: BoxFit.contain,
        alignment: Alignment.topLeft,
        child: Image.memory(
          data,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.medium,
        ),
      );
    },
  );
}

Widget _buildShrinkableText(String text, ThemeData theme) {
  final TextStyle style =
      theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.onSurface.withValues(alpha: 0.88),
        height: 1.25,
      ) ??
      const TextStyle(fontSize: 14, height: 1.25, color: Colors.black87);
  return LayoutBuilder(
    builder: (BuildContext context, BoxConstraints constraints) {
      final double width = constraints.maxWidth <= 0 ? 200 : constraints.maxWidth;
      return ClipRect(
        child: FittedBox(
          fit: BoxFit.contain,
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: Text(
              text,
              style: style,
              softWrap: true,
            ),
          ),
        ),
      );
    },
  );
}

Widget _buildScrollableImage(Uint8List data) {
  return ClipRect(
    child: InteractiveViewer(
      minScale: 1,
      maxScale: 4,
      boundaryMargin: const EdgeInsets.all(0),
      child: Align(
        alignment: Alignment.topLeft,
        child: Image.memory(
          data,
          fit: BoxFit.none,
          filterQuality: FilterQuality.medium,
        ),
      ),
    ),
  );
}

Widget _buildScrollableText(String text, ThemeData theme) {
  final TextStyle style =
      theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.onSurface.withValues(alpha: 0.9),
        height: 1.35,
      ) ??
      const TextStyle(fontSize: 14, height: 1.35, color: Colors.black87);
  return Scrollbar(
    thumbVisibility: true,
    child: SingleChildScrollView(
      child: SelectableText(text, style: style),
    ),
  );
}

Widget _buildEmptyWindowState(ThemeData theme) {
  final TextStyle style =
      theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        fontStyle: FontStyle.italic,
      ) ??
      const TextStyle(fontSize: 12, fontStyle: FontStyle.italic, color: Color(0xFF5F6368));
  return Center(child: Text('No preview available', style: style));
}

String? _windowSubtitleForNode(GraphNode node) {
  if (node.visualType == RvgVisualType.file ||
      node.visualType == RvgVisualType.folder ||
      (node.metadata['origin'] as String?) == 'filesystem') {
    return _relativePathFor(node);
  }
  if (node.visualType == RvgVisualType.external) {
    return (node.metadata['absolutePath'] as String?) ?? node.sourcePath;
  }
  return null;
}

String? _noteBodyFor(GraphNode node) {
  return node.metadata['body'] as String?;
}

bool _nodeIsDirectory(GraphNode node) {
  return (node.metadata['isDirectory'] as bool?) ?? false;
}

String? _fileExtension(GraphNode node) {
  final String? ext = (node.metadata['extension'] as String?) ??
      (node.sourcePath != null ? p.extension(node.sourcePath!) : null);
  if (ext == null || ext.isEmpty) {
    return null;
  }
  return ext.startsWith('.') ? ext.substring(1) : ext;
}

IconData _iconForNode(GraphNode node) {
  if (_nodeIsDirectory(node) || node.visualType == RvgVisualType.folder) {
    return Icons.folder;
  }
  if (node.visualType == RvgVisualType.note) {
    return Icons.sticky_note_2_outlined;
  }
  final String? extension = _fileExtension(node)?.toLowerCase();
  if (extension != null) {
    if (<String>{'png', 'jpg', 'jpeg', 'gif', 'bmp', 'webp'}.contains(extension)) {
      return Icons.photo;
    }
    if (<String>{'md', 'markdown', 'txt', 'json', 'yaml', 'yml', 'csv', 'tsv'}
        .contains(extension)) {
      return Icons.description_outlined;
    }
    if (extension == 'pdf') {
      return Icons.picture_as_pdf;
    }
    if (<String>{
      'dart',
      'js',
      'ts',
      'tsx',
      'jsx',
      'java',
      'kt',
      'kts',
      'swift',
      'py',
      'rb',
      'go',
      'rs',
      'c',
      'cc',
      'cpp',
      'h',
      'hpp',
      'cs',
      'sh',
    }.contains(extension)) {
      return Icons.code;
    }
  }
  if ((node.metadata['origin'] as String?) == 'external-link') {
    return Icons.link;
  }
  return Icons.insert_drive_file_outlined;
}

String _relativePathFor(GraphNode node) {
  return (node.metadata['relativePath'] as String?) ?? node.label;
}

Color _gitStatusColor(GitFileChangeType change) {
  switch (change) {
    case GitFileChangeType.conflicted:
      return Colors.red.shade700;
    case GitFileChangeType.deleted:
      return Colors.red.shade500;
    case GitFileChangeType.modified:
      return Colors.orange.shade600;
    case GitFileChangeType.renamed:
      return Colors.blue.shade600;
    case GitFileChangeType.added:
      return Colors.green.shade600;
    case GitFileChangeType.untracked:
      return Colors.deepPurple.shade500;
    case GitFileChangeType.ignored:
      return Colors.grey.shade500;
  }
}

String _gitStatusLabel(GitFileChangeType change) {
  switch (change) {
    case GitFileChangeType.conflicted:
      return 'Merge conflict';
    case GitFileChangeType.deleted:
      return 'Deleted';
    case GitFileChangeType.modified:
      return 'Modified';
    case GitFileChangeType.renamed:
      return 'Renamed';
    case GitFileChangeType.added:
      return 'Added';
    case GitFileChangeType.untracked:
      return 'Untracked';
    case GitFileChangeType.ignored:
      return 'Ignored';
  }
}

IconData _gitStatusIcon(GitFileChangeType change) {
  switch (change) {
    case GitFileChangeType.conflicted:
      return Icons.warning_amber_rounded;
    case GitFileChangeType.deleted:
      return Icons.delete_forever;
    case GitFileChangeType.modified:
      return Icons.edit;
    case GitFileChangeType.renamed:
      return Icons.drive_file_move;
    case GitFileChangeType.added:
      return Icons.add_circle;
    case GitFileChangeType.untracked:
      return Icons.fiber_new;
    case GitFileChangeType.ignored:
      return Icons.do_not_disturb_alt;
  }
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

class _CommitListTile extends StatelessWidget {
  const _CommitListTile({required this.commit});

  final GitCommit commit;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String abbreviatedHash =
        commit.hash.length > 7 ? commit.hash.substring(0, 7) : commit.hash;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          commit.message,
          style: theme.textTheme.bodyLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '${commit.author} • ${commit.relativeTime}',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 4),
        Text(
          abbreviatedHash,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.secondary,
            letterSpacing: 0.6,
          ),
        ),
      ],
    );
  }
}

class _DiffEntryTile extends StatelessWidget {
  const _DiffEntryTile({required this.entry});

  final RvgDiffEntry entry;

  Color _colorForType(BuildContext context) {
    switch (entry.type) {
      case RvgDiffType.added:
        return Colors.green.shade500;
      case RvgDiffType.removed:
        return Theme.of(context).colorScheme.error;
      case RvgDiffType.changed:
        return Colors.orange.shade600;
    }
  }

  IconData _iconForType() {
    switch (entry.type) {
      case RvgDiffType.added:
        return Icons.add_circle_outline;
      case RvgDiffType.removed:
        return Icons.remove_circle_outline;
      case RvgDiffType.changed:
        return Icons.change_circle_outlined;
    }
  }

  String _labelForType() {
    switch (entry.type) {
      case RvgDiffType.added:
        return 'Added';
      case RvgDiffType.removed:
        return 'Removed';
      case RvgDiffType.changed:
        return 'Modified';
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color tint = _colorForType(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(_iconForType(), color: tint, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                entry.label,
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              _labelForType(),
              style: theme.textTheme.labelSmall?.copyWith(color: tint),
            ),
          ],
        ),
        if (entry.details.isNotEmpty) ...[
          const SizedBox(height: 6),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children:
                entry.details
                    .map(
                      (String detail) => Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Text(
                          '• $detail',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    )
                    .toList(),
          ),
        ],
      ],
    );
  }
}

class WindowNodeView {
  static const NodeViewOption shrinkable = NodeViewOption(
    id: 'window.shrinkable',
    label: 'Shrink to fit',
  );

  static const NodeViewOption scrollable = NodeViewOption(
    id: 'window.scrollable',
    label: 'Scrollable viewport',
  );

  static const NodeViewOption icon = NodeViewOption(
    id: 'window.icon',
    label: 'Icon only',
  );

  static const List<NodeViewOption> all = <NodeViewOption>[
    shrinkable,
    scrollable,
    icon,
  ];
}

class _WindowColorPreset {
  const _WindowColorPreset(this.label, this.color);

  final String label;
  final Color color;
}

const List<_WindowColorPreset> _windowBackgroundPresets = <_WindowColorPreset>[
  _WindowColorPreset('Default', Color(0xFFFFFFFF)),
  _WindowColorPreset('Soft gray', Color(0xFFF5F5F5)),
  _WindowColorPreset('Indigo mist', Color(0xFFE8EAF6)),
  _WindowColorPreset('Seafoam', Color(0xFFE0F2F1)),
  _WindowColorPreset('Transparent', Color(0x00000000)),
];

const List<_WindowColorPreset> _windowBorderPresets = <_WindowColorPreset>[
  _WindowColorPreset('Slate', Color(0xFFB0BEC5)),
  _WindowColorPreset('Indigo', Color(0xFF3F51B5)),
  _WindowColorPreset('Emerald', Color(0xFF43A047)),
  _WindowColorPreset('Sunset', Color(0xFFFF7043)),
  _WindowColorPreset('Transparent', Color(0x00000000)),
];

NodeViewOption _optionForWindowMode(WindowViewMode mode) {
  switch (mode) {
    case WindowViewMode.shrinkable:
      return WindowNodeView.shrinkable;
    case WindowViewMode.scrollable:
      return WindowNodeView.scrollable;
    case WindowViewMode.icon:
      return WindowNodeView.icon;
  }
}

WindowViewMode _windowModeForOption(NodeViewOption option) {
  return _windowModeForId(option.id);
}

WindowViewMode _windowModeForId(String id) {
  switch (id) {
    case 'window.scrollable':
      return WindowViewMode.scrollable;
    case 'window.icon':
      return WindowViewMode.icon;
    case 'window.shrinkable':
    default:
      return WindowViewMode.shrinkable;
  }
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
