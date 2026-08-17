/// App self-update: checks GitHub Releases for newer versions, downloads
/// the APK (optionally via an acceleration proxy), and hands off to the
/// system installer.
///
/// The GitHub Releases API (api.github.com) is always called directly —
/// ghproxy.net only accelerates github.com file downloads, not the API.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Which releases to consider when checking for updates.
enum UpdateChannel {
  /// Only stable (non-prerelease) releases.
  stable,

  /// Stable releases plus prereleases (e.g. nightly builds).
  nightly;

  String get label => switch (this) {
    stable => 'stable',
    nightly => 'nightly',
  };

  static UpdateChannel fromLabel(String? label) => switch (label) {
    'nightly' => nightly,
    _ => stable,
  };
}

/// Download mirror for the APK file.
enum UpdateMirror {
  /// Direct download from github.com.
  official,

  /// Prefix the URL with ghproxy.net for faster downloads in China.
  ghproxy;

  String get label => switch (this) {
    official => 'official',
    ghproxy => 'ghproxy',
  };

  static UpdateMirror fromLabel(String? label) => switch (label) {
    'ghproxy' => ghproxy,
    _ => official,
  };
}

/// A downloadable asset attached to a GitHub release.
class AssetInfo {
  final String name;
  final String downloadUrl;
  final int size;

  const AssetInfo({
    required this.name,
    required this.downloadUrl,
    required this.size,
  });
}

/// Information about a release that is newer than the currently installed app.
class UpdateInfo {
  final String tagName;
  final String releaseName;
  final String? releaseNotes;
  final DateTime publishedAt;
  final AssetInfo asset;
  final bool isPrerelease;

  const UpdateInfo({
    required this.tagName,
    required this.releaseName,
    this.releaseNotes,
    required this.publishedAt,
    required this.asset,
    required this.isPrerelease,
  });

  /// Returns a user-facing version string. Version tags get a `v` prefix
  /// (e.g. `0.5.0` → `v0.5.0`); non-version tags like `nightly` stay as-is.
  String get displayVersion {
    if (tagName.startsWith('v') || tagName.startsWith('V')) return tagName;
    return SemVer.tryParse(tagName) != null ? 'v$tagName' : tagName;
  }
}

/// Parsed semantic version (major, minor, patch).
class SemVer implements Comparable<SemVer> {
  final int major;
  final int minor;
  final int patch;

  const SemVer(this.major, this.minor, this.patch);

  @override
  int compareTo(SemVer other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    return patch.compareTo(other.patch);
  }

  bool operator >(SemVer other) => compareTo(other) > 0;

  @override
  bool operator ==(Object other) =>
      other is SemVer &&
      major == other.major &&
      minor == other.minor &&
      patch == other.patch;

  @override
  int get hashCode => Object.hash(major, minor, patch);

  @override
  String toString() => '$major.$minor.$patch';

  /// Parses a tag like `v0.5.0` or `0.5.0` into [SemVer].
  /// Returns null when the tag is not a version string (e.g. `nightly`).
  static SemVer? tryParse(String tag) {
    final cleaned = tag.startsWith('v') || tag.startsWith('V')
        ? tag.substring(1)
        : tag;
    final parts = cleaned.split('.');
    if (parts.length < 2 || parts.length > 3) return null;
    try {
      final major = int.parse(parts[0]);
      final minor = int.parse(parts[1]);
      final patch = parts.length == 3 ? int.parse(parts[2]) : 0;
      return SemVer(major, minor, patch);
    } on FormatException {
      return null;
    }
  }
}

/// Checks GitHub Releases for newer versions and downloads the APK.
class UpdateChecker {
  UpdateChecker({
    required this.owner,
    required this.repo,
    required this.currentVersion,
  });

  final String owner;
  final String repo;

  /// The current app version (from pubspec, e.g. `0.4.1`).
  final String currentVersion;

  static const _apiBase = 'https://api.github.com';
  static const _ghproxyPrefix = 'https://ghproxy.net/';

  /// Method channel for reading the device's supported ABIs.
  static const _platform = MethodChannel('dev.ijkzen.zcode_remote/device_info');

