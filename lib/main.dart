import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'services/quote.dart';
import 'services/store.dart';

void main() {
  FlutterForegroundTask.initCommunicationPort();
  runApp(const WatchApp());
}

@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(WatchTaskHandler());
}

Future<void> runTick() async {
  try {
    final List<Map<String, dynamic>> rows = await fetchBackfillSnapshots();
    if (rows.isEmpty) return;
    await saveBackfill(rows.map(Snapshot.fromJson).toList());
  } catch (_) {}
}

class WatchTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    await runTick();
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    runTick();
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

class WatchApp extends StatelessWidget {
  const WatchApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'A股盯盘助手',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.red),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<Snapshot> _today = <Snapshot>[];
  bool _serviceOn = false;
  bool _busy = false;
  String _message = '正在初始化…';

  @override
  void initState() {
    super.initState();
    FlutterForegroundTask.addTaskDataCallback(_onTaskData);
    WidgetsBinding.instance.addPostFrameCallback((_) => _initialize());
  }

  @override
  void dispose() {
    FlutterForegroundTask.removeTaskDataCallback(_onTaskData);
    super.dispose();
  }

  void _onTaskData(Object data) {
    _reload();
  }

  Future<void> _initialize() async {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'ashare_watch',
        channelName: '盯盘服务',
        channelDescription: '定时回补涨停与炸板节点数据',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(120000),
        autoRunOnBoot: true,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );

    await _reload();

    final bool running = await FlutterForegroundTask.isRunningService;
    if (running) {
      setState(() {
        _serviceOn = true;
        _message = '后台盯盘服务运行中';
      });
      await _refresh(markMessage: false);
      return;
    }

    final NotificationPermission permission =
        await FlutterForegroundTask.checkNotificationPermission();
    if (permission != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
    if (Platform.isAndroid &&
        !await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }

    await _startService();
    await _refresh(markMessage: false);
  }

  Future<void> _startService() async {
    try {
      final result = await FlutterForegroundTask.startService(
        serviceTypes: const <ForegroundServiceTypes>[
          ForegroundServiceTypes.dataSync,
        ],
        serviceId: 256,
        notificationTitle: 'A股盯盘助手运行中',
        notificationText: '自动回补当日涨停 / 炸板节点',
        callback: startCallback,
      );
      setState(() {
        _serviceOn = true;
        _message = '后台服务已启动 (${result.runtimeType})';
      });
    } catch (e) {
      setState(() {
        _serviceOn = false;
        _message = '后台服务启动失败: $e';
      });
    }
  }

  Future<void> _stopService() async {
    try {
      await FlutterForegroundTask.stopService();
      setState(() {
        _serviceOn = false;
        _message = '后台服务已停止';
      });
    } catch (e) {
      setState(() => _message = '停止服务失败: $e');
    }
  }

  Future<void> _reload() async {
    final List<Snapshot> all = await loadSnapshots();
    final DateTime now = DateTime.now().toUtc().add(const Duration(hours: 8));
    final String today =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    if (!mounted) return;
    setState(() {
      _today = all
          .where((Snapshot s) => s.date == today && kNodes.contains(s.node))
          .toList()
            ..sort((Snapshot a, Snapshot b) => a.node.compareTo(b.node));
    });
  }

  Future<void> _refresh({required bool markMessage}) async {
    try {
      final List<Map<String, dynamic>> rows = await fetchBackfillSnapshots();
      if (rows.isEmpty) {
        if (markMessage) _message = '今天非交易日或接口暂未返回数据';
      } else {
        await saveBackfill(rows.map(Snapshot.fromJson).toList());
        if (markMessage) {
          _message = '已回填当日 ${rows.length} 个节点（截至 ${rows.last['node']}）';
        }
      }
    } catch (e) {
      if (markMessage) _message = '抓取失败: $e';
    }
    await _reload();
  }

  Future<void> _manualFetch() async {
    setState(() => _busy = true);
    await _refresh(markMessage: true);
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _clear() async {
    await clearSnapshots();
    await _reload();
    if (mounted) setState(() => _message = '本地记录已清空，下拉可重新回填');
  }

  @override
  Widget build(BuildContext context) {
    final Snapshot? latest = _today.isEmpty ? null : _today.last;
    final String todayLabel = latest?.date ?? '今日';

    return Scaffold(
      appBar: AppBar(
        title: const Text('A股盯盘助手'),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '清空本地记录',
            onPressed: _clear,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '立即回填',
            onPressed: _busy ? null : _manualFetch,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _manualFetch,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            _buildStatusCard(),
            const SizedBox(height: 16),
            _buildChart(),
            const SizedBox(height: 16),
            _buildSummaryCard(latest, todayLabel),
            const SizedBox(height: 16),
            const Text(
              '当日节点',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 8),
            _buildTimeline(),
            const SizedBox(height: 20),
            const Text(
              '华为手机请在「设置 → 应用 → 应用启动管理」中关闭本 App 的自动管理，'
              '并手动允许后台活动，避免锁屏后服务被系统停止。',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  _serviceOn ? Icons.check_circle : Icons.cancel,
                  color: _serviceOn ? Colors.green : Colors.grey,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Text(
                  _serviceOn ? '后台自动回填已开启' : '后台自动回填未开启',
                  style: const TextStyle(fontSize: 14),
                ),
                const Spacer(),
                TextButton(
                  onPressed: _serviceOn ? _stopService : _startService,
                  child: Text(_serviceOn ? '停止' : '开启'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              _message,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  // 涨停家数走势柱状图：早盘 / 午盘两段，已过节点画柱，未到节点显示 -
  Widget _buildChart() {
    final Map<String, Snapshot> byNode = <String, Snapshot>{};
    for (final Snapshot s in _today) {
      byNode[s.node] = s;
    }
    final int maxZt = _today.fold<int>(
        0, (int m, Snapshot s) => s.zt > m ? s.zt : m);
    final int done = byNode.length;

    Widget segment(String title, List<String> nodes) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(title, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 4),
          SizedBox(
            height: 104,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: nodes.map((String node) {
                final Snapshot? s = byNode[node];
                final double ratio =
                    s == null ? 0 : s.zt / (maxZt == 0 ? 1 : maxZt);
                final double barH = s == null
                    ? 0.0
                    : (ratio * 60).clamp(3.0, 60.0).toDouble();
                return Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: <Widget>[
                      Text(
                        s == null ? '-' : '${s.zt}',
                        style: TextStyle(
                          fontSize: 10,
                          color: s == null ? Colors.grey : Colors.red,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Container(
                        height: barH,
                        width: double.infinity,
                        margin: const EdgeInsets.symmetric(horizontal: 1),
                        decoration: BoxDecoration(
                          color: s == null
                              ? Colors.grey.withOpacity(0.15)
                              : Colors.red.withOpacity(0.75),
                          borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(2)),
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        node.substring(0, 2) == '0'
                            ? node.substring(1)
                            : node,
                        style: const TextStyle(fontSize: 8, color: Colors.grey),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                const Text('涨停家数走势',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                Text('已更新 $done/25',
                    style: const TextStyle(fontSize: 12, color: Colors.grey)),
              ],
            ),
            const SizedBox(height: 12),
            segment('早盘 9:40 – 11:30', kNodes.sublist(0, 12)),
            const SizedBox(height: 14),
            segment('午盘 13:00 – 15:00', kNodes.sublist(12)),
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryCard(Snapshot? latest, String todayLabel) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '$todayLabel · ${latest == null ? '暂无数据' : '${latest.node} 快照'}',
              style: const TextStyle(fontSize: 13, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Expanded(
                  child: _buildNumber(
                    '涨停家数',
                    latest?.zt ?? 0,
                    Colors.red,
                    latest?.deltaZt,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildNumber(
                    '炸板家数',
                    latest?.zb ?? 0,
                    Colors.orange,
                    latest?.deltaZb,
                  ),
                ),
              ],
            ),
            if (latest != null) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                '最强板块：${latest.topSector}   最高连板：${latest.maxLb} 板',
                style: const TextStyle(fontSize: 13),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildNumber(String label, int value, Color color, int? delta) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey.withOpacity(0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 4),
          Text(
            '$value',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.w500, color: color),
          ),
          if (delta != null)
            Text(
              '较上一节点 ${delta >= 0 ? '+' : ''}$delta',
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
        ],
      ),
    );
  }

  Widget _buildTimeline() {
    final Map<String, Snapshot> byNode = <String, Snapshot>{};
    for (final Snapshot s in _today) {
      byNode[s.node] = s;
    }
    return Card(
      child: Column(
        children: kNodes.map((String node) {
          final Snapshot? row = byNode[node];
          return ListTile(
            dense: true,
            leading: SizedBox(
              width: 52,
              child: Text(node, style: const TextStyle(fontSize: 13)),
            ),
            title: row == null
                ? const Text('待更新',
                    style: TextStyle(fontSize: 13, color: Colors.grey))
                : Text(
                    '涨停 ${row.zt}  ·  炸板 ${row.zb}  ·  ${row.topSector}',
                    style: const TextStyle(fontSize: 13),
                  ),
            trailing: row == null
                ? const Icon(Icons.chevron_right, size: 16, color: Colors.grey)
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        '${row.deltaZt >= 0 ? '+' : ''}${row.deltaZt} / ${row.deltaZb >= 0 ? '+' : ''}${row.deltaZb}',
                        style: TextStyle(
                          fontSize: 12,
                          color: row.deltaZt >= 0 ? Colors.red : Colors.green,
                        ),
                      ),
                      const Icon(Icons.chevron_right, size: 16, color: Colors.grey),
                    ],
                  ),
            onTap: row == null ? null : () => _showDetail(row),
          );
        }).toList(),
      ),
    );
  }

  static List<dynamic> _list(Map<String, dynamic> d, String key) =>
      d[key] is List ? d[key] as List<dynamic> : <dynamic>[];

  static String _weekday(String date) {
    try {
      final DateTime dt = DateTime.parse(date);
      return const <String>['一', '二', '三', '四', '五', '六', '日'][dt.weekday - 1];
    } catch (_) {
      return '';
    }
  }

  void _showDetail(Snapshot snap) {
    final Map<String, dynamic> d = snap.detail ?? <String, dynamic>{};
    final List<dynamic> sectors = _list(d, 'sectors').take(5).toList();
    final List<dynamic> ladder = _list(d, 'ladder');
    final List<dynamic> first = _list(d, 'first');
    final List<dynamic> lbFirst = _list(d, 'lbFirst');
    final int lbCount = d['lbCount'] is int ? d['lbCount'] as int : 0;
    final int firstBoard = d['firstBoardCount'] is int
        ? d['firstBoardCount'] as int
        : 0;
    final dynamic ds = d['deltaSector'];
    final String rate = (snap.zt + snap.zb) > 0
        ? (snap.zb / (snap.zt + snap.zb) * 100).toStringAsFixed(1)
        : '0.0';
    final String dsExtra = (ds is Map && (ds['d'] is int))
        ? '，增量最多板块 ${ds['name']}（+${ds['d']} 家）'
        : '';
    final String changeLine = '较上一节点：涨停 '
        '${snap.deltaZt >= 0 ? '+' : ''}${snap.deltaZt} 家，'
        '炸板 ${snap.deltaZb >= 0 ? '+' : ''}${snap.deltaZb} 家' + dsExtra;

    String statCell(String value, String label) {
      return Expanded(
        child: Column(
          children: <Widget>[
            Text(value,
                style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    color: Colors.white)),
            const SizedBox(height: 2),
            Text(label,
                style: const TextStyle(fontSize: 11, color: Color(0xDDFFFFFF))),
          ],
        ),
      );
    }

    Widget section(String title) => Padding(
          padding: const EdgeInsets.only(top: 14, bottom: 4),
          child: Text(title,
              style: const TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w600, color: Colors.black87)),
        );

    Widget line(String text) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Text(text, style: const TextStyle(fontSize: 13, height: 1.6)),
        );

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (BuildContext ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.9,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (BuildContext ctx, ScrollController ctrl) => Container(
          decoration: const BoxDecoration(
            color: Color(0xFFF5F5F5),
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: ListView(
            controller: ctrl,
            children: <Widget>[
              Container(
                padding: const EdgeInsets.fromLTRB(16, 18, 16, 14),
                color: Colors.red,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            Text('${snap.node} 报告',
                                style: const TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.white)),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.22),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Text('盘中跟进',
                                  style: TextStyle(
                                      fontSize: 10, color: Colors.white)),
                            ),
                          ],
                        ),
                        GestureDetector(
                          onTap: () => Navigator.pop(ctx),
                          child: const Icon(Icons.close, color: Colors.white),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text('${snap.date} 周${_weekday(snap.date)}',
                        style: const TextStyle(
                            fontSize: 12, color: Color(0xDDFFFFFF))),
                  ],
                ),
              ),
              Container(
                color: Colors.red,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Row(
                  children: <Widget>[
                    statCell('${snap.zt}', '涨停'),
                    statCell('${snap.zb}', '炸板'),
                    statCell('${snap.deltaZt >= 0 ? '+' : ''}${snap.deltaZt}', '较上次'),
                    statCell(
                        ds is Map ? (ds['name']?.toString() ?? '-') : '-', '增板最多'),
                  ],
                ),
              ),
              Container(
                margin: const EdgeInsets.all(12),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    line('A股盯盘快照 · 数据源 东方财富涨停池/炸板池'),
                    const SizedBox(height: 6),
                    line('涨停 ${snap.zt} 家，炸板 ${snap.zb} 家，炸板率约 $rate%'),
                    section('涨停板块分布（前五）：'),
                    ...sectors.asMap().entries.map<Widget>((MapEntry<int, dynamic> e) {
                      final Map<String, dynamic> m = e.value as Map<String, dynamic>;
                      return line('${e.key + 1}. ${m['name']}  ${m['n']} 家');
                    }),
                    if (sectors.isEmpty) line('暂无数据'),
                    section('连板梯队：'),
                    line(ladder.isEmpty
                        ? '暂无数据'
                        : ladder
                            .map((dynamic x) =>
                                '${(x as Map<String, dynamic>)['n']}连板 ${x['c']} 家')
                            .join('，')),
                    const SizedBox(height: 4),
                    Text('（2 板及以上 $lbCount 家，首板 $firstBoard 家）',
                        style:
                            const TextStyle(fontSize: 12, color: Colors.grey)),
                    section('首批封板示例（按封板时间前 5）：'),
                    ...first.map<Widget>((dynamic x) {
                      final Map<String, dynamic> m = x as Map<String, dynamic>;
                      return line('${m['name']}（${m['fbt']} 首封）　${m['sector']}');
                    }),
                    if (first.isEmpty) line('暂无数据'),
                    section('连板个股（按封板时间前 5）：'),
                    ...lbFirst.map<Widget>((dynamic x) {
                      final Map<String, dynamic> m = x as Map<String, dynamic>;
                      return line('${m['name']}　${m['lbc']} 连板　${m['fbt']} 封板');
                    }),
                    if (lbFirst.isEmpty) line('当前无连板个股'),
                    section('节点变化与炸板：'),
                    line(changeLine),
                    const SizedBox(height: 12),
                    const Text(
                      '说明：本节点数据按东方财富首次封板时间回推，为当日已达节点的历史近似快照，'
                      '非当时时点实时抓取，仅供参考，不构成投资建议。',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
