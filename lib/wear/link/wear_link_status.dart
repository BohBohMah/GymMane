enum WearLinkState { unsupported, disabled, idle, connecting, connected, pairing, error }

class WearLinkStatus {
  const WearLinkStatus({
    this.supported = false,
    this.enabled = false,
    this.state = WearLinkState.disabled,
    this.deviceName = '',
    this.address = '',
    this.error = '',
    this.pairingCode = '',
    this.pairingUntil,
    this.sdk = 0,
    this.pairedCount = 0,
  });

  final bool supported;
  final bool enabled;
  final WearLinkState state;
  final String deviceName;
  final String address;
  final String error;
  final String pairingCode;
  final DateTime? pairingUntil;
  final int sdk;
  final int pairedCount;

  bool get connected => state == WearLinkState.connected;
  bool get pairing => state == WearLinkState.pairing && pairingCode.isNotEmpty;

  static WearLinkStatus fromMap(Map<dynamic, dynamic>? raw) {
    if (raw == null) return const WearLinkStatus();
    final value = raw.cast<String, dynamic>();
    final state = switch (value['state'] as String? ?? 'disabled') {
      'unsupported' => WearLinkState.unsupported,
      'idle' => WearLinkState.idle,
      'connecting' => WearLinkState.connecting,
      'connected' => WearLinkState.connected,
      'pairing' => WearLinkState.pairing,
      'error' => WearLinkState.error,
      _ => WearLinkState.disabled,
    };
    return WearLinkStatus(
      supported: value['supported'] as bool? ?? false,
      enabled: value['enabled'] as bool? ?? false,
      state: state,
      deviceName: value['deviceName'] as String? ?? '',
      address: value['address'] as String? ?? '',
      error: value['error'] as String? ?? '',
      pairingCode: value['pairingCode'] as String? ?? '',
      pairingUntil: DateTime.tryParse(value['pairingUntil'] as String? ?? ''),
      sdk: (value['sdk'] as num?)?.toInt() ?? 0,
      pairedCount: (value['pairedCount'] as num?)?.toInt() ?? 0,
    );
  }
}
