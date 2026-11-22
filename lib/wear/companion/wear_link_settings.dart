import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../l10n/l10n.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../../widgets/dialogs.dart';
import '../../widgets/glass.dart';
import '../../widgets/ui_kit.dart';
import '../link/wear_link_server.dart';
import '../link/wear_link_status.dart';

class WearLinkSettings extends StatefulWidget {
  const WearLinkSettings({super.key});

  static void show(BuildContext context) => showAppSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const WearLinkSettings(),
  );

  @override
  State<WearLinkSettings> createState() => _WearLinkSettingsState();
}

class _WearLinkSettingsState extends State<WearLinkSettings> {
  final _link = WearLinkServer.instance;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _link.refresh();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy || !mounted) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forget() async {
    final ok = await askConfirm(
      context,
      title: t.wearLinkPhoneForget,
      body: t.wearLinkPhoneForgetBody,
      confirmLabel: t.wearLinkPhoneForget,
      danger: true,
    );
    if (ok) await _run(_link.forget);
  }

  @override
  Widget build(BuildContext context) {
    final gc = context.gc;
    return Container(
      padding: sheetPad(context),
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.9),
      decoration: sheetDecoration(gc),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SheetHandle(),
          const SizedBox(height: 14),
          Flexible(
            child: SingleChildScrollView(
              child: ValueListenableBuilder<WearLinkStatus>(
                valueListenable: _link.status,
                builder: (context, status, _) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SheetTitle(t.wearLinkPhoneTitle, subtitle: t.wearLinkPhoneBody),
                    const SizedBox(height: 16),
                    SoftCard(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(PhosphorIconsRegular.deviceMobile, size: 32, color: gc.text),
                          const SizedBox(width: 18),
                          Icon(PhosphorIconsBold.bluetooth, size: 23, color: status.connected ? gc.sage : gc.accent),
                          const SizedBox(width: 18),
                          Icon(PhosphorIconsRegular.watch, size: 32, color: gc.text),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    SoftCard(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      child: SwitchListTile.adaptive(
                        contentPadding: EdgeInsets.zero,
                        title: Text(t.wearLinkPhoneEnable),
                        value: status.enabled,
                        onChanged: status.supported && !_busy ? (on) => _run(() => _link.setEnabled(on)) : null,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _status(status),
                      textAlign: TextAlign.center,
                      style: AppTheme.f(
                        13,
                        weight: FontWeight.w600,
                        color: status.connected ? gc.sage : gc.textSecondary,
                      ),
                    ),
                    if (status.supported && status.enabled) ...[
                      if (!status.connected) ...[
                        const SizedBox(height: 12),
                        PrimaryButton(
                          label: t.wearLinkPhonePair,
                          onTap: _busy
                              ? null
                              : () => _run(() async {
                                  await _link.beginPairing();
                                }),
                        ),
                      ],
                      if (status.pairedCount > 0)
                        GhostButton(label: t.wearLinkPhoneForget, icon: PhosphorIconsRegular.linkBreak, onTap: _forget),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _status(WearLinkStatus status) {
    if (!status.supported) return t.wearLinkPhoneUnsupported;
    if (status.error == 'permission') return t.wearLinkPhonePermission;
    if (status.error.isNotEmpty) return t.wearLinkPhoneError(status.error);
    if (status.connected) return t.wearLinkPhoneConnectedTo(status.deviceName);
    if (status.enabled) return t.wearLinkPhoneWaiting;
    return t.wearLinkPhoneOff;
  }
}
