abstract class UsageProvider {
  String get id;
  String get displayName;
  Future<void> refresh();
}
