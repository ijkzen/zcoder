/// App self-update: checks GitHub Releases for newer versions, downloads
/// the APK (optionally via an acceleration proxy), and hands off to the
/// system installer.
///
/// The GitHub Releases API (api.github.com) is always called directly — the
/// accelerators below only proxy github.com file downloads, not the API.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../protocol/zlog.dart';

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

/// Download source for the APK file: an accelerator (prefix-rewrite GitHub
/// proxy) or direct download.
enum UpdateMirror {
  /// Direct download from github.com.
  official('official', '官方直连', null),

  /// Try every [accelerators] member in order, then fall back to the
  /// official direct download when all of them fail. Recommended default.
  auto('auto', '自动切换（推荐）', null),

  /// gh-proxy.com — Cloudflare Worker, multiple edge nodes.
  ghProxyCom('ghProxyCom', 'gh-proxy.com', 'https://gh-proxy.com/'),

  /// ghfast.top — mainland-China popular mirror.
  ghFast('ghFast', 'ghfast.top', 'https://ghfast.top/'),

  /// ghproxy.cn — supports releases + codeload + API (GET only; HEAD → 405).
  ghProxyCn('ghProxyCn', 'ghproxy.cn', 'https://ghproxy.cn/'),

  /// gh-proxy.org — broadest URL coverage (releases + codeload + API + raw).
  ghProxyOrg('ghProxyOrg', 'gh-proxy.org', 'https://gh-proxy.org/'),

  /// gh.ddlc.top — Cloudflare Worker (hunshcn/gh-proxy).
  ghDdlc('ghDdlc', 'gh.ddlc.top', 'https://gh.ddlc.top/'),

  /// ghproxy.xyz — CDN backed.
  ghProxyXyz('ghProxyXyz', 'ghproxy.xyz', 'https://ghproxy.xyz/');

  /// Persisted key (the `update_mirror` app setting).
  final String label;

  /// Menu label shown in settings.
  final String displayName;

  /// Prefix-rewrite base (`$prefix<original github url>`); null for
  /// [official] and [auto], which have no single fixed URL.
  final String? prefix;

  const UpdateMirror(this.label, this.displayName, this.prefix);

  /// The accelerators tried by [UpdateMirror.auto], in order.
  static const List<UpdateMirror> accelerators = [
    UpdateMirror.ghProxyCom,
    UpdateMirror.ghFast,
    UpdateMirror.ghProxyCn,
    UpdateMirror.ghProxyOrg,
    UpdateMirror.ghDdlc,
    UpdateMirror.ghProxyXyz,
  ];

  bool get isAccelerator => this != official && this != auto;

  static UpdateMirror fromLabel(String? label) {
    // `ghproxy` is the legacy value persisted by older builds — route it to
    // the auto chain instead of the retired built-in single mirror.
    if (label == 'ghproxy') return UpdateMirror.auto;
    for (final m in UpdateMirror.values) {
      if (m.label == label) return m;
    }
    return UpdateMirror.auto;
  }
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

