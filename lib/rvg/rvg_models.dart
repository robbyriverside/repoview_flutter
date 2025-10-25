import 'dart:convert';
import 'dart:ui';

import 'package:flutter/foundation.dart';

import 'rvg_types.dart';

class RvgNode {
  const RvgNode({
    required this.id,
    required this.label,
    required this.visual,
    required this.position,
    required this.size,
    this.connections = const [],
    this.filePath,
    this.metadata = const {},
  });

  final String id;
  final String label;
  final RvgVisualType visual;
  final Offset position;
  final Size size;
  final List<String> connections;
  final String? filePath;
  final Map<String, dynamic> metadata;

  RvgNode copyWith({
    String? id,
    String? label,
    RvgVisualType? visual,
    Offset? position,
    Size? size,
    List<String>? connections,
    String? filePath,
    Map<String, dynamic>? metadata,
  }) {
    return RvgNode(
      id: id ?? this.id,
      label: label ?? this.label,
      visual: visual ?? this.visual,
      position: position ?? this.position,
      size: size ?? this.size,
      connections: connections ?? List<String>.from(this.connections),
      filePath: filePath ?? this.filePath,
      metadata: metadata ?? Map<String, dynamic>.from(this.metadata),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'label': label,
      'visual': visual.wireValue,
      'position': <String, double>{'x': position.dx, 'y': position.dy},
      'size': <String, double>{'width': size.width, 'height': size.height},
      'connections': connections,
      if (filePath != null) 'filePath': filePath,
      if (metadata.isNotEmpty) 'metadata': metadata,
    };
  }

  factory RvgNode.fromJson(Map<String, dynamic> json) {
    final Map<String, dynamic> positionJson =
        (json['position'] as Map).cast<String, num>();
    final Map<String, dynamic> sizeJson =
        (json['size'] as Map).cast<String, num>();
    return RvgNode(
      id: json['id'] as String,
      label: json['label'] as String,
      visual: RvgVisualTypeWire.parse(json['visual'] as String? ?? 'rectangle'),
      position: Offset(
        (positionJson['x'] ?? 0).toDouble(),
        (positionJson['y'] ?? 0).toDouble(),
      ),
      size: Size(
        (sizeJson['width'] ?? 0).toDouble(),
        (sizeJson['height'] ?? 0).toDouble(),
      ),
      connections:
          (json['connections'] as List?)
              ?.map((dynamic value) => value as String)
              .toList() ??
          const <String>[],
      filePath: json['filePath'] as String?,
      metadata:
          (json['metadata'] as Map?)?.cast<String, dynamic>() ??
          const <String, dynamic>{},
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is RvgNode &&
        other.id == id &&
        other.label == label &&
        other.visual == visual &&
        other.position == position &&
        other.size == size &&
        listEquals(other.connections, connections) &&
        other.filePath == filePath &&
        mapEquals(other.metadata, metadata);
  }

  @override
  int get hashCode => Object.hashAll(<Object?>[
    id,
    label,
    visual,
    position.dx,
    position.dy,
    size.width,
    size.height,
    Object.hashAll(connections),
    filePath,
    Object.hashAll(
      metadata.entries.map(
        (MapEntry<String, dynamic> entry) =>
            Object.hash(entry.key, entry.value),
      ),
    ),
  ]);
}

class RvgDocument {
  const RvgDocument({
    required this.version,
    required this.createdAt,
    required this.updatedAt,
    required this.nodes,
    this.attributes = const {},
  });

  final String version;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<RvgNode> nodes;
  final Map<String, dynamic> attributes;

  RvgDocument copyWith({
    String? version,
    DateTime? createdAt,
    DateTime? updatedAt,
    List<RvgNode>? nodes,
    Map<String, dynamic>? attributes,
  }) {
    return RvgDocument(
      version: version ?? this.version,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      nodes: nodes ?? List<RvgNode>.from(this.nodes),
      attributes: attributes ?? Map<String, dynamic>.from(this.attributes),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'version': version,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'nodes': nodes.map((RvgNode node) => node.toJson()).toList(),
      if (attributes.isNotEmpty) 'attributes': attributes,
    };
  }

  factory RvgDocument.fromJson(Map<String, dynamic> json) {
    return RvgDocument(
      version: json['version'] as String? ?? '1.0.0',
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      updatedAt:
          DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      nodes:
          (json['nodes'] as List? ?? const <dynamic>[])
              .map(
                (dynamic raw) =>
                    RvgNode.fromJson((raw as Map).cast<String, dynamic>()),
              )
              .toList(),
      attributes:
          (json['attributes'] as Map?)?.cast<String, dynamic>() ??
          const <String, dynamic>{},
    );
  }

  RvgNode? nodeById(String id) {
    for (final RvgNode node in nodes) {
      if (node.id == id) {
        return node;
      }
    }
    return null;
  }

  RvgDocument updateNode(String id, RvgNode Function(RvgNode node) transform) {
    bool mutated = false;
    final List<RvgNode> updatedNodes = <RvgNode>[];
    for (final RvgNode node in nodes) {
      if (node.id == id) {
        final RvgNode transformed = transform(node);
        updatedNodes.add(transformed);
        mutated = mutated || transformed != node;
      } else {
        updatedNodes.add(node);
      }
    }
    if (!mutated) {
      return this;
    }
    return copyWith(nodes: updatedNodes, updatedAt: DateTime.now().toUtc());
  }

  static RvgDocument demo() {
    final DateTime now = DateTime.now().toUtc();
    return RvgDocument(
      version: '1.0.0',
      createdAt: now,
      updatedAt: now,
      nodes: <RvgNode>[
        const RvgNode(
          id: 'api',
          label: 'API Gateway',
          visual: RvgVisualType.rectangle,
          position: Offset(180, 160),
          size: Size(200, 96),
          connections: <String>['auth', 'orders', 'analytics'],
        ),
        const RvgNode(
          id: 'auth',
          label: 'Auth Service',
          visual: RvgVisualType.rectangle,
          position: Offset(520, 120),
          size: Size(190, 90),
          connections: <String>['users'],
        ),
        const RvgNode(
          id: 'orders',
          label: 'Orders',
          visual: RvgVisualType.rectangle,
          position: Offset(520, 340),
          size: Size(190, 90),
          connections: <String>['payments', 'shipments'],
        ),
        const RvgNode(
          id: 'analytics',
          label: 'Analytics',
          visual: RvgVisualType.circle,
          position: Offset(260, 480),
          size: Size(160, 160),
          connections: <String>['warehouse'],
        ),
        const RvgNode(
          id: 'users',
          label: 'Users DB',
          visual: RvgVisualType.rectangle,
          position: Offset(820, 80),
          size: Size(200, 96),
        ),
        const RvgNode(
          id: 'payments',
          label: 'Payments',
          visual: RvgVisualType.rectangle,
          position: Offset(820, 300),
          size: Size(200, 96),
          connections: <String>['ledger'],
        ),
        const RvgNode(
          id: 'shipments',
          label: 'Shipments',
          visual: RvgVisualType.rectangle,
          position: Offset(820, 460),
          size: Size(200, 96),
        ),
        const RvgNode(
          id: 'warehouse',
          label: 'Warehouse\nReporting',
          visual: RvgVisualType.rectangle,
          position: Offset(560, 560),
          size: Size(220, 110),
        ),
        const RvgNode(
          id: 'ledger',
          label: 'Finance Ledger',
          visual: RvgVisualType.circle,
          position: Offset(1100, 320),
          size: Size(150, 150),
        ),
      ],
    );
  }

  @override
  String toString() => jsonEncode(toJson());
}
