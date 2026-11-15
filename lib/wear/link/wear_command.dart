import 'dart:convert';

class WearCommand {
  const WearCommand({required this.id, required this.baseRev, required this.action, this.args = const {}});

  final String id;
  final int baseRev;
  final String action;
  final Map<String, dynamic> args;

  static WearCommand? fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String?;
    final action = json['action'] as String?;
    if (id == null || id.isEmpty || id.length > 80 || action == null || action.isEmpty) return null;
    final raw = json['args'];
    return WearCommand(
      id: id,
      baseRev: (json['baseRev'] as num?)?.toInt() ?? 0,
      action: action,
      args: raw is Map ? raw.cast<String, dynamic>() : const {},
    );
  }

  Map<String, dynamic> toJson() => {'id': id, 'baseRev': baseRev, 'action': action, 'args': args};
}

class WearAck {
  const WearAck({required this.id, required this.ok, required this.rev, required this.code, this.message});

  final String id;
  final bool ok;
  final int rev;
  final String code;
  final String? message;

  WearAck withRev(int next) => WearAck(id: id, ok: ok, rev: next, code: code, message: message);

  Map<String, dynamic> toJson() => {
        'id': id,
        'ok': ok,
        'rev': rev,
        'code': code,
        if (message != null) 'message': message,
      };

  String toJsonString() => jsonEncode(toJson());
}

class WearExecution {
  const WearExecution({required this.ok, required this.code, this.changed = false, this.message});

  final bool ok;
  final String code;
  final bool changed;
  final String? message;

  static const noSession = WearExecution(ok: false, code: 'no_session');
  static const invalid = WearExecution(ok: false, code: 'invalid');
  static const conflict = WearExecution(ok: false, code: 'conflict');
  static const noPending = WearExecution(ok: false, code: 'no_pending');
  static const unchanged = WearExecution(ok: true, code: 'ok');
  static const changedOk = WearExecution(ok: true, code: 'ok', changed: true);
  static const unsupported = WearExecution(ok: false, code: 'unsupported');
}
