import 'package:flutter/material.dart';

import '../../local_store.dart';
import '../../sync/sync_controller.dart';
import '../../sync/sync_transport.dart';

class SyncSettings extends StatefulWidget {
  const SyncSettings({super.key, required this.store});
  final LocalStore store;
  @override
  State<SyncSettings> createState() => _SyncSettingsState();
}

class _SyncSettingsState extends State<SyncSettings> {
  final _account = TextEditingController();
  final _password = TextEditingController();
  final _device = TextEditingController();
  final _name = TextEditingController(text: '我的真果鉴');
  List<CloudProfile>? _profiles;
  CloudProfile? _selected;
  bool _working = false, _editing = false;
  String? _message;
  SyncController? get controller => widget.store.syncHooks is SyncController
      ? widget.store.syncHooks as SyncController
      : null;
  @override
  void initState() {
    super.initState();
    final binding = widget.store.syncState.binding;
    _account.text = binding?['account'] as String? ?? '';
    _device.text = binding?['deviceName'] as String? ?? '我的设备';
  }

  @override
  void dispose() {
    final sync = controller;
    Future.microtask(() => sync?.cancelSetup());
    for (final c in [_account, _password, _device, _name]) {
      c.dispose();
    }
    super.dispose();
  }

  void _invalidate(String _) {
    controller?.cancelSetup();
    setState(() {
      _profiles = null;
      _selected = null;
      _message = null;
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _working = true;
      _message = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) {
        setState(
          () => _message = e is SyncFailure
              ? e.message
              : '操作未完成，请检查本地存储、网络或重新测试连接',
        );
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _preview() async {
    final sync = controller!;
    final preview = await sync.preview(profile: _selected, newName: _name.text);
    if (!mounted) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认首次合并'),
        content: SingleChildScrollView(
          child: Text(
            '合并后：${preview.count('favorites')} 部追剧，${preview.count('history')} 条历史。\n\n'
            '追剧尊重云端取消记录；观看历史按有效观看时间合并；重合播放偏好采用云端值。站源开关与本地权限保持当前设置。\n\n'
            '本地恢复副本已保存：\n${preview.recoveryPath}\n\n'
            '确认后启用自动同步。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('合并并启用'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await sync.confirm(preview);
      if (mounted) {
        setState(() {
          _editing = false;
          _profiles = null;
          _password.clear();
        });
      }
    }
  }

  Future<void> _restore() async {
    final names = await widget.store.syncRecoveries();
    if (!mounted) return;
    if (names.isEmpty) {
      setState(() => _message = '当前用户没有合并前恢复副本');
      return;
    }
    final name = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('恢复合并前的本地记录'),
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('选择副本后替换当前用户的追剧、历史和播放偏好，并暂停自动同步。云端资料保留。'),
          ),
          for (final name in names)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, name),
              child: Text(
                DateTime.fromMillisecondsSinceEpoch(
                  int.parse(name.split('/').last.split('-').first),
                ).toLocal().toString().split('.').first,
              ),
            ),
        ],
      ),
    );
    if (name != null && mounted) await widget.store.restoreSyncRecovery(name);
  }

  @override
  Widget build(BuildContext context) {
    final sync = controller;
    if (sync == null) return const Text('同步服务尚未初始化');
    return ListenableBuilder(
      listenable: sync,
      builder: (context, _) {
        final state = sync.state;
        final binding = state.binding;
        final disabled = _working || sync.busy || widget.store.locked;
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 14,
              children: [
                Text('坚果云同步', style: Theme.of(context).textTheme.titleLarge),
                Text('当前本地用户：${widget.store.profile.name}'),
                const Text('同步追剧、观看进度与播放偏好。视频下载、站源账号及设备设置仅保存在本机。'),
                if (state.needsReview) const Text('恢复备份后自动同步已暂停，请重新连接并确认合并。'),
                if (binding != null) ...[
                  Text(
                    '云端资料：${binding['profileName']}\n账号：${binding['account']}',
                  ),
                  Text(
                    sync.busy
                        ? '正在同步…'
                        : '待上传操作：${state.pending}\n最近成功：${state.lastSuccess == null ? '尚未同步' : DateTime.fromMillisecondsSinceEpoch(state.lastSuccess!).toLocal().toString().split('.').first}',
                  ),
                  if (state.clockUncertain)
                    const Text('检测到本机时间偏差，续播时可能需要选择观看位置。请校准系统时间。'),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('自动同步'),
                    subtitle: const Text('启动、返回前台及观看后同步；后台不保证立即完成'),
                    value: state.automatic && !state.needsReview,
                    onChanged: disabled
                        ? null
                        : (value) => _run(() => sync.setAutomatic(value)),
                  ),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: disabled || state.needsReview
                            ? null
                            : () => _run(() => sync.synchronize(manual: true)),
                        icon: const Icon(Icons.sync),
                        label: const Text('立即同步'),
                      ),
                      OutlinedButton(
                        onPressed: disabled
                            ? null
                            : () => setState(() => _editing = !_editing),
                        child: const Text('更新连接 / 应用密码'),
                      ),
                      TextButton(
                        onPressed: disabled
                            ? null
                            : () => _run(() async {
                                await sync.disconnect();
                                if (mounted) {
                                  setState(() {
                                    _profiles = null;
                                    _editing = false;
                                    _password.clear();
                                  });
                                }
                              }),
                        child: const Text('断开连接'),
                      ),
                    ],
                  ),
                  if (state.devices.isNotEmpty) ...[
                    const Text('已同步设备'),
                    for (final entry in state.devices.entries)
                      Text(
                        '${entry.value}${entry.key == widget.store.deviceId ? '（本机）' : ''} · ${entry.key.substring(0, 8)}',
                      ),
                  ],
                  const Text('断开连接保留本地和云端资料。'),
                ],
                if (sync.error != null)
                  Text(
                    sync.error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                if (binding == null || _editing || state.needsReview) ...[
                  const Text('服务器：https://dav.jianguoyun.com/dav/'),
                  TextField(
                    controller: _account,
                    onChanged: _invalidate,
                    enabled: !disabled,
                    decoration: const InputDecoration(labelText: '坚果云账号（邮箱）'),
                  ),
                  TextField(
                    controller: _password,
                    onChanged: _invalidate,
                    enabled: !disabled,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                      labelText: '应用密码',
                      helperText: '在坚果云「账户信息 → 安全选项」中创建第三方应用密码',
                    ),
                  ),
                  TextField(
                    controller: _device,
                    onChanged: _invalidate,
                    enabled: !disabled,
                    maxLength: 80,
                    decoration: const InputDecoration(labelText: '设备名称'),
                  ),
                  OutlinedButton(
                    onPressed: disabled
                        ? null
                        : () => _run(() async {
                            final result = await sync.connect(
                              _account.text,
                              _password.text,
                              _device.text,
                            );
                            if (mounted) {
                              setState(() {
                                _profiles = result;
                                _selected = result
                                    .where((p) => p.id == binding?['profileId'])
                                    .firstOrNull;
                                _message = '测试文件上传、读回、删除均成功';
                              });
                            }
                          }),
                    child: const Text('测试连接并读取资料'),
                  ),
                  if (_profiles != null) ...[
                    DropdownButtonFormField<String>(
                      initialValue: _selected?.id ?? '',
                      decoration: const InputDecoration(labelText: '云端资料'),
                      items: [
                        const DropdownMenuItem(value: '', child: Text('创建新资料')),
                        for (final p in _profiles!)
                          DropdownMenuItem(
                            value: p.id,
                            child: Text('${p.name} · ${p.id.substring(0, 8)}'),
                          ),
                      ],
                      onChanged: disabled
                          ? null
                          : (id) => setState(
                              () => _selected = _profiles!
                                  .where((p) => p.id == id)
                                  .firstOrNull,
                            ),
                    ),
                    if (_selected == null)
                      TextField(
                        controller: _name,
                        enabled: !disabled,
                        maxLength: 80,
                        decoration: const InputDecoration(labelText: '新资料名称'),
                      ),
                    FilledButton(
                      onPressed: disabled ? null : () => _run(_preview),
                      child: const Text('预览合并'),
                    ),
                  ],
                ],
                if (_working) const LinearProgressIndicator(),
                TextButton(
                  onPressed: disabled ? null : () => _run(_restore),
                  child: const Text('恢复本机合并前副本'),
                ),
                if (_message != null) Text(_message!),
              ],
            ),
          ),
        );
      },
    );
  }
}
