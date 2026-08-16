/// Local persistence: pairings (QR credentials) and the text-only cache of
/// sessions and conversation rows.
library;

import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../relay/relay_types.dart';

class StoredPairing {
  final int id;
  final String deviceSid;
  final String passHash;
  final int timestamp;
  final String? deviceMid;
  final String? deviceName;
  final String? appVersion;
  final String customName;
  final int createdAt;

  const StoredPairing({
    required this.id,
    required this.deviceSid,
    required this.passHash,
    required this.timestamp,
    this.deviceMid,
    this.deviceName,
    this.appVersion,
    required this.customName,
    required this.createdAt,
  });

  PairingCredential toCredential() => PairingCredential(
        deviceSid: deviceSid,
        passHash: passHash,
        timestamp: timestamp,
        deviceMid: deviceMid,
        deviceName: deviceName,
        appVersion: appVersion,
      );

  String get displayName =>
      customName.isNotEmpty ? customName : (deviceName ?? deviceSid);

  Map<String, Object?> toRow() => {
        'device_sid': deviceSid,
        'pass_hash': passHash,
        'timestamp': timestamp,
        'device_mid': deviceMid,
        'device_name': deviceName,
        'app_version': appVersion,
        'custom_name': customName,
        'created_at': createdAt,
      };

  static StoredPairing fromRow(Map<String, Object?> row) => StoredPairing(
        id: row['id'] as int,
        deviceSid: row['device_sid'] as String,
        passHash: row['pass_hash'] as String,
        timestamp: row['timestamp'] as int,
        deviceMid: row['device_mid'] as String?,
        deviceName: row['device_name'] as String?,
        appVersion: row['app_version'] as String?,
        customName: row['custom_name'] as String? ?? '',
        createdAt: row['created_at'] as int? ?? 0,
      );
}

class CachedSession {
  final String sessionId;
  final String workspaceKey;
  final String title;
  final int lastActivityAt;
  final String previewText;
  const CachedSession({
    required this.sessionId,
    required this.workspaceKey,
    required this.title,
    required this.lastActivityAt,
    required this.previewText,
  });
}

class AppDatabase {
  AppDatabase._();
  static final AppDatabase instance = AppDatabase._();

  Database? _db;

  Future<Database> get _database async {
    if (_db != null) return _db!;
    final dir = await getDatabasesPath();
    _db = await openDatabase(
      p.join(dir, 'zcode_remote.db'),
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE pairings (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            device_sid TEXT NOT NULL UNIQUE,
            pass_hash TEXT NOT NULL,
            timestamp INTEGER NOT NULL,
            device_mid TEXT,
            device_name TEXT,
            app_version TEXT,
            custom_name TEXT NOT NULL DEFAULT '',
            created_at INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE cached_sessions (
            session_id TEXT PRIMARY KEY,
            workspace_key TEXT NOT NULL,
            title TEXT NOT NULL,
            last_activity_at INTEGER NOT NULL,
            preview_text TEXT NOT NULL DEFAULT ''
          )
        ''');
        await db.execute('''
          CREATE TABLE cached_rows (
            session_id TEXT NOT NULL,
            row_id INTEGER NOT NULL,
            row_json TEXT NOT NULL,
            PRIMARY KEY (session_id, row_id)
          )
        ''');
      },
    );
    return _db!;
  }

  // ---------- Pairings ----------

  Future<List<StoredPairing>> listPairings() async {
    final db = await _database;
    final rows = await db.query('pairings', orderBy: 'created_at DESC');
    return rows.map(StoredPairing.fromRow).toList();
  }

  Future<StoredPairing?> findPairing(String deviceSid) async {
    final db = await _database;
    final rows = await db.query('pairings', where: 'device_sid = ?', whereArgs: [deviceSid]);
    if (rows.isEmpty) return null;
    return StoredPairing.fromRow(rows.first);
  }

  Future<void> upsertPairing(StoredPairing pairing) async {
    final db = await _database;
    final existing = await db.query(
      'pairings',
      where: 'device_sid = ?',
      whereArgs: [pairing.deviceSid],
    );
    if (existing.isEmpty) {
      await db.insert('pairings', pairing.toRow());
    } else {
      await db.update(
        'pairings',
        pairing.toRow(),
        where: 'device_sid = ?',
        whereArgs: [pairing.deviceSid],
      );
    }
  }

  Future<void> renamePairing(int id, String customName) async {
    final db = await _database;
    await db.update('pairings', {'custom_name': customName}, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deletePairing(int id) async {
    final db = await _database;
    await db.delete('pairings', where: 'id = ?', whereArgs: [id]);
  }

  // ---------- Session text cache ----------

  Future<void> cacheSession(
    String sessionId,
    String workspaceKey,
    String title,
    int lastActivityAt,
    String previewText,
  ) async {
    final db = await _database;
    await db.insert(
      'cached_sessions',
      {
        'session_id': sessionId,
        'workspace_key': workspaceKey,
        'title': title,
        'last_activity_at': lastActivityAt,
        'preview_text': previewText,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<CachedSession>> cachedSessions(String workspaceKey) async {
    final db = await _database;
    final rows = await db.query(
      'cached_sessions',
      where: 'workspace_key = ?',
      whereArgs: [workspaceKey],
      orderBy: 'last_activity_at DESC',
      limit: 50,
    );
    return rows
        .map((r) => CachedSession(
              sessionId: r['session_id'] as String,
              workspaceKey: r['workspace_key'] as String,
              title: r['title'] as String? ?? '',
              lastActivityAt: r['last_activity_at'] as int? ?? 0,
              previewText: r['preview_text'] as String? ?? '',
            ))
        .toList();
  }

  Future<void> cacheRow(String sessionId, int rowId, String rowJson) async {
    final db = await _database;
    await db.insert(
      'cached_rows',
      {'session_id': sessionId, 'row_id': rowId, 'row_json': rowJson},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<String>> cachedRowJson(String sessionId) async {
    final db = await _database;
    final rows = await db.query(
      'cached_rows',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'row_id ASC',
    );
    return rows.map((r) => r['row_json'] as String).toList();
  }

  Future<void> clearSessionRows(String sessionId) async {
    final db = await _database;
    await db.delete('cached_rows', where: 'session_id = ?', whereArgs: [sessionId]);
  }

  /// Trim cached rows for [sessionId] to at most [keep] newest rows.
  Future<void> trimSessionRows(String sessionId, {int keep = 500}) async {
    final db = await _database;
    final rows = await db.query(
      'cached_rows',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'row_id DESC',
      limit: keep,
    );
    final keepIds = rows.map((r) => r['row_id'] as int).toSet();
    final all = await db.query(
      'cached_rows',
      columns: ['row_id'],
      where: 'session_id = ?',
      whereArgs: [sessionId],
    );
    for (final r in all) {
      final rowId = r['row_id'] as int;
      if (!keepIds.contains(rowId)) {
        await db.delete(
          'cached_rows',
          where: 'session_id = ? AND row_id = ?',
          whereArgs: [sessionId, rowId],
        );
      }
    }
  }
}

/// Serializes a row's cache-able text payload.
String rowCacheJson({
  required int rowId,
  required String kind,
  String? text,
  String? inputText,
  String? toolName,
  String? toolStatus,
}) =>
    jsonEncode({
      'rowId': rowId,
      'kind': kind,
      if (text != null) 'text': text,
      if (inputText != null) 'inputText': inputText,
      if (toolName != null) 'toolName': toolName,
      if (toolStatus != null) 'toolStatus': toolStatus,
    });
