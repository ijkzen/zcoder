/// App self-update: checks GitHub Releases for newer versions, downloads
/// the APK (optionally via an acceleration proxy), and hands off to the
/// system installer.
///
/// The GitHub Releases API (api.github.com) is always called directly — the
/// accelerators below only proxy github.com file downloads, not the API.
library;

import 'dart:async';
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

  /// Races every [accelerators] member plus the official direct download
  /// concurrently, keeps the fastest connection, and re-races the survivors
  /// if the winner fails mid-download. Recommended default.
  auto('auto', '自动测速（推荐）', null),

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

  /// The accelerators raced by [UpdateMirror.auto]. Order is only a
  /// tie-breaker — all of them start downloading concurrently and the
  /// fastest connection wins.
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

/// Marker written by release.yml between the user-facing changelog (the
/// annotated tag message) and the build metadata / APK variant tables.
/// The update dialog only shows the part before it.
const kReleaseNotesBuildInfoMarker = '<!-- build-info -->';

/// Trims a GitHub release body at the build-info marker so the update
/// dialog shows only the changelog. Bodies without the marker (older
/// releases) are returned unchanged; if trimming would leave nothing
/// (releases that fell back to GitHub's auto-generated notes, which are
/// appended after the marker), the full body is returned.
String? trimReleaseNotes(String? body) {
  if (body == null) return null;
  final marker = body.indexOf(kReleaseNotesBuildInfoMarker);
  if (marker < 0) return body;
  var notes = body.substring(0, marker).trim();
  // release.yml separates the changelog from the build info with an `---`
  // rule; don't leave it dangling at the bottom of the dialog.
  notes = notes
      .replaceFirst(RegExp(r'\n{0,2}(?:---|\*\*\*|___)$'), '')
      .trim();
  return notes.isEmpty ? body : notes;
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
              releaseNotes: trimReleaseNotes(release['body'] as String?),
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
            releaseNotes: trimReleaseNotes(release['body'] as String?),
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

  /// How much real file data a race contestant must stream to win the probe
  /// phase outright: the first candidate to deliver this many bytes is the
  /// fastest in practice and keeps its connection — the probe bytes are the
  /// start of the actual file, so nothing is downloaded twice.
  static const _probeBytes = 512 * 1024;

  /// When nobody reaches [_probeBytes] within this window, the contestant
  /// with the most bytes so far wins — covers the "everyone alive but slow"
  /// case.
  static const _probeDeadline = Duration(seconds: 20);

  /// Downloads the APK to a temporary file, reporting progress via [onProgress]
  /// (0.0–1.0) and the source actually being used via [onSource].
  ///
  /// [mirror] controls the download source: [UpdateMirror.official] downloads
  /// directly; [UpdateMirror.auto] races every accelerator plus the official
  /// URL concurrently and keeps the fastest connection (see [downloadRacing]);
  /// a specific accelerator tries that mirror then falls back to the official
  /// URL. Defaults to [UpdateMirror.auto] — the recommended multi-mirror mode.
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
    if (mirror == UpdateMirror.auto) {
      return downloadRacing(
        candidateUrls(asset.downloadUrl, mirror),
        asset,
        file,
        onProgress: onProgress,
        onSource: onSource,
      );
    }
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

  /// The concurrent download race behind [UpdateMirror.auto]: every candidate
  /// starts streaming the file at once, the first to deliver [probeBytes]
  /// real bytes wins and keeps its connection (probe bytes are the head of
  /// the actual file), the losers are cancelled. If nobody reaches the
  /// threshold within [probeDeadline] the current byte-count leader wins; if
  /// the winner then fails mid-download, the surviving candidates race again
  /// from scratch. Throws [UpdateCheckException] when every candidate dies.
  Future<String> downloadRacing(
    List<({String url, String? name})> candidates,
    AssetInfo asset,
    File file, {
    void Function(double progress)? onProgress,
    void Function(String source)? onSource,
    Duration probeDeadline = _probeDeadline,
    int probeBytes = _probeBytes,
    Duration progressTimeout = _progressTimeout,
  }) async {
    var remaining = candidates;
    Object? lastError;
    while (remaining.isNotEmpty) {
      try {
        return await _raceOnce(
          remaining,
          asset,
          file,
          onProgress: onProgress,
          onSource: onSource,
          probeDeadline: probeDeadline,
          probeBytes: probeBytes,
          progressTimeout: progressTimeout,
        );
      } on _RaceRoundException catch (e) {
        zlog('[UpdateChecker] 本轮竞速失败，${e.failed.length} 个源出局: ${e.cause}');
        lastError = e.cause;
        remaining = [
          for (var i = 0; i < remaining.length; i++)
            if (!e.failed.contains(i)) remaining[i],
        ];
      }
    }
    throw UpdateCheckException('下载失败: $lastError');
  }

  /// The download URLs for [mirror], paired with the source name to show
  /// (null name = official direct download). For [UpdateMirror.auto] this is
  /// the full race field — every accelerator plus the official URL; for a
  /// specific mirror it is that mirror followed by the official fallback.
  /// Public so the UI can preview the sources.
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

  /// One round of the race: every candidate in [candidates] streams into its
  /// own probe file until a winner emerges. On success the winner's probe
  /// file is renamed to [file] and its path returned. On failure a
  /// [_RaceRoundException] carries the indices of the dead candidates so the
  /// caller can re-race the survivors.
  Future<String> _raceOnce(
    List<({String url, String? name})> candidates,
    AssetInfo asset,
    File file, {
    void Function(double progress)? onProgress,
    void Function(String source)? onSource,
    required Duration probeDeadline,
    required int probeBytes,
    required Duration progressTimeout,
  }) async {
    final contestants = <_RaceContestant>[
      for (var i = 0; i < candidates.length; i++)
        _RaceContestant(
          url: candidates[i].url,
          name: candidates[i].name,
          file: File('${file.path}.race$i'),
        ),
    ];

    final winnerFound = Completer<_RaceContestant?>();
    Timer? deadlineTimer;
    _RaceContestant? winner;

    void reportProgress() {
      if (onProgress == null) return;
      final w = winner;
      if (w != null) {
        // After the probe phase only the winner's bytes count.
        if (w.total > 0) {
          final v = w.received / w.total;
          onProgress(v > 1.0 ? 1.0 : v);
        }
      } else {
        // During the probe phase show the leading edge across all candidates.
        var maxReceived = 0;
        for (final c in contestants) {
          if (c.received > maxReceived) maxReceived = c.received;
        }
        final total = asset.size > 0 ? asset.size : 1;
        final v = maxReceived / total;
        onProgress(v > 1.0 ? 1.0 : v);
      }
    }

    _RaceContestant? leader() {
      _RaceContestant? best;
      for (final c in contestants) {
        if (c.failed || c.aborted) continue;
        if (best == null || c.received > best.received) best = c;
      }
      return best;
    }

    void checkState() {
      if (winnerFound.isCompleted) return;
      if (contestants.every((c) => c.failed || c.aborted)) {
        winnerFound.complete(null);
        return;
      }
      final best = leader();
      if (best != null &&
          best.received > 0 &&
          (best.received >= probeBytes ||
              (best.total > 0 && best.received >= best.total))) {
        winnerFound.complete(best);
      }
    }

    try {
      onSource?.call('多源测速中（${contestants.length} 个源）…');
      zlog('[UpdateChecker] 开始 ${contestants.length} 路并发测速下载');
      for (final c in contestants) {
        c.start(
          asset,
          progressTimeout: progressTimeout,
          onBytes: () {
            reportProgress();
            checkState();
          },
          onSettled: () {
            if (c.failed) zlog('[UpdateChecker] ${c.label} 出局: ${c.error}');
            checkState();
          },
        );
      }
      deadlineTimer = Timer(probeDeadline, () {
        if (winnerFound.isCompleted) return;
        // Everyone alive but too slow for the threshold — commit to the
        // current leader. A zero-byte leader is still connecting; its own
        // first-byte timeout ends the round if it never delivers.
        final best = leader();
        if (best != null) winnerFound.complete(best);
      });

      winner = await winnerFound.future;
      final w = winner;
      if (w == null) {
        throw _RaceRoundException(
          failed: {for (var i = 0; i < contestants.length; i++) i},
          cause: contestants
                  .firstWhere((c) => c.error != null)
                  .error ??
              '所有下载源均不可用',
        );
      }
      final winnerIndex = contestants.indexOf(w);

      onSource?.call(w.label);
      zlog('[UpdateChecker] 测速胜出: ${w.label} (已接收 ${w.received} 字节)');

      // Cancel the losers immediately so the winner gets the full bandwidth;
      // the winner keeps streaming into its probe file.
      for (final c in contestants) {
        if (!identical(c, w)) unawaited(c.abort());
      }

      await w.done;
      if (w.error != null) {
        throw _RaceRoundException(
          failed: {
            winnerIndex,
            for (var i = 0; i < contestants.length; i++)
              if (contestants[i].failed) i,
          },
          cause: w.error!,
        );
      }

      await w.file.rename(file.path);
      zlog('[UpdateChecker] 通过 ${w.label} 下载完成 (${w.received} bytes)');
      return file.path;
    } finally {
      deadlineTimer?.cancel();
      await Future.wait([
        for (final c in contestants)
          if (!identical(c, winner)) c.abort(),
      ]);
      // A failed winner's partial probe file must not linger either.
      if (winner != null && winner.error != null) await winner.abort();
    }
  }

  DateTime _parseDate(dynamic release) {
    final raw = release['published_at'] as String? ??
        release['created_at'] as String? ??
        '';
    return DateTime.tryParse(raw) ?? DateTime.fromMillisecondsSinceEpoch(0);
  }
}

