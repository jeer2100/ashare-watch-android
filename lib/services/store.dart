import 'dart:convert';
import 'dart:io';

const String _storeFileName = 'ashare_watch_snapshots.json';

File get _storeFile => File('${Directory.systemTemp.path}/$_storeFileName');

class Snapshot {
  final String date;
  final String node;
  final int zt;
  final int zb;
  final int deltaZt;
  final int deltaZb;
  final String topSector;
  final int maxLb;
  final int ts;

  const Snapshot({
    required this.date,
    required this.node,
    required this.zt,
    required this.zb,
    required this.deltaZt,
    required this.deltaZb,
    required this.topSector,
    required this.maxLb,
    required this.ts,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'date': date,
        'node': node,
        'zt': zt,
        'zb': zb,
        'deltaZt': deltaZt,
        'deltaZb': deltaZb,
        'topSector': topSector,
        'maxLb': maxLb,
        'ts': ts,
      };

  factory Snapshot.fromJson(Map<String, dynamic> json) => Snapshot(
        date: json['date']?.toString() ?? '',
        node: json['node']?.toString() ?? '',
        zt: _int(json['zt']),
        zb: _int(json['zb']),
        deltaZt: _int(json['deltaZt']),
        deltaZb: _int(json['deltaZb']),
        topSector: json['topSector']?.toString() ?? '-',
        maxLb: _int(json['maxLb']),
        ts: _int(json['ts']),
      );

  Snapshot copyWithDelta({required int deltaZt, required int deltaZb}) =>
      Snapshot(
        date: date,
        node: node,
        zt: zt,
        zb: zb,
        deltaZt: deltaZt,
        deltaZb: deltaZb,
        topSector: topSector,
        maxLb: maxLb,
        ts: ts,
      );
}

int _int(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}

Future<List<Snapshot>> loadSnapshots() async {
  try {
    final File file = _storeFile;
    if (!file.existsSync()) return <Snapshot>[];
    final dynamic decoded = jsonDecode(await file.readAsString());
    if (decoded is! List) return <Snapshot>[];
    return decoded
        .whereType<Map<String, dynamic>>()
        .map(Snapshot.fromJson)
        .where((Snapshot s) => s.date.isNotEmpty && s.node.isNotEmpty)
        .toList();
  } catch (_) {
    return <Snapshot>[];
  }
}

Future<void> saveSnapshot(Snapshot snapshot) async {
  final List<Snapshot> all = await loadSnapshots();

  final List<Snapshot> sameDay = all
      .where((Snapshot s) => s.date == snapshot.date && s.node != snapshot.node)
      .toList()
    ..sort((Snapshot a, Snapshot b) => a.node.compareTo(b.node));

  final Snapshot? previous = sameDay.isEmpty ? null : sameDay.last;
  final Snapshot updated = snapshot.copyWithDelta(
    deltaZt: previous == null ? snapshot.zt : snapshot.zt - previous.zt,
    deltaZb: previous == null ? snapshot.zb : snapshot.zb - previous.zb,
  );

  final int index = all.indexWhere(
    (Snapshot s) => s.date == snapshot.date && s.node == snapshot.node,
  );
  if (index >= 0) {
    all[index] = updated;
  } else {
    all.add(updated);
  }

  all.sort((Snapshot a, Snapshot b) {
    final int byDate = a.date.compareTo(b.date);
    return byDate != 0 ? byDate : a.node.compareTo(b.node);
  });

  final List<Snapshot> trimmed =
      all.length > 1200 ? all.sublist(all.length - 1200) : all;
  await _storeFile.writeAsString(
    jsonEncode(trimmed.map((Snapshot s) => s.toJson()).toList()),
    flush: true,
  );
}

Future<void> clearSnapshots() async {
  try {
    if (_storeFile.existsSync()) await _storeFile.delete();
  } catch (_) {}
}
