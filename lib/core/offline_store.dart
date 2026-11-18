import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:pointycastle/export.dart';
import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'backend_config.dart';

bool transientReadFailure(Object error) =>
    error is http.ClientException ||
    error is TimeoutException ||
    (error is PostgrestException &&
        {'PGRST000', 'PGRST001', 'PGRST002', 'PGRST003', '503', '504'}.contains(error.code));

class OfflineStore {
  final _keys = <String, Future<Uint8List>>{};
  final _random = Random.secure();
  static const _secure = FlutterSecureStorage();
  bool get available =>
      !kIsWeb && {TargetPlatform.android, TargetPlatform.iOS, TargetPlatform.macOS}.contains(defaultTargetPlatform);
  late final Future<Database> _db = _open();

  Future<Database> _open() async {
    final directory = await getDatabasesPath();
    final host = Uri.parse(backendUrl).authority.replaceAll(RegExp(r'[^a-zA-Z0-9.-]'), '_');
    return openDatabase('$directory/taspa-$host.sqlite', version: 1, onCreate: (db, _) async {
      await db.execute('create table entries (owner text not null, bucket text not null, id text not null, body text not null, touched integer not null, primary key(owner,bucket,id))');
    });
  }

  Uint8List _bytes(int length) => Uint8List.fromList(List.generate(length, (_) => _random.nextInt(256)));

  Future<Uint8List> _key(String owner) => _keys.putIfAbsent(owner, () async {
    final label = 'taspa.offline.${Uri.parse(backendUrl).authority}.$owner';
    final existing = await _secure.read(key: label);
    if (existing != null) return base64Decode(existing);
    final key = _bytes(32);
    await _secure.write(key: label, value: base64Encode(key));
    return key;
  });

  Future<String> _encode(String owner, String bucket, String id, Object value) async {
    final json = jsonEncode(value);
    if (owner.isEmpty) return json;
    final nonce = _bytes(12);
    final cipher = GCMBlockCipher(AESEngine())..init(true, AEADParameters(
      KeyParameter(await _key(owner)), 128, nonce, utf8.encode('$owner/$bucket/$id')));
    return base64Encode([...nonce, ...cipher.process(utf8.encode(json))]);
  }

  Future<dynamic> _decode(String owner, String bucket, String id, String value) async {
    if (owner.isEmpty) return jsonDecode(value);
    final bytes = base64Decode(value);
    final cipher = GCMBlockCipher(AESEngine())..init(false, AEADParameters(
      KeyParameter(await _key(owner)), 128, bytes.sublist(0, 12), utf8.encode('$owner/$bucket/$id')));
    return jsonDecode(utf8.decode(cipher.process(bytes.sublist(12))));
  }

  Future<dynamic> read(String owner, String bucket, String id) async {
    if (!available) return null;
    final rows = await (await _db).query('entries', columns: ['body'], where: 'owner=? and bucket=? and id=?', whereArgs: [owner,bucket,id]);
    if (rows.isEmpty) return null;
    return _decode(owner, bucket, id, rows.single['body'] as String);
  }

  Future<List<Map<String,dynamic>>> queued(String owner) async {
    if (!available) return [];
    final rows = await (await _db).query('entries', where: 'owner=? and bucket=?', whereArgs: [owner,'outbox'], orderBy: 'touched,id');
    return Future.wait(rows.map((row) async =>
      await _decode(owner,'outbox',row['id'] as String,row['body'] as String) as Map<String,dynamic>));
  }

  Future<void> write(String owner, String bucket, String id, Object value) async {
    if (!available) return;
    final db = await _db;
    final body = await _encode(owner,bucket,id,value);
    await db.transaction((tx) async {
      await tx.insert('entries', {'owner':owner,'bucket':bucket,'id':id,'body':body,
        'touched':DateTime.now().millisecondsSinceEpoch}, conflictAlgorithm: ConflictAlgorithm.replace);
      if (bucket == 'cache') {
        await tx.rawDelete('delete from entries where owner=? and bucket=? and id in (select id from entries where owner=? and bucket=? order by touched desc limit -1 offset 240)', [owner,bucket,owner,bucket]);
      }
    });
  }

  Future<void> remove(String owner, String bucket, String id) async {
    if (!available) return;
    await (await _db).delete('entries',where:'owner=? and bucket=? and id=?',whereArgs:[owner,bucket,id]);
  }

  Future<void> forgetCache(String owner) async {
    _keys.remove(owner);
    if (!available || owner.isEmpty) return;
    await (await _db).delete('entries',where:'owner=? and bucket=?',whereArgs:[owner,'cache']);
  }

  Future<bool> hasEdits(String owner) async {
    if (!available) return false;
    final rows = await (await _db).query('entries', columns: ['id'],
      where: "owner=? and bucket in ('outbox','drafts')", whereArgs: [owner], limit: 1);
    return rows.isNotEmpty;
  }

  Future<void> forgetEdits(String owner) async {
    if (!available) return;
    await (await _db).delete('entries', where: "owner=? and bucket in ('outbox','drafts')", whereArgs: [owner]);
  }

  Future<T> cached<T extends Object>(String owner, String id, Future<T> Function() fetch,
      {bool Function(Object) canUseCache = transientReadFailure, T Function(dynamic)? fallback}) async {
    try {
      final fresh = await fetch().timeout(const Duration(seconds: 12));
      await write(owner, 'cache', id, fresh).catchError((Object _) {});
      return fresh;
    } on Exception catch (error) {
      if (canUseCache(error) && fallback != null) {
        final saved = await read(owner, 'cache', id).catchError((Object _) => null);
        if (saved != null) return fallback(saved);
      }
      rethrow;
    }
  }
}
