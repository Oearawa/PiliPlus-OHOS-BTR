import 'dart:convert';
import 'dart:io';

Future<void> _updatePubspecVersion(int versionCode) async {
  final pubspecPath = './pubspec.yaml';
  final file = File(pubspecPath);
  if (!await file.exists()) return;

  final content = await file.readAsString();
  final lines = content.split('\n');

  for (var i = 0; i < lines.length; i++) {
    if (lines[i].startsWith('version:')) {
      final match = RegExp(
        r'version:\s*([\d.]+)(\+[\d]+)?',
      ).firstMatch(lines[i]);
      if (match != null) {
        final versionName = match.group(1)!;
        lines[i] = 'version: $versionName+$versionCode';
        await file.writeAsString(lines.join('\n'));
        break;
      }
    }
  }
}

void main() async {
  // 手动指定 versionName
  // 正式版本线：与 GitHub Tag、设置→关于、BuildConfig 完全一致。
  // 打包侧（pubspec → HAP versionName）只保留数字段，因 Flutter OHOS 会剥掉
  // 非数字字符、HarmonyOS versionName 也只接受数字与点；版本后缀由应用内
  // 版本号承载，versionCode 保证单调递增。
  const versionName = '2.2.1-ohos-2';

  // 基于基准 versionCode (6603) 叠加提交计数，保证单调递增
  final commitCount = await _getGitCommitCount();
  final versionCode = 6603 + (commitCount > 0 ? commitCount : 1);
  final commitHash = await _getGitCommitHash();

  await _updatePubspecVersion(versionCode);

  final nowUtc = DateTime.now().toUtc();
  final utcMidnight = DateTime.utc(nowUtc.year, nowUtc.month, nowUtc.day);

  final env = {
    '此环境变量由脚本自动生成': '请勿编辑',
    'pili.name': versionName,
    'pili.time': utcMidnight.millisecondsSinceEpoch ~/ 1000,
    'pili.hash': commitHash,
    'pili.code': versionCode,
    'ENABLE_FLEX_OVERFLOW': false,
  };
  File('./.vscode/env.json')
    ..createSync(recursive: true)
    ..writeAsStringSync(jsonEncode(env));
}

// 获取 Git 提交数量作为版本号
Future<int> _getGitCommitCount() async {
  try {
    final result = await Process.run('git', ['rev-list', '--count', 'HEAD']);
    if (result.exitCode == 0) {
      return int.tryParse(result.stdout.toString().trim()) ?? 0;
    }
  } catch (e) {
    print('获取 Git 提交数量失败: $e');
  }
  return 0;
}

// 获取 Git 提交哈希值
Future<String> _getGitCommitHash() async {
  try {
    final result = await Process.run('git', ['rev-parse', 'HEAD']);
    if (result.exitCode == 0) {
      return result.stdout.toString().trim();
    }
  } catch (e) {
    print('获取 Git 提交哈希值失败: $e');
  }
  return '';
}
