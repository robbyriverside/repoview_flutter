import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

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

  late final Map<GraphShapeType, GraphShapeDelegate> _shapeRegistry;
  late List<GraphNode> _nodes;
  String? _selectedNodeId;

  @override
  void initState() {
    super.initState();
    _shapeRegistry = {
      GraphShapeType.rectangle: const RectangleNodeShape(),
      GraphShapeType.circle: const CircleNodeShape(),
    };
    _nodes = [
      GraphNode(
        id: 'api',
        label: 'API Gateway',
        shape: GraphShapeType.rectangle,
        position: const Offset(180, 160),
        size: const Size(200, 96),
        connections: const ['auth', 'orders', 'analytics'],
      ),
      GraphNode(
        id: 'auth',
        label: 'Auth Service',
        shape: GraphShapeType.rectangle,
        position: const Offset(520, 120),
        size: const Size(190, 90),
        connections: const ['users'],
      ),
      GraphNode(
        id: 'orders',
        label: 'Orders',
        shape: GraphShapeType.rectangle,
        position: const Offset(520, 340),
        size: const Size(190, 90),
        connections: const ['payments', 'shipments'],
      ),
      GraphNode(
        id: 'analytics',
        label: 'Analytics',
        shape: GraphShapeType.circle,
        position: const Offset(260, 480),
        size: const Size(160, 160),
        connections: const ['warehouse'],
      ),
      GraphNode(
        id: 'users',
        label: 'Users DB',
        shape: GraphShapeType.rectangle,
        position: const Offset(820, 80),
        size: const Size(200, 96),
      ),
      GraphNode(
        id: 'payments',
        label: 'Payments',
        shape: GraphShapeType.rectangle,
        position: const Offset(820, 300),
        size: const Size(200, 96),
        connections: const ['ledger'],
      ),
      GraphNode(
        id: 'shipments',
        label: 'Shipments',
        shape: GraphShapeType.rectangle,
        position: const Offset(820, 460),
        size: const Size(200, 96),
      ),
      GraphNode(
        id: 'warehouse',
        label: 'Warehouse\nReporting',
        shape: GraphShapeType.rectangle,
        position: const Offset(560, 560),
        size: const Size(220, 110),
      ),
      GraphNode(
        id: 'ledger',
        label: 'Finance Ledger',
        shape: GraphShapeType.circle,
        position: const Offset(1100, 320),
        size: const Size(150, 150),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Graph Connectivity Playground')),
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

  void _handleNodePan(String nodeId, Offset delta) {
    final nodeIndex = _nodes.indexWhere((element) => element.id == nodeId);
    if (nodeIndex == -1) {
      return;
    }
    final node = _nodes[nodeIndex];
    final Offset rawPosition = node.position + delta;
    final double maxX = _canvasSize.width - node.size.width;
    final double maxY = _canvasSize.height - node.size.height;

    final Offset boundedPosition = Offset(
      rawPosition.dx.clamp(0.0, maxX < 0 ? 0.0 : maxX).toDouble(),
      rawPosition.dy.clamp(0.0, maxY < 0 ? 0.0 : maxY).toDouble(),
    );

    final GraphNode updatedNode = node.copyWith(position: boundedPosition);

    setState(() {
      final List<GraphNode> updatedNodes = List<GraphNode>.from(_nodes);
      updatedNodes[nodeIndex] = updatedNode;
      _nodes = updatedNodes;
    });
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

    final List<GraphNode>? updatedNodes = _toggleConnection(
      activeSource,
      tappedId,
    );
    if (updatedNodes != null) {
      setState(() {
        _nodes = updatedNodes;
        _selectedNodeId = null;
      });
    } else {
      setState(() {
        _selectedNodeId = null;
      });
    }
  }

  List<GraphNode>? _toggleConnection(String fromId, String toId) {
    final int fromIndex = _nodes.indexWhere((node) => node.id == fromId);
    final int toIndex = _nodes.indexWhere((node) => node.id == toId);
    if (fromIndex == -1 || toIndex == -1) {
      return null;
    }

    final GraphNode source = _nodes[fromIndex];
    final bool hasEdge = source.connections.contains(toId);
    final List<String> updatedConnections =
        hasEdge
            ? source.connections.where((id) => id != toId).toList()
            : [...source.connections, toId];

    final List<GraphNode> updatedNodes = List<GraphNode>.from(_nodes);
    updatedNodes[fromIndex] = source.copyWith(connections: updatedConnections);
    return updatedNodes;
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
    this.connections = const [],
  });

  final String id;
  final String label;
  final GraphShapeType shape;
  final Offset position;
  final Size size;
  final List<String> connections;

  GraphNode copyWith({
    String? id,
    String? label,
    GraphShapeType? shape,
    Offset? position,
    Size? size,
    List<String>? connections,
  }) {
    return GraphNode(
      id: id ?? this.id,
      label: label ?? this.label,
      shape: shape ?? this.shape,
      position: position ?? this.position,
      size: size ?? this.size,
      connections: connections ?? this.connections,
    );
  }
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
    return Container(
      width: node.size.width,
      height: node.size.height,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isSelected ? Colors.indigo.shade50 : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isSelected ? Colors.indigo : Colors.grey.shade400,
          width: isSelected ? 3 : 1.6,
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        node.label,
        textAlign: TextAlign.center,
        style:
            theme.textTheme.titleMedium?.copyWith(
              color: Colors.black87,
              fontWeight: FontWeight.w600,
            ) ??
            const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
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

Color _colorWithOpacity(Color color, double opacity) {
  final double boundedOpacity = opacity.clamp(0.0, 1.0);
  final int alpha = (boundedOpacity * 255).round();
  return color.withAlpha(alpha);
}
