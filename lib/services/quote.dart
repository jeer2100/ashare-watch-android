import 'dart:convert';

import 'package:http/http.dart' as http;

const String _ut = '7eea3edcaed734bea9cbfc24409ed989';

const List<String> kNodes = <String>[
  '09:40', '09:50', '10:00', '10:10', '10:20', '10:30',
  '10:40', '10:50', '11:00', '11:10', '11:20', '11:30',
  '13:00', '13:10', '13:20', '13:30', '13:40', '13:50',
  '14:00', '14:10', '14:20', '14:30', '14:40', '14:50', '15:00',
];

class PoolData {
  final int tc;
  final String qdate;
  final List<dynamic> pool;

  const PoolData({required this.tc, required this.qdate, required this.pool});
}

int _toInt(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}

String _pad(int n) => n < 10 ? '0$n' : '$n';

Future<PoolData> _fetchPool(
  String endpoint,
  String compactDate,
  String node,
) async {
  final uri = Uri.parse('https://push2ex.eastmoney.com/$endpoint').replace(
    queryParameters: <String, String>{
      'ut': _ut,
      'dpt': 'wz.ztzt',
      'Pageindex': '0',
      'pagesize': '500',
      'sort': 'fbt:asc',
      'date': compactDate,
      '_t': node.replaceAll(':', ''),
    },
  );

  final http.Response response = await http
      .get(uri, headers: <String, String>{'User-Agent': 'Mozilla/5.0'})
      .timeout(const Duration(seconds: 15));

  if (response.statusCode != 200) {
    throw Exception('HTTP ${response.statusCode}');
  }

  final dynamic decoded = jsonDecode(response.body);
  if (decoded is! Map<String, dynamic>) {
    throw Exception('响应格式异常');
  }
  final Map<String, dynamic> data =
      decoded['data'] is Map<String, dynamic> ? decoded['data'] : {};

  return PoolData(
    tc: _toInt(data['tc']),
    qdate: data['qdate']?.toString() ?? '',
    pool: data['pool'] is List ? data['pool'] as List : const [],
  );
}

// fbt 93021 => 09:30:21，转成当天秒数，用于按节点回推
int _fbtSec(dynamic v) {
  final String s = _toInt(v).toString().padLeft(6, '0');
  final int h = int.tryParse(s.substring(0, 2)) ?? 0;
  final int m = int.tryParse(s.substring(2, 4)) ?? 0;
  final int sec = int.tryParse(s.substring(4, 6)) ?? 0;
  return h * 3600 + m * 60 + sec;
}

String _fmtFbt(dynamic v) {
  final String s = _toInt(v).toString().padLeft(6, '0');
  return '${s.substring(0, 2)}:${s.substring(2, 4)}';
}

int _nodeSec(String node) {
  final List<String> p = node.split(':');
  return (int.tryParse(p[0]) ?? 0) * 3600 + (int.tryParse(p[1]) ?? 0) * 60;
}

Map<String, dynamic> _infoOf(Map<String, dynamic> x) => <String, dynamic>{
      'name': x['n']?.toString() ?? '',
      'code': x['c']?.toString() ?? '',
      'fbt': _fmtFbt(x['fbt']),
      'lbc': _toInt(x['lbc']),
      'sector': x['hybk']?.toString() ?? '其他',
    };

// 明细分析：板块分布 / 连板梯队 / 首封前5 / 连板前5（与网页版口径一致）
Map<String, dynamic> analyzePool(List<dynamic> pool) {
  final Map<String, int> counts = <String, int>{};
  for (final dynamic x in pool) {
    if (x is Map<String, dynamic>) {
      final String? s = x['hybk']?.toString();
      if (s != null && s.isNotEmpty) counts[s] = (counts[s] ?? 0) + 1;
    }
  }
  final List<MapEntry<String, int>> entries = counts.entries.toList()
    ..sort((MapEntry<String, int> a, MapEntry<String, int> b) =>
        b.value.compareTo(a.value));
  final List<dynamic> sectors = entries
      .map((MapEntry<String, int> e) =>
          <String, dynamic>{'name': e.key, 'n': e.value})
      .toList();

  final Map<int, int> lb = <int, int>{};
  for (final dynamic x in pool) {
    if (x is Map<String, dynamic>) {
      final int n = _toInt(x['lbc']);
      if (n > 0) lb[n] = (lb[n] ?? 0) + 1;
    }
  }
  final List<int> ladderKeys = lb.keys.toList()
    ..sort((int a, int b) => b.compareTo(a));
  final List<dynamic> ladder = ladderKeys
      .map((int k) => <String, dynamic>{'n': k, 'c': lb[k]})
      .toList();

  final List<Map<String, dynamic>> byFbt = pool
      .whereType<Map<String, dynamic>>()
      .toList()
    ..sort((Map<String, dynamic> a, Map<String, dynamic> b) =>
        _fbtSec(a['fbt']).compareTo(_fbtSec(b['fbt'])));
  final List<dynamic> first = byFbt.take(5).map(_infoOf).toList();
  final List<Map<String, dynamic>> lbStocks = byFbt
      .where((Map<String, dynamic> x) => _toInt(x['lbc']) >= 2)
      .toList();

  return <String, dynamic>{
    'sectors': sectors,
    'ladder': ladder,
    'first': first,
    'lbCount': lbStocks.length,
    'firstBoardCount': pool.length - lbStocks.length,
    'lbFirst': lbStocks.take(5).map(_infoOf).toList(),
  };
}

