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
    this.apiKey = defaultSandboxKey,
    this.terminalId = '',
    this.softwareHouseId = defaultSoftwareHouseId,
    this.resellerId = defaultResellerId,
    this.sandbox = true,
  });

  /// Sandbox defaults, so a freshly built till can take a test card without
  /// anyone pasting credentials in first.
  ///
  /// The API key is deliberately NOT a literal here: this repository is public,
  /// and a key committed to source is a published key. It comes from a
  /// build-time define instead —
  ///
  ///     flutter build windows --dart-define=DOJO_API_KEY=sk_sandbox_…
  ///
  /// (CI passes it from a repository secret). With no define the till simply
  /// starts unconfigured and the operator enters a key in Settings, which is
  /// the right behaviour for a real venue anyway.
  ///
  /// The partner ids are Dojo's own published sandbox placeholders, documented
  /// publicly, so they are safe to ship as defaults. Verified: this pair lists
  /// real sandbox terminals and completes a pay-at-counter sale.
  static const defaultSandboxKey = String.fromEnvironment('DOJO_API_KEY');
  static const defaultSoftwareHouseId = String.fromEnvironment(
    'DOJO_SOFTWARE_HOUSE_ID',
    defaultValue: 'softwareHouse1',
  );
  static const defaultResellerId = String.fromEnvironment(
    'DOJO_RESELLER_ID',
    defaultValue: 'reseller1',
  );

  final String apiKey;

  /// The physical card machine id. Blank = no reader on this till, so the card
  /// is taken another way (Android drop-in, or on-screen checkout on desktop).
  final String terminalId;

  /// Partner credentials Dojo issues on onboarding. Both are required by the
  /// terminal endpoints — without `reseller-id` the call is rejected even when
  /// the software-house id is right.
  final String softwareHouseId;
  final String resellerId;

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
    String? resellerId,
    bool? sandbox,
  }) => DojoConfig(
    apiKey: apiKey ?? this.apiKey,
    terminalId: terminalId ?? this.terminalId,
    softwareHouseId: softwareHouseId ?? this.softwareHouseId,
    resellerId: resellerId ?? this.resellerId,
    sandbox: sandbox ?? this.sandbox,
  );

  Map<String, dynamic> toJson() => {
    'apiKey': apiKey,
    'terminalId': terminalId,
    'softwareHouseId': softwareHouseId,
    'resellerId': resellerId,
    'sandbox': sandbox,
  };

  factory DojoConfig.fromJson(Map<String, dynamic> j) => DojoConfig(
    apiKey: j['apiKey'] as String? ?? '',
    terminalId: j['terminalId'] as String? ?? '',
    // Tills saved before these existed fall back to the sandbox partner ids
    // rather than to blank, which would make the terminal call 401.
    softwareHouseId: j['softwareHouseId'] as String? ?? defaultSoftwareHouseId,
    resellerId: j['resellerId'] as String? ?? defaultResellerId,
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
