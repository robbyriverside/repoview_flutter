/// Visual categories supported by RVG documents.
enum RvgVisualType { rectangle, circle, folder, file, external, note }

extension RvgVisualTypeWire on RvgVisualType {
  String get wireValue {
    switch (this) {
      case RvgVisualType.rectangle:
        return 'rectangle';
      case RvgVisualType.circle:
        return 'circle';
      case RvgVisualType.folder:
        return 'folder';
      case RvgVisualType.file:
        return 'file';
      case RvgVisualType.external:
        return 'external';
      case RvgVisualType.note:
        return 'note';
    }
  }

  static RvgVisualType parse(String value) {
    switch (value) {
      case 'circle':
        return RvgVisualType.circle;
      case 'folder':
        return RvgVisualType.folder;
      case 'file':
        return RvgVisualType.file;
      case 'external':
        return RvgVisualType.external;
      case 'note':
        return RvgVisualType.note;
      case 'rectangle':
      default:
        return RvgVisualType.rectangle;
    }
  }
}