Future<PoolData?> _fetchZbSafe(String compactDate) async {
  try {
    return await _fetchPool('getTopicZBPool', compactDate, 'backfill');
  } catch (_) {
    return null;
  }
}

/// 抓一次全量涨停/炸板池，按首次封板时间 fbt 回推出当日所有"已完成"节点。
/// 未到时间的节点不返回，界面显示"待更新"；每个节点都带完整明细 detail。
Future<List<Map<String, dynamic>>> fetchBackfillSnapshots() async {
  final DateTime now = DateTime.now().toUtc().add(const Duration(hours: 8));
  if (now.weekday == DateTime.saturday || now.weekday == DateTime.sunday) {
    return const <Map<String, dynamic>>[];
  }

  final String compactDate =
      '${now.year}${_pad(now.month)}${_pad(now.day)}';
  final String date = '${now.year}-${_pad(now.month)}-${_pad(now.day)}';

  final PoolData zt =
      await _fetchPool('getTopicZTPool', compactDate, 'backfill');
  if (zt.qdate != compactDate) return const <Map<String, dynamic>>[];
  final PoolData? zb = await _fetchZbSafe(compactDate);
  final List<dynamic> zbPool = zb?.pool ?? const <dynamic>[];

  final int nowSec = now.hour * 3600 + now.minute * 60 + now.second;
  final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
  Map<String, int>? prevSectors;
  int prevZt = 0;
  int prevZb = 0;

  for (final String node in kNodes) {
    final int ns = _nodeSec(node);
    if (ns > nowSec) break;

    final List<dynamic> ztList = zt.pool
        .where((dynamic x) =>
            x is Map<String, dynamic> && _fbtSec(x['fbt']) <= ns)
        .toList();
    final List<dynamic> zbList = zbPool
        .where((dynamic x) =>
            x is Map<String, dynamic> && _fbtSec(x['fbt']) <= ns)
        .toList();

    final Map<String, dynamic> detail = analyzePool(ztList);
    final Map<String, int> curSectors = <String, int>{};
    for (final dynamic s in (detail['sectors'] as List<dynamic>)) {
      final Map<String, dynamic> m = s as Map<String, dynamic>;
      curSectors[m['name'] as String] = _toInt(m['n']);
    }
    final List<Map<String, dynamic>> sectorDelta =
        <Map<String, dynamic>>[];
    curSectors.forEach((String k, int v) {
      final int d = v - (prevSectors?[k] ?? 0);
      if (d > 0) sectorDelta.add(<String, dynamic>{'name': k, 'd': d});
    });
    sectorDelta.sort((Map<String, dynamic> a, Map<String, dynamic> b) =>
        _toInt(b['d']).compareTo(_toInt(a['d'])));
    detail['deltaSector'] = sectorDelta.isEmpty ? null : sectorDelta.first;

    final List<dynamic> sectors = detail['sectors'] as List<dynamic>;
    final List<dynamic> ladder = detail['ladder'] as List<dynamic>;
    out.add(<String, dynamic>{
      'date': date,
      'node': node,
      'zt': ztList.length,
      'zb': zbList.length,
      'topSector': sectors.isNotEmpty ? sectors.first['name'] : '-',
      'maxLb': ladder.isNotEmpty ? _toInt(ladder.first['n']) : 0,
      'ts': DateTime.now().millisecondsSinceEpoch,
      'detail': detail,
      'deltaZt': ztList.length - prevZt,
      'deltaZb': zbList.length - prevZb,
    });
    prevZt = ztList.length;
    prevZb = zbList.length;
    prevSectors = curSectors;
  }
  return out;
}