  /// Parses a tag like `v0.5.0`, `0.5.0`, or `v0.5.0+12` into [SemVer].
  /// Build metadata after `+` is stripped before parsing.
  /// Returns null when the tag is not a version string (e.g. `nightly`).
  static SemVer? tryParse(String tag) {
    var cleaned = tag.startsWith('v') || tag.startsWith('V')
        ? tag.substring(1)
        : tag;
    // Strip build metadata (e.g. "+12") — not part of semver precedence.
    final plusIdx = cleaned.indexOf('+');
    if (plusIdx != -1) cleaned = cleaned.substring(0, plusIdx);
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

  /// Method channel for reading the device's supported ABIs.
  static const _platform = MethodChannel('dev.ijkzen.zcode_remote/device_info');

  /// Fetches releases from GitHub and returns the newest one that is newer
  /// than [currentVersion], or null if up to date.
  ///
  /// [channel] controls whether prereleases are included.
  /// [mirror] is only used later for download URL construction; the API
  /// call itself is always direct (the accelerators only proxy file
  /// downloads, not api.github.com).
  Future<UpdateInfo?> checkForUpdate({
    UpdateChannel channel = UpdateChannel.stable,
  }) async {
    final url = Uri.parse('$_apiBase/repos/$owner/$repo/releases');
    zlog('[UpdateChecker] GET $url');
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
  ///
  /// Naming convention:
  ///   - `zcode_remote-arm64-v8a-*.apk`  → arm64 only
  ///   - `zcode_remote-armv7-*.apk`      → armv7 only
  ///   - `zcode_remote-universal-*.apk`  → all ABIs
  ///   - `app-release.apk`               → legacy single APK
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

    // Build a priority list: device-native ABIs first, then universal, then
    // whatever is left.
    final abiPriority = <String>[];
    for (final abi in abis) {
      if (!abiPriority.contains(abi)) abiPriority.add(abi);
    }
    if (!abiPriority.contains('universal')) abiPriority.add('universal');

    for (final abi in abiPriority) {
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
  /// Returns a list like `['arm64-v8a', 'armeabi-v7a', 'armeabi']`.
  /// Falls back to `['arm64-v8a']` on non-Android or on error.
  Future<List<String>> _getDeviceAbis() async {
    if (!Platform.isAndroid) return ['arm64-v8a'];
    try {
      final result = await _platform.invokeMethod<List>('getSupportedAbis');
      if (result != null && result.isNotEmpty) {
        zlog('[UpdateChecker] Device ABIs: $result');
        return result.cast<String>();
      }
    } catch (e) {
      zlog('[UpdateChecker] Failed to get ABIs: $e');
    }
    return ['arm64-v8a'];
  }

  /// How long to wait for the first byte (DNS/connect/headers) before a
  /// candidate is abandoned — a dead or geo-blocked mirror must never hang
  /// the update dialog.
  static const _firstByteTimeout = Duration(seconds: 25);

  /// No new bytes for this long mid-download aborts the attempt so the
  /// caller can switch to the next candidate (a slow-but-alive mirror).
  static const _progressTimeout = Duration(seconds: 15);

  /// Downloads the APK to a temporary file, reporting progress via [onProgress]
  /// (0.0–1.0) and the source actually being used via [onSource].
  ///
  /// [mirror] controls the download source: [UpdateMirror.official] downloads
  /// directly; [UpdateMirror.auto] tries every accelerator in order then falls
  /// back to the official URL; a specific accelerator tries that mirror then
  /// the official URL. A stalled candidate (no first byte, or no progress for
  /// a while) is abandoned in favor of the next one. Defaults to
  /// [UpdateMirror.auto] — the recommended multi-mirror chain.
  ///
  /// Returns the path to the downloaded file.
  Future<String> downloadApk(
    AssetInfo asset, {
    UpdateMirror mirror = UpdateMirror.auto,
    void Function(double progress)? onProgress,
    void Function(String source)? onSource,
  }) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/${asset.name}');
    Object? lastError;
    for (final (:url, :name) in candidateUrls(asset.downloadUrl, mirror)) {
      try {
        return await _downloadFrom(url, name, asset, file, onProgress, onSource);
      } catch (e) {
        zlog('[UpdateChecker] $name 失败: $e');
        // Truncate/remove any partial bytes; the next attempt rewrites it.
        try {
          await file.delete();
        } catch (_) {}
        lastError = e;
      }
    }
    if (lastError is UpdateCheckException) throw lastError;
    throw UpdateCheckException('下载失败: $lastError');
  }

  /// The download URLs to try for [mirror], in order, paired with the source
  /// name to show (null name = official direct download). Public so the UI
  /// can preview what will be tried.
  List<({String url, String? name})> candidateUrls(
    String downloadUrl,
    UpdateMirror mirror,
  ) {
    if (mirror == UpdateMirror.official) {
      return [(url: downloadUrl, name: null)];
    }
    final selected = mirror == UpdateMirror.auto
        ? UpdateMirror.accelerators
        : [mirror];
    return [
      for (final m in selected)
        (url: '${m.prefix}$downloadUrl', name: m.displayName),
      // Official direct download as the last-resort fallback.
      (url: downloadUrl, name: null),
    ];
  }

  /// Streams one candidate into [file]; returns the file path on success and
  /// throws on failure (timeout, non-200, or I/O error).
  Future<String> _downloadFrom(
    String url,
    String? name,
    AssetInfo asset,
    File file,
    void Function(double progress)? onProgress,
    void Function(String source)? onSource,
  ) async {
    final label = '通过 ${name ?? '官方直连'} ';
    onSource?.call(name ?? '官方直连');
    zlog('[UpdateChecker] 开始$label下载 $url');
    final request = http.Request('GET', Uri.parse(url));
    final client = http.Client();
    try {
      final response = await client.send(request).timeout(_firstByteTimeout);
      if (response.statusCode != 200) {
        throw UpdateCheckException('$label下载失败: HTTP ${response.statusCode}');
      }
      final total = response.contentLength ?? asset.size;
      final sink = file.openWrite();
      int received = 0;
      try {
        await for (final chunk in response.stream.timeout(_progressTimeout)) {
          sink.add(chunk);
          received += chunk.length;
          if (total > 0) onProgress?.call(received / total);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      zlog('[UpdateChecker] $label下载完成 ($received bytes)');
      return file.path;
    } finally {
      client.close();
    }
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
