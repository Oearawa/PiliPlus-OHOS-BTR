// Update prompt.
//
// Scope is deliberately small: this app detects a newer release, explains it,
// and opens the release page in the system browser. Downloading and installing
// stay with the user — no in-app download, no installer, no silent update.

import 'dart:async';

import 'package:PiliPlus/core/update/release_info.dart';
import 'package:PiliPlus/core/update/update_checker.dart';
import 'package:PiliPlus/core/update/update_service.dart';
import 'package:PiliPlus/utils/date_utils.dart';
import 'package:PiliPlus/utils/extension/num_ext.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:material_ui/material_ui.dart';

String _sizeLabel(int bytes) => bytes <= 0 ? '未知' : bytes.formatSize;

String _dateLabel(DateTime? at) => at == null
    ? '未知'
    : DateFormatUtils.format(
        at.millisecondsSinceEpoch ~/ 1000,
        format: DateFormatUtils.longFormatDs,
      );

/// Shows the "new version" prompt.
///
/// Returns true when the user chose to open GitHub. [isAuto] marks a check that
/// ran without the user asking; dismissing it records "later" for this tag so
/// the next automatic check stays quiet.
Future<bool> showUpdateDialog(
  BuildContext context,
  UpdateCheckResult result, {
  bool isAuto = true,
}) async {
  final ReleaseInfo? release = result.release;
  if (release == null) return false;
  final ColorScheme colorScheme = ColorScheme.of(context);
  final ReleaseAsset? asset = release.hapAsset;
  final String newest = release.version?.display ?? release.tagName;
  final String current =
      result.currentVersion?.display ?? UpdateService.currentVersion.display;

  final bool? openRelease = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      title: Text('发现新版本 $newest'),
      content: SizedBox(
        height: 320,
        width: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '当前版本：$current\n'
              '最新版本：$newest\n'
              '发布时间：${_dateLabel(release.publishedAt)}'
              '${asset == null ? '' : '\n安装包：${asset.name}（${_sizeLabel(asset.size)}）'}',
              style: const TextStyle(fontSize: 13, height: 1.6),
            ),
            if (asset == null) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                '该版本暂未提供安装包，可先到 Release 页面查看说明。',
                style: TextStyle(fontSize: 12, color: colorScheme.error),
              ),
            ],
            const SizedBox(height: 8),
            const Divider(height: 1),
            const SizedBox(height: 8),
            Expanded(
              child: SingleChildScrollView(
                child: Text(
                  release.body.trim().isEmpty
                      ? '该版本没有提供更新说明。'
                      : release.body,
                  style: const TextStyle(fontSize: 13, height: 1.5),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text('暂不更新', style: TextStyle(color: colorScheme.outline)),
        ),
        FilledButton(
          // The URL comes from the API payload, never assembled by hand, so it
          // always points at this repository's own release page.
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('前往 GitHub 下载'),
        ),
      ],
    ),
  );

  final bool open = openRelease ?? false;
  if (open) {
    final String url = release.htmlUrl;
    if (url.isEmpty) {
      SmartDialog.showToast('Release 页面地址缺失，请到项目 Releases 查看');
    } else {
      PageUtils.launchURL(url);
    }
  } else if (isAuto) {
    await UpdateService.markSkipped(result);
  }
  return open;
}

/// Runs a check and reports the outcome in the UI.
///
/// [force] is true for the manual entry points (about page, settings): those
/// bypass the cache, clear a previous "later" and always answer the user.
Future<void> runUpdateCheck(BuildContext context, {required bool force}) async {
  if (force) {
    SmartDialog.showLoading(msg: '正在检查…');
  }
  final UpdateCheckResult result = force
      ? await UpdateService.checkManually()
      : (await UpdateService.maybeAutoCheck()) ??
            const UpdateCheckResult(status: UpdateStatus.cached);
  if (force) SmartDialog.dismiss();

  if (!context.mounted) return;
  switch (result.status) {
    case UpdateStatus.available:
      await showUpdateDialog(context, result, isAuto: !force);
    case UpdateStatus.upToDate:
    case UpdateStatus.cached:
      if (force) SmartDialog.showToast('已是最新版本');
    case UpdateStatus.missingAsset:
      if (force) SmartDialog.showToast(result.message);
    case UpdateStatus.failed:
      if (force) SmartDialog.showToast(result.message);
  }
}
