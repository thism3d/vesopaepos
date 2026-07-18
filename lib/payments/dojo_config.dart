import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Dojo card-payment credentials for this terminal.
///
/// Held at runtime rather than baked into the APK with `--dart-define`, so a
/// till already installed on an Android device can be given its sandbox key on
/// the device — no rebuild, no reinstall. A build-time define still seeds the
/// default (handy for desktop dev), but anything entered in Settings overrides
/// it and persists.
class DojoConfig {
  const DojoConfig({
    this.apiKey = '',
    this.terminalId = '',
    this.softwareHouseId = '',
    this.sandbox = true,
  });

  final String apiKey;

  /// The physical card machine id. Blank = card-not-present (intent only).
  final String terminalId;

  /// Partner credential Dojo issues on onboarding; needed for the terminal
  /// endpoint. Blank until Dojo grant one.
  final String softwareHouseId;

  /// Sandbox vs live.
  ///
  /// This does NOT change the host — there is no separate sandbox host. The old
  /// code pointed sandbox at `api.sandbox.dojo.tech`, which does not resolve
  /// (NXDOMAIN), so every sandbox request failed to connect. Dojo instead
  /// routes by the key: a `sk_sandbox_…` key on the single host `api.dojo.tech`
  /// returns sandbox intents (`pi_sandbox_…`). The native SDK is told it is a
  /// sandbox intent via [DojoSDKDebugConfig.isSandboxIntent].
  final bool sandbox;

  bool get configured => apiKey.trim().isNotEmpty;

  /// Whether the configured key is a sandbox key. Dojo sandbox keys are
  /// prefixed `sk_sandbox_`; this is what selects sandbox behaviour, not a host.
  bool get isSandboxKey => apiKey.trim().startsWith('sk_sandbox_') || sandbox;

  /// Dojo has one API host for both sandbox and live; the key decides which
  /// environment a request lands in. See [sandbox] for why there is no separate
  /// sandbox host.
  String get baseUrl => 'https://api.dojo.tech';

  DojoConfig copyWith({
    String? apiKey,
    String? terminalId,
    String? softwareHouseId,
    bool? sandbox,
  }) => DojoConfig(
    apiKey: apiKey ?? this.apiKey,
    terminalId: terminalId ?? this.terminalId,
    softwareHouseId: softwareHouseId ?? this.softwareHouseId,
    sandbox: sandbox ?? this.sandbox,
  );

  Map<String, dynamic> toJson() => {
    'apiKey': apiKey,
    'terminalId': terminalId,
    'softwareHouseId': softwareHouseId,
    'sandbox': sandbox,
  };

  factory DojoConfig.fromJson(Map<String, dynamic> j) => DojoConfig(
    apiKey: j['apiKey'] as String? ?? '',
    terminalId: j['terminalId'] as String? ?? '',
    softwareHouseId: j['softwareHouseId'] as String? ?? '',
    sandbox: j['sandbox'] as bool? ?? true,
  );
}

/// Persisted Dojo config, editable from Settings. Seeds from the build-time
/// defines the first run so an APK built with the key still works out of the
/// box, then honours whatever the operator saves.
class DojoConfigController extends AsyncNotifier<DojoConfig> {
  static const _key = 'dojo_config';

  static const _seedKey = String.fromEnvironment('DOJO_API_KEY');
  static const _seedTerminal = String.fromEnvironment('DOJO_TERMINAL_ID');
  static const _seedSoftwareHouse = String.fromEnvironment(
    'DOJO_SOFTWARE_HOUSE_ID',
  );

  @override
  Future<DojoConfig> build() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw != null) {
      try {
        return DojoConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      } catch (_) {
        // Fall through to the seed on a corrupt value.
      }
    }
    return const DojoConfig().copyWith(
      apiKey: _seedKey.isEmpty ? null : _seedKey,
      terminalId: _seedTerminal.isEmpty ? null : _seedTerminal,
      softwareHouseId: _seedSoftwareHouse.isEmpty ? null : _seedSoftwareHouse,
    );
  }

  Future<void> save(DojoConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(config.toJson()));
    state = AsyncData(config);
  }
}

final dojoConfigProvider =
    AsyncNotifierProvider<DojoConfigController, DojoConfig>(
      DojoConfigController.new,
    );
