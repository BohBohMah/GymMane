import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Temporary, metadata-only tracing enabled for isolated test APKs at build
/// time. Never include workout names, set values, PINs, addresses or payloads.
const bool wearLinkDiagnosticsEnabled = bool.fromEnvironment('GYMMANE_WEAR_DIAGNOSTICS');
const MethodChannel _diagnosticsChannel = MethodChannel('gymmane/wearlink');

void wearLinkDiagnostic(String message) {
  if (wearLinkDiagnosticsEnabled) {
    debugPrint('[GymManeWearLink] $message');
    unawaited(
      _diagnosticsChannel.invokeMethod<void>('diagnostic', {'message': message}).catchError((Object _) {}),
    );
  }
}

String wearSnapshotSummary(Map<String, dynamic> snapshot) {
  final workoutId = snapshot['workoutId'];
  final hasWorkout = workoutId is String && workoutId.isNotEmpty;
  final exerciseCount = snapshot['exercises'] is List ? (snapshot['exercises'] as List).length : 0;
  return 'rev=${snapshot['rev']} status=${snapshot['status']} '
      'hasWorkout=$hasWorkout exercises=$exerciseCount';
}
