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

String _topSector(List<dynamic> pool) {
  final Map<String, int> counts = <String, int>{};
  for (final dynamic item in pool) {
    if (item is Map<String, dynamic>) {
      final String? sector = item['hybk']?.toString();
      if (sector != null && sector.isNotEmpty) {
        counts[sector] = (counts[sector] ?? 0) + 1;
      }
    }
  }
  if (counts.isEmpty) return '-';
  String best = '-';
  int bestCount = 0;
  counts.forEach((String key, int value) {
    if (value > bestCount) {
      bestCount = value;
      best = key;
    }
  });
  return best;
}

int _maxLb(List<dynamic> pool) {
  int max = 0;
  for (final dynamic item in pool) {
    if (item is Map<String, dynamic>) {
      final int lb = _toInt(item['lbc']);
      if (lb > max) max = lb;
    }
  }
  return max;
}

Future<PoolData?> _fetchZbSafe(String compactDate, String node) async {
  try {
    return await _fetchPool('getTopicZBPool', compactDate, node);
  } catch (_) {
    return null;
  }
}

Future<Map<String, dynamic>?> _buildSnapshot(
  DateTime now,
  String node,
) async {
  if (now.weekday == 6 || now.weekday == 7) return null;

  final String compactDate =
      '${now.year}${_pad(now.month)}${_pad(now.day)}';
  final String date = '${now.year}-${_pad(now.month)}-${_pad(now.day)}';

  final PoolData zt = await _fetchPool('getTopicZTPool', compactDate, node);
  if (zt.qdate != compactDate) return null;

  final PoolData? zb = await _fetchZbSafe(compactDate, node);

  return <String, dynamic>{
    'date': date,
    'node': node,
    'zt': zt.tc,
    'zb': zb?.tc ?? 0,
    'topSector': _topSector(zt.pool),
    'maxLb': _maxLb(zt.pool),
    'ts': DateTime.now().millisecondsSinceEpoch,
  };
}

/// 后台服务用：只在 25 个整点节点分钟抓取，保证时间线是整齐的 25 个点。
Future<Map<String, dynamic>?> fetchRawSnapshot() async {
  final DateTime now = DateTime.now().toUtc().add(const Duration(hours: 8));
  final String node = '${_pad(now.hour)}:${_pad(now.minute)}';
  if (!kNodes.contains(node)) return null;
  return _buildSnapshot(now, node);
}

/// 手动刷新 / 打开 App 用：任意时刻都抓当前实时快照，node 用实际时间。
/// 只要接口返回的是当天数据（交易日盘前/盘中/盘后均可）就有效。
Future<Map<String, dynamic>?> fetchLiveSnapshot() async {
  final DateTime now = DateTime.now().toUtc().add(const Duration(hours: 8));
  if (now.weekday == 6 || now.weekday == 7) return null;
  final String node = '${_pad(now.hour)}:${_pad(now.minute)}';
  return _buildSnapshot(now, node);
}
