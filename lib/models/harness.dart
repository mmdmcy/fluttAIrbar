enum HarnessUpdateSource { npm, githubRelease, officialChannel }

class HarnessConfigSpec {
  const HarnessConfigSpec({
    required this.label,
    required this.pathTemplate,
    this.sensitive = false,
  });

  final String label;
  final String pathTemplate;
  final bool sensitive;
}

class HarnessDefinition {
  const HarnessDefinition({
    required this.id,
    required this.displayName,
    required this.executable,
    required this.versionArgs,
    required this.updateArgs,
    required this.updateSource,
    required this.configs,
    this.npmPackage,
    this.npmPackages = const [],
    this.releaseRepository,
    this.checkArgs,
    this.description,
    this.supportsUpdate = true,
    this.updatePackageInPlace = false,
  });

  final String id;
  final String displayName;
  final String executable;
  final List<String> versionArgs;
  final List<String> updateArgs;
  final HarnessUpdateSource updateSource;
  final List<HarnessConfigSpec> configs;
  final String? npmPackage;
  final List<String> npmPackages;
  final String? releaseRepository;
  final List<String>? checkArgs;
  final String? description;
  final bool supportsUpdate;
  final bool updatePackageInPlace;

  bool get requiresReleaseAge =>
      updateSource == HarnessUpdateSource.npm ||
      updateSource == HarnessUpdateSource.githubRelease;

  List<String> get packageCandidates => [
    if (npmPackage != null && npmPackage!.isNotEmpty) npmPackage!,
    ...npmPackages,
  ];
}

class HarnessConfigFile {
  const HarnessConfigFile({
    required this.label,
    required this.path,
    required this.sensitive,
    required this.exists,
    this.summary,
  });

  final String label;
  final String path;
  final bool sensitive;
  final bool exists;
  final String? summary;
}

class HarnessRelease {
  const HarnessRelease({
    required this.latestVersion,
    required this.source,
    this.publishedAt,
  });

  final String latestVersion;
  final HarnessUpdateSource source;
  final DateTime? publishedAt;

  bool isNewerThan(String currentVersion) =>
      compareVersions(latestVersion, currentVersion) > 0;

  bool ageGateSatisfied({
    DateTime? now,
    Duration minimumAge = const Duration(days: 14),
  }) {
    final published = publishedAt?.toUtc();
    if (published == null) return false;
    final reference = (now ?? DateTime.now()).toUtc();
    return !published.isAfter(reference.subtract(minimumAge));
  }

  String get ageLabel {
    final published = publishedAt;
    if (published == null) return 'release age unavailable';
    final elapsed = DateTime.now().toUtc().difference(published.toUtc());
    if (elapsed.isNegative) return 'release is dated in the future';
    final days = elapsed.inDays;
    if (days == 0) return 'released today';
    if (days == 1) return 'released 1 day ago';
    return 'released $days days ago';
  }
}

class HarnessStatus {
  const HarnessStatus({
    required this.definition,
    required this.configs,
    this.executablePath,
    this.currentVersion,
    this.release,
    this.checkError,
  });

  final HarnessDefinition definition;
  final List<HarnessConfigFile> configs;
  final String? executablePath;
  final String? currentVersion;
  final HarnessRelease? release;
  final String? checkError;

  bool get installed => executablePath != null;

  bool get updateAvailable =>
      installed &&
      currentVersion != null &&
      release != null &&
      release!.isNewerThan(currentVersion!);

  bool get updateCandidate =>
      definition.supportsUpdate &&
      checkError == null &&
      updateAvailable &&
      (!definition.requiresReleaseAge || release!.publishedAt != null);

  bool ageGateSatisfied({DateTime? now}) {
    if (!definition.requiresReleaseAge) return true;
    return release?.ageGateSatisfied(now: now) ?? false;
  }
}

enum HarnessUpdateOutcome { updated, skipped, upToDate, failed }

enum HarnessUpdatePhase {
  idle,
  queued,
  updating,
  updated,
  upToDate,
  skipped,
  failed,
}

class HarnessUpdateResult {
  const HarnessUpdateResult({
    required this.status,
    required this.outcome,
    required this.message,
    this.exitCode,
  });

  final HarnessStatus status;
  final HarnessUpdateOutcome outcome;
  final String message;
  final int? exitCode;
}

class HarnessUpdateReport {
  const HarnessUpdateReport(this.results);

  final List<HarnessUpdateResult> results;

  int get updatedCount => results
      .where((result) => result.outcome == HarnessUpdateOutcome.updated)
      .length;

  int get skippedCount => results
      .where((result) => result.outcome == HarnessUpdateOutcome.skipped)
      .length;

  int get upToDateCount => results
      .where((result) => result.outcome == HarnessUpdateOutcome.upToDate)
      .length;

  int get failedCount => results
      .where((result) => result.outcome == HarnessUpdateOutcome.failed)
      .length;
}

int compareVersions(String left, String right) {
  final leftVersion = _Version.parse(left);
  final rightVersion = _Version.parse(right);
  if (leftVersion == null || rightVersion == null) {
    return left.compareTo(right);
  }

  for (var index = 0; index < 3; index++) {
    final comparison = leftVersion.core[index].compareTo(
      rightVersion.core[index],
    );
    if (comparison != 0) return comparison;
  }

  if (leftVersion.prerelease == null && rightVersion.prerelease == null) {
    return 0;
  }
  if (leftVersion.prerelease == null) return 1;
  if (rightVersion.prerelease == null) return -1;

  final leftParts = leftVersion.prerelease!.split('.');
  final rightParts = rightVersion.prerelease!.split('.');
  final length = leftParts.length < rightParts.length
      ? leftParts.length
      : rightParts.length;
  for (var index = 0; index < length; index++) {
    final leftPart = leftParts[index];
    final rightPart = rightParts[index];
    final leftNumber = int.tryParse(leftPart);
    final rightNumber = int.tryParse(rightPart);
    final comparison = leftNumber != null && rightNumber != null
        ? leftNumber.compareTo(rightNumber)
        : leftNumber != null
        ? -1
        : rightNumber != null
        ? 1
        : leftPart.compareTo(rightPart);
    if (comparison != 0) return comparison;
  }
  return leftParts.length.compareTo(rightParts.length);
}

class _Version {
  const _Version(this.core, this.prerelease);

  final List<int> core;
  final String? prerelease;

  static _Version? parse(String value) {
    final match = RegExp(
      r'^\s*[v=]?([0-9]+)(?:\.([0-9]+))?(?:\.([0-9]+))?(?:-([0-9A-Za-z.-]+))?',
    ).firstMatch(value);
    if (match == null) return null;
    return _Version([
      int.parse(match.group(1)!),
      int.tryParse(match.group(2) ?? '') ?? 0,
      int.tryParse(match.group(3) ?? '') ?? 0,
    ], match.group(4));
  }
}
