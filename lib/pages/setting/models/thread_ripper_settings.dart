// Settings entries for the native thread-ripper (BTR) integration.
//
// Kept in this file instead of `video_settings.dart` so upstream changes to
// the long video-settings list only conflict on the single spread that adds
// these entries. The widgets are the existing `SwitchModel` / `NormalModel`
// and `SelectDialog`, so the rows look and behave exactly like the rest of the
// settings page.

import 'package:PiliPlus/pages/setting/models/model.dart';
import 'package:PiliPlus/pages/setting/widgets/select_dialog.dart';
import 'package:PiliPlus/services/thread_ripper/auto_concurrency.dart';
import 'package:PiliPlus/services/thread_ripper/player_bridge.dart';
import 'package:PiliPlus/services/thread_ripper/prefs.dart';
import 'package:PiliPlus/services/thread_ripper/range_core.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:material_ui/material_ui.dart';

const List<(int, String)> _cdnModes = <(int, String)>[
  (0, '大陆节点'),
  (1, '海外节点'),
  (2, '自定义节点'),
];

String get _modeLabel {
  final int index = RipperPrefs.modeIndex;
  if (index == 2 && RipperPrefs.customHosts.isEmpty) {
    return '自定义（未设置节点，暂用海外）';
  }
  if (index == 2) {
    return '自定义（${RipperPrefs.customHosts.length} 个节点）';
  }
  return _cdnModes.firstWhere((item) => item.$1 == index).$2;
}

Future<void> _showModeDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final int? result = await showDialog<int>(
    context: context,
    builder: (context) => SelectDialog<int>(
      title: 'CDN 节点区域',
      value: RipperPrefs.modeIndex,
      values: _cdnModes,
    ),
  );
  if (result != null) {
    RipperPrefs.modeIndex = result;
    setState();
    SmartDialog.showToast('需重新打开视频生效');
  }
}

Future<void> _showConcurrencyDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final int? result = await showDialog<int>(
    context: context,
    builder: (context) => SelectDialog<int>(
      title: '最大连接数',
      value: RipperPrefs.concurrency,
      values: AutoConcurrency.ladder
          .map((int value) => (value, '$value'))
          .toList(),
    ),
  );
  if (result != null) {
    RipperPrefs.concurrency = result;
    setState();
    SmartDialog.showToast('需重新打开视频生效');
  }
}

/// Editor for the custom CDN hosts.
///
/// One host per line; anything that is not on Bilibili's media whitelist is
/// dropped instead of being stored, because a signed address must never be
/// sent to an arbitrary server typed in by mistake.
Future<void> _showCustomHostsDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final TextEditingController controller = TextEditingController(
    text: RipperPrefs.customHosts.join('\n'),
  );
  final List<String>? result = await showDialog<List<String>>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('自定义 CDN 节点'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            '每行一个主机名或完整地址，例如 upos-sz-mirrorhw.bilivideo.com。'
            '只接受 B 站媒体域名；保存后会在节点区域里自动选中“自定义”。',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: controller,
            maxLines: 8,
            minLines: 4,
            decoration: const InputDecoration(
              hintText: 'upos-sz-mirrorhw.bilivideo.com',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () {
            final List<String> hosts = <String>[];
            for (final String line in controller.text.split(
              RegExp(r'[\s,，]+'),
            )) {
              final String? host = normalizeCdnHost(line);
              if (host != null && !hosts.contains(host)) hosts.add(host);
            }
            Navigator.of(context).pop(hosts);
          },
          child: const Text('保存'),
        ),
      ],
    ),
  );
  controller.dispose();
  if (result == null) return;
  RipperPrefs.customHosts = result;
  if (result.isNotEmpty && RipperPrefs.modeIndex != 2) {
    RipperPrefs.modeIndex = 2;
  }
  setState();
  SmartDialog.showToast('已保存 ${result.length} 个节点，需重新打开视频生效');
}