/// One contestant in a download race round: streams the file into its own
/// probe file until it wins (file kept and renamed by the caller) or loses
/// (connection cancelled, probe file deleted via [abort]).
class _RaceContestant {
  _RaceContestant({required this.url, required this.name, required this.file});

  final String url;

  /// Accelerator display name; null = official direct download.
  final String? name;

  final File file;

  final http.Client _client = http.Client();
  final Completer<void> _done = Completer<void>();
  StreamSubscription<List<int>>? _sub;
  IOSink? _sink;
  void Function()? _onSettled;

  int received = 0;
  int total = 0;
  Object? error;
  bool aborted = false;

  String get label => name ?? '官方直连';
  bool get failed => error != null;

  /// Completes when the download ends, successfully or not — inspect [error].
  Future<void> get done => _done.future;

  void start(
    AssetInfo asset, {
    required void Function() onBytes,
    required void Function() onSettled,
    Duration progressTimeout = UpdateChecker._progressTimeout,
  }) {
    _onSettled = onSettled;
    () async {
      try {
        final response = await _client
            .send(http.Request('GET', Uri.parse(url)))
            .timeout(UpdateChecker._firstByteTimeout);
        if (response.statusCode != 200) {
          throw UpdateCheckException('$label下载失败: HTTP ${response.statusCode}');
        }
        total = response.contentLength ?? asset.size;
        _sink = file.openWrite();
        _sub = response.stream.timeout(progressTimeout).listen(
          (chunk) {
            final sink = _sink;
            if (sink == null) return;
            sink.add(chunk);
            received += chunk.length;
            onBytes();
          },
          cancelOnError: true,
          onError: (Object e) => _finish(error: e),
          onDone: () => _finish(),
        );
      } catch (e) {
        _finish(error: e);
      }
    }();
  }

  Future<void> _finish({Object? error}) async {
    if (_done.isCompleted) return;
    if (!aborted && error != null) this.error = error;
    await _sub?.cancel();
    _client.close();
    final sink = _sink;
    _sink = null;
    if (sink != null) {
      try {
        await sink.flush();
        await sink.close();
      } catch (_) {}
    }
    _done.complete();
    _onSettled?.call();
  }

  /// Cancels the download and deletes the probe file.
  Future<void> abort() async {
    aborted = true;
    await _finish();
    try {
      await file.delete();
    } catch (_) {}
  }
}

/// One race round failed; [failed] holds the indices (into the round's
/// candidate list) of the contestants that died and must not be retried.
class _RaceRoundException implements Exception {
  _RaceRoundException({required this.failed, required this.cause});

  final Set<int> failed;
  final Object cause;
}

/// Thrown when the update check or download fails.
class UpdateCheckException implements Exception {
  final String message;
  UpdateCheckException(this.message);

  @override
  String toString() => message;
}
