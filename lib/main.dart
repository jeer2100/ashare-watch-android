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
    final Map<String, dynamic>? raw = await fetchRawSnapshot();
    if (raw == null) return;
    await saveSnapshot(Snapshot.fromJson(raw));
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
        channelDescription: '每10分钟自动抓取涨停与炸板数据',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(60000),
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
  }

  Future<void> _startService() async {
    try {
      final result = await FlutterForegroundTask.startService(
        serviceTypes: const <ForegroundServiceTypes>[
          ForegroundServiceTypes.dataSync,
        ],
        serviceId: 256,
        notificationTitle: 'A股盯盘助手运行中',
        notificationText: '每10分钟自动抓取涨停 / 炸板快照',
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
      _today = all.where((Snapshot s) => s.date == today).toList()
        ..sort((Snapshot a, Snapshot b) => a.node.compareTo(b.node));
    });
  }

  Future<void> _manualFetch() async {
    setState(() => _busy = true);
    try {
      final Map<String, dynamic>? raw = await fetchRawSnapshot();
      if (raw == null) {
        _message = '当前不在抓取节点（交易日 9:40–11:30、13:00–15:00 每10分钟）';
      } else {
        await saveSnapshot(Snapshot.fromJson(raw));
        _message = '已抓取 ${raw['node']}：涨停 ${raw['zt']} / 炸板 ${raw['zb']}';
      }
    } catch (e) {
      _message = '抓取失败: $e';
    }
    await _reload();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _clear() async {
    await clearSnapshots();
    await _reload();
    if (mounted) setState(() => _message = '本地记录已清空');
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
            tooltip: '立即抓取',
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
                  _serviceOn ? '后台自动抓取已开启' : '后台自动抓取未开启',
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

  Widget _buildSummaryCard(Snapshot? latest, String todayLabel) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '$todayLabel · ${latest == null ? '暂无快照' : '${latest.node} 快照'}',
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
                ? const Text('待更新', style: TextStyle(fontSize: 13, color: Colors.grey))
                : Text(
                    '涨停 ${row.zt}  ·  炸板 ${row.zb}  ·  ${row.topSector}',
                    style: const TextStyle(fontSize: 13),
                  ),
            trailing: row == null
                ? null
                : Text(
                    '${row.deltaZt >= 0 ? '+' : ''}${row.deltaZt} / ${row.deltaZb >= 0 ? '+' : ''}${row.deltaZb}',
                    style: TextStyle(
                      fontSize: 12,
                      color: row.deltaZt >= 0 ? Colors.red : Colors.green,
                    ),
                  ),
          );
        }).toList(),
      ),
    );
  }
}