/// Shows the live measurements of the running session.
///
/// Every number comes from the controller or the shared semaphore; when no
/// session is active the dialog says so instead of showing zeros.
Future<void> _showDiagnosticsDialog(BuildContext context) async {
  await showDialog<void>(
    context: context,
    builder: (context) {
      final Map<String, Object?>? status =
          RipperPlayerBridge.instance.diagnostics();
      final List<String> events = status == null
          ? const <String>[]
          : (status['events'] as List<Object?>? ?? const <Object?>[])
                .map((Object? event) => '$event')
                .toList();
      final List<String> rows = status == null
          ? const <String>['当前没有活动的代理会话（打开视频后返回此处查看）。']
          : <String>[
              '模式：${status['mode'] == 'manual' ? '手动固定档位' : '自动并发'}',
              '状态：${status['state']}',
              '实际并发：${status['threads']} / 上限 ${status['maxThreads']}',
              '活动请求：${status['active']}，等待队列：${status['queued']}',
              '有效吞吐：${status['goodputMbps'] == null ? '未测量' : '${status['goodputMbps']} MB/s'}',
              '连接饱和占比：${status['saturation'] ?? '未测量'}',
              '最近调档原因：${status['reason']}',
              if (status['demandMbps'] != null)
                '码率需求：${status['demandMbps']} Mbps',
              if (status['resting'] != null)
                '冷却中的档位：${(status['resting'] as List<Object?>).join(', ')}',
              '已注册轨道：${status['tracks']}，本地端口：${status['port']}',
            ];
      return AlertDialog(
        title: const Text('BTR 自动并发诊断'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                for (final String row in rows)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(row, style: const TextStyle(fontSize: 13)),
                  ),
                if (events.isNotEmpty) ...<Widget>[
                  const Divider(),
                  const Text(
                    '最近调档记录',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                  const SizedBox(height: 6),
                  for (final String event in events.reversed.take(8))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        '· $event',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      );
    },
  );
}

String _diagnosticsSubtitle() {
  final Map<String, Object?>? status =
      RipperPlayerBridge.instance.diagnostics();
  if (status == null) return '无活动会话';
  final Object? goodput = status['goodputMbps'];
  return '${status['state']} · ${status['threads']}/${status['maxThreads']} · '
      '活动 ${status['active']} · 排队 ${status['queued']} · '
      '${goodput == null ? '吞吐未测量' : '$goodput MB/s'}';
}

/// Rows appended to the video settings page.
List<SettingsModel> get threadRipperSettings => <SettingsModel>[
  SwitchModel(
    title: '启用多线程视频加速 (BTR)',
    subtitle:
        '通过本地代理并发下载 DASH 音视频，改善海外观看体验；'
        '默认关闭，切换后需重新打开视频生效',
    leading: const Icon(Icons.speed),
    setKey: RipperPrefs.enabledKey,
    defaultVal: false,
    onChanged: (_) {
      SmartDialog.showToast('需重新打开视频生效');
    },
  ),
  NormalModel(
    title: 'CDN 节点区域',
    leading: const Icon(Icons.public),
    getSubtitle: () => '当前：$_modeLabel',
    onTap: _showModeDialog,
  ),
  NormalModel(
    title: '自定义 CDN 节点',
    leading: const Icon(Icons.dns_outlined),
    getSubtitle: () {
      final List<String> hosts = RipperPrefs.customHosts;
      if (hosts.isEmpty) return '未设置；仅在选择“自定义”时使用';
      return hosts.join('、');
    },
    onTap: _showCustomHostsDialog,
  ),
  SwitchModel(
    title: '自动并发',
    subtitle: '按码率确定初值，并根据缓冲、吞吐与限流反馈升到 64；关闭后使用下方手动档位',
    leading: const Icon(Icons.auto_graph),
    setKey: RipperPrefs.autoConcurrencyKey,
    defaultVal: true,
    onChanged: (_) => SmartDialog.showToast('需重新打开视频生效'),
  ),
  SwitchModel(
    title: '剧集加速',
    subtitle: '番剧/电影等 PGC 也走代理；DRM 与试看剧集仍直连',
    leading: const Icon(Icons.movie_outlined),
    setKey: RipperPrefs.episodeEnabledKey,
    defaultVal: true,
    onChanged: (_) => SmartDialog.showToast('需重新打开视频生效'),
  ),
  NormalModel(
    title: '手动并发档位',
    leading: const Icon(Icons.call_split),
    getSubtitle: () => RipperPrefs.autoConcurrency
        ? '当前手动档位 ${RipperPrefs.concurrency}；自动模式不受此值限制'
        : '当前固定使用 ${RipperPrefs.concurrency} 个连接',
    onTap: _showConcurrencyDialog,
  ),
  NormalModel(
    title: '自动并发诊断',
    leading: const Icon(Icons.monitor_heart_outlined),
    getSubtitle: _diagnosticsSubtitle,
    onTap: (BuildContext context, VoidCallback setState) =>
        _showDiagnosticsDialog(context),
  ),
];