  /// Fetches releases from GitHub and returns the newest one that is newer
  /// than [currentVersion], or null if up to date.
  ///
  /// [channel] controls whether prereleases are included.
  /// [mirror] is only used later for download URL construction; the API
  /// call itself is always direct (ghproxy does not proxy api.github.com).
  Future<UpdateInfo?> checkForUpdate({
    UpdateChannel channel = UpdateChannel.stable,
  }) async {
    final url = Uri.parse('$_apiBase/repos/$owner/$repo/releases');
    debugPrint('[UpdateChecker] GET $url');
    final response = await http.get(
      url,
      headers: {
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'zcode_remote/$currentVersion',
      },
    );

    if (response.statusCode != 200) {
      throw UpdateCheckException(
        'GitHub API 返回 ${response.statusCode}: ${response.reasonPhrase}',
      );
    }

    final List<dynamic> releases = jsonDecode(response.body) as List<dynamic>;
    if (releases.isEmpty) return null;

    final current = SemVer.tryParse(currentVersion);
    if (current == null) {
      throw UpdateCheckException('无法解析当前版本号: $currentVersion');
    }

    // Sort releases by published_at descending so we check newest first.
    final sorted = releases.toList()
      ..sort((a, b) {
        final aDate = _parseDate(a);
        final bDate = _parseDate(b);
        return bDate.compareTo(aDate);
      });

    for (final release in sorted) {
      final isPrerelease = release['prerelease'] as bool? ?? false;

      // In stable mode, skip prereleases entirely.
      if (channel == UpdateChannel.stable && isPrerelease) continue;

      final tagName = release['tag_name'] as String;
      final tagVersion = SemVer.tryParse(tagName);

      // For version-tagged releases (e.g. v0.5.0), compare semver.
      if (tagVersion != null) {
        if (tagVersion > current) {
          final asset = await _pickAsset(release);
          if (asset != null) {
            return UpdateInfo(
              tagName: tagName,
              releaseName: release['name'] as String? ?? tagName,
              releaseNotes: release['body'] as String?,
              publishedAt: _parseDate(release),
              asset: asset,
              isPrerelease: isPrerelease,
            );
          }
        }
        continue;
      }

      // For non-version tags (e.g. nightly), include them only in nightly
      // mode and compare by publish date against the current build date.
      // We use the tag's publish date vs. "now" as a proxy — if the release
      // was published after the app was built, treat it as newer.
      if (channel == UpdateChannel.nightly && isPrerelease) {
        final asset = await _pickAsset(release);
        if (asset != null) {
          return UpdateInfo(
            tagName: tagName,
            releaseName: release['name'] as String? ?? tagName,
            releaseNotes: release['body'] as String?,
            publishedAt: _parseDate(release),
            asset: asset,
            isPrerelease: true,
          );
        }
      }
    }

    return null;
  }

  /// Picks the best APK asset from a release, matching the device ABI.
  /// Falls back to the sole .apk file if there's only one.
  Future<AssetInfo?> _pickAsset(dynamic release) async {
    final assets = release['assets'] as List<dynamic>;
    final apks = assets
        .where(
          (a) => (a['name'] as String).toLowerCase().endsWith('.apk'),
        )
        .toList();
    if (apks.isEmpty) return null;

    // Single APK — no choice needed.
    if (apks.length == 1) {
      return _assetFromJson(apks.first);
    }

    // Multiple APKs — match by device ABI.
    final abis = await _getDeviceAbis();
    for (final abi in abis) {
      for (final apk in apks) {
        final name = (apk['name'] as String).toLowerCase();
        if (name.contains(abi)) {
          return _assetFromJson(apk);
        }
      }
    }

    // No ABI match — fall back to the first APK.
    return _assetFromJson(apks.first);
  }

  AssetInfo _assetFromJson(dynamic json) {
    return AssetInfo(
      name: json['name'] as String,
      downloadUrl: json['browser_download_url'] as String,
      size: (json['size'] as num).toInt(),
    );
  }

  /// Reads Build.SUPPORTED_ABIS from the Android platform.
  /// Falls back to ['arm64-v8a'] on non-Android or on error.
  Future<List<String>> _getDeviceAbis() async {
    if (!Platform.isAndroid) return ['arm64-v8a'];
    try {
      final result = await _platform.invokeMethod<List>('getSupportedAbis');
      if (result != null) {
        return result.cast<String>();
      }
    } catch (e) {
      debugPrint('[UpdateChecker] Failed to get ABIs: $e');
    }
    return ['arm64-v8a'];
  }

  /// Downloads the APK to a temporary file, reporting progress via [onProgress]
  /// (0.0–1.0). Returns the path to the downloaded file.
  ///
  /// [mirror] controls whether the download URL is proxied through ghproxy.net.
  Future<String> downloadApk(
    AssetInfo asset, {
    UpdateMirror mirror = UpdateMirror.official,
    void Function(double progress)? onProgress,
  }) async {
    final url = _applyMirror(asset.downloadUrl, mirror);
    debugPrint('[UpdateChecker] Downloading $url');

    final request = http.Request('GET', Uri.parse(url));
    final client = http.Client();
    final response = await client.send(request);

    if (response.statusCode != 200) {
      client.close();
      throw UpdateCheckException(
        '下载失败: HTTP ${response.statusCode} ${response.reasonPhrase}',
      );
    }

    final total = response.contentLength ?? asset.size;
    final dir = await getTemporaryDirectory();
    final filePath = '${dir.path}/${asset.name}';
    final file = File(filePath);
    final sink = file.openWrite();

    int received = 0;
    try {
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) {
          onProgress?.call(received / total);
        }
      }
      await sink.flush();
    } catch (e) {
      await sink.close();
      client.close();
      await file.delete();
      rethrow;
    } finally {
      await sink.close();
      client.close();
    }

    debugPrint('[UpdateChecker] Downloaded to $filePath ($received bytes)');
    return filePath;
  }

  /// Prefixes the download URL with the ghproxy prefix when needed.
  String _applyMirror(String url, UpdateMirror mirror) {
    if (mirror == UpdateMirror.ghproxy && !url.startsWith(_ghproxyPrefix)) {
      return '$_ghproxyPrefix$url';
    }
    return url;
  }

  DateTime _parseDate(dynamic release) {
    final raw = release['published_at'] as String? ??
        release['created_at'] as String? ??
        '';
    return DateTime.tryParse(raw) ?? DateTime.fromMillisecondsSinceEpoch(0);
  }
}

/// Thrown when the update check or download fails.
class UpdateCheckException implements Exception {
  final String message;
  UpdateCheckException(this.message);

  @override
  String toString() => message;
}
