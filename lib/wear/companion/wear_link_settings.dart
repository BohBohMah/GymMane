import 'dart:async';

import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../l10n/l10n.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../../widgets/dialogs.dart';
import '../../widgets/ui_kit.dart';
import '../link/wear_link_server.dart';
import '../link/wear_link_status.dart';

/// Phone-side controls for the opt-in watch link.
class WearLinkSettings extends StatefulWidget {
  const WearLinkSettings({super.key});

  @override
  State<WearLinkSettings> createState() => _WearLinkSettingsState();
}

class _WearLinkSettingsState extends State<WearLinkSettings> {
  final WearLinkServer _link = WearLinkServer.instance;
  Timer? _ticker;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _link.refresh();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _toggle(bool on) async {
    if (_busy) return;
    setState(() => _busy = true);
    await _link.setEnabled(on);
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _pair() async {
    if (_busy) return;
    setState(() => _busy = true);
    await _link.beginPairing();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _cancel() async {
    await _link.cancelPairing();
    if (mounted) setState(() {});
  }

  Future<void> _forget() async {
    final ok = await askConfirm(
      context,
      title: t.wearLinkPhoneForget,
      body: t.wearLinkPhoneForgetBody,
      confirmLabel: t.wearLinkPhoneForget,
      danger: true,
    );
    if (!ok) return;
    await _link.forget();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final gc = context.gc;
    return ValueListenableBuilder<WearLinkStatus>(
      valueListenable: _link.status,
      builder: (context, status, _) {
        return SoftCard(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                t.wearLinkPhoneBody,
                style: AppTheme.f(13,
                    weight: FontWeight.w500, color: gc.textSecondary, height: 1.45),
              ),
              const SizedBox(height: 16),
              Semantics(
                toggled: status.enabled,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: status.supported && !_busy ? () => _toggle(!status.enabled) : null,
                  child: Row(
                    children: [
                      Icon(PhosphorIconsRegular.watch, size: 19, color: gc.text),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          t.wearLinkPhoneEnable,
                          style: AppTheme.f(14, weight: FontWeight.w600, color: gc.text),
                        ),
                      ),
                      if (_busy)
                        const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      else
                        TinySwitch(on: status.enabled),
                    ],
                  ),
                ),
              ),
              if (!status.supported) ...[
                const SizedBox(height: 12),
                Text(
                  t.wearLinkPhoneUnsupported,
                  style: AppTheme.f(12.5, weight: FontWeight.w500, color: gc.warn, height: 1.4),
                ),
              ],
              if (status.supported && status.enabled) ...[
                const SizedBox(height: 14),
                Divider(color: gc.border, height: 1),
                const SizedBox(height: 14),
                _statusLine(gc, status),
                if (status.pairing) ...[
                  const SizedBox(height: 14),
                  Text(
                    t.wearLinkPhonePairingTitle,
                    textAlign: TextAlign.center,
                    style: AppTheme.f(12.5, weight: FontWeight.w600, color: gc.textSecondary),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    status.pairingCode,
                    textAlign: TextAlign.center,
                    style: AppTheme.f(40,
                        weight: FontWeight.w800, color: gc.ember, letterSpacing: 8),
                  ),
                  Text(
                    '${t.wearLinkPhonePairingHint}  ${_left(status)}',
                    textAlign: TextAlign.center,
                    style: AppTheme.f(11.5, weight: FontWeight.w500, color: gc.textTertiary),
                  ),
                  const SizedBox(height: 12),
                  GhostButton(
                    label: t.cancel,
                    icon: PhosphorIconsRegular.x,
                    onTap: _cancel,
                  ),
                ] else ...[
                  const SizedBox(height: 12),
                  PrimaryButton(
                    label: t.wearLinkPhonePair,
                    onTap: _busy ? null : _pair,
                  ),
                ],
                const SizedBox(height: 8),
                GhostButton(
                  label: t.wearLinkPhoneForget,
                  icon: PhosphorIconsRegular.linkBreak,
                  onTap: _forget,
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _statusLine(GymColors gc, WearLinkStatus status) {
    final String text;
    final Color color;
    if (status.error == 'permission') {
      text = t.wearLinkPhonePermission;
      color = gc.warn;
    } else if (status.error.isNotEmpty) {
      text = t.wearLinkPhoneError(status.error);
      color = gc.danger;
    } else if (status.connected) {
      text = t.wearLinkPhoneConnectedTo(status.deviceName);
      color = gc.sage;
    } else if (status.pairing) {
      text = t.wearLinkPhoneWaiting;
      color = gc.accent;
    } else if (status.enabled) {
      text = t.wearLinkPhoneWaiting;
      color = gc.textSecondary;
    } else {
      text = t.wearLinkPhoneOff;
      color = gc.textTertiary;
    }
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: AppTheme.f(12.5, weight: FontWeight.w600, color: color),
          ),
        ),
      ],
    );
  }

  String _left(WearLinkStatus status) {
    final until = status.pairingUntil;
    if (until == null) return '';
    final left = until.difference(DateTime.now()).inSeconds;
    if (left <= 0) return '0:00';
    return '${left ~/ 60}:${(left % 60).toString().padLeft(2, '0')}';
  }
}
