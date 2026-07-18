import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'data/auth_service.dart';
import 'data/floor_repository.dart';
import 'data/local/database.dart';
import 'data/loyalty_repository.dart';
import 'data/session_controller.dart';
import 'data/order_repository.dart';
import 'data/session_repository.dart';
import 'data/sync_service.dart';
import 'data/table_repository.dart';
import 'payments/dojo_config.dart';
import 'payments/dojo_desktop.dart';
import 'payments/dojo_native.dart';
import 'payments/payment_provider.dart';
import 'ui/shell.dart';
import 'ui/sign_in_page.dart';
import 'ui/splash_page.dart';
import 'ui/theme.dart';
import 'ui/theme_controller.dart';

/// Where the server lives, as seen from the device the app is running on.
///
/// On desktop that is localhost. On the Android emulator, 10.0.2.2 is the
/// host machine — "localhost" there means the emulator itself, so the till
/// would never find the server. A real phone or tablet needs the Mac's LAN
/// address, which only you know:
///
///   flutter build apk --dart-define=API_HOST=192.168.1.42
String _defaultHost() {
  const override = String.fromEnvironment('API_HOST');
  if (override.isNotEmpty) return override;
  if (Platform.isAndroid) return '10.0.2.2';
  return 'localhost';
}

final apiBaseProvider = Provider<String>((_) {
  const full = String.fromEnvironment('API_BASE');
  if (full.isNotEmpty) return full;
  return 'http://${_defaultHost()}:4000';
});

final wsUrlProvider = Provider<String>((_) {
  const full = String.fromEnvironment('WS_URL');
  if (full.isNotEmpty) return full;
  return 'ws://${_defaultHost()}:4000/ws';
});

final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

final orderRepositoryProvider = Provider<OrderRepository>(
  (ref) => OrderRepository(ref.watch(databaseProvider)),
);

final sessionRepositoryProvider = Provider<SessionRepository>(
  (ref) => SessionRepository(ref.watch(databaseProvider)),
);

final tableRepositoryProvider = Provider<TableRepository>(
  (ref) => TableRepository(
    ref.watch(databaseProvider),
    ref.watch(orderRepositoryProvider),
  ),
);

final loyaltyRepositoryProvider = Provider<LoyaltyRepository>(
  (ref) => LoyaltyRepository(ref.watch(databaseProvider)),
);

/// Signing out: verifies the password against the live server and flushes every
/// offline sale before the session is cleared.
final authServiceProvider = Provider<AuthService>(
  (ref) => AuthService(
    apiBase: ref.watch(apiBaseProvider),
    db: ref.watch(databaseProvider),
    sync: ref.watch(syncServiceProvider),
  ),
);

/// Server-push events, surfaced from the sync service so non-DB providers can
/// refresh when the back office changes. Emits the event `type` string.
final syncEventsProvider = StreamProvider<String>((ref) {
  return ref.watch(syncServiceProvider).events;
});

/// The floor plan drawn in the back office, cached so it survives going offline.
///
/// Reloads automatically when the back office signals a floor change, so a
/// table added or moved in the office appears on the till without a manual
/// refresh.
final floorPlanProvider = FutureProvider<List<FloorRoom>>((ref) async {
  // A floor (or catalogue) push from the server re-runs this provider.
  ref.listen(syncEventsProvider, (_, next) {
    final type = next.value;
    if (type == 'floor.updated' || type == 'catalogue.updated') {
      ref.invalidateSelf();
    }
  });

  final prefs = await SharedPreferences.getInstance();
  final office = ref.watch(officeProvider);
  final repo = FloorRepository(
    apiBase: ref.watch(apiBaseProvider),
    cache: PrefsFloorCache(prefs, office: office),
    office: office,
  );
  return repo.load();
});

/// Card payments, built from the terminal's runtime Dojo config
/// ([dojoConfigProvider]) rather than a build-time flag — so a till already
/// installed on Android can have its sandbox key entered in Settings without a
/// rebuild. Null until a key is present, so a till without one shows cash only
/// instead of failing at the moment of payment.
final dojoProvider = Provider<PaymentProvider?>((ref) {
  final config = ref.watch(dojoConfigProvider).value;
  if (config == null || !config.configured) return null;

  // The REST provider creates the payment intent and, on desktop, drives the
  // whole flow. It always exists.
  final rest = DojoProvider(
    apiKey: config.apiKey.trim(),
    baseUrl: config.baseUrl,
    terminalId: config.terminalId.trim().isEmpty
        ? null
        : config.terminalId.trim(),
    softwareHouseId: config.softwareHouseId.trim().isEmpty
        ? null
        : config.softwareHouseId.trim(),
    resellerId: config.resellerId.trim().isEmpty
        ? null
        : config.resellerId.trim(),
  );

  // A card machine on the counter wins on every platform: if the venue has a
  // reader, that is how the card should be taken, not by keying it into the
  // screen. `rest` drives the terminal session directly.
  if (rest.canUseTerminal) return rest;

  // No reader. On Android the card is presented through Dojo's native drop-in
  // SDK (card entry + 3-D Secure). The native provider reuses `rest` for intent
  // creation and falls back to it if the SDK is not bundled.
  if (Platform.isAndroid) {
    return NativeDojoProvider(intents: rest, isSandbox: config.isSandboxKey);
  }

  // Desktop tills (the Windows touch-screen EPOS) have no Dojo SDK, so the card
  // is presented either by a physical reader or by Dojo's hosted checkout —
  // see DesktopDojoProvider. Plain REST polling on its own presents no card at
  // all, which is what left the till stuck on "Waiting for the card…".
  if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
    return DesktopDojoProvider(intents: rest);
  }

  return rest;
});

/// Who is signed into this terminal.
final sessionProvider = Provider<Session>(
  (ref) => ref.watch(sessionControllerProvider).value ?? Session.empty,
);

/// Which venue this terminal belongs to. Comes from the sign-in rather than a
/// build flag, so one APK can be installed in any venue.
final officeProvider = Provider<String>(
  (ref) => ref.watch(sessionProvider).office ?? '',
);

final syncServiceProvider = Provider<SyncService>((ref) {
  final sync = SyncService(
    ref.watch(databaseProvider),
    apiBase: ref.watch(apiBaseProvider),
    wsUrl: ref.watch(wsUrlProvider),
    office: ref.watch(officeProvider),
  );
  ref.onDispose(sync.dispose);
  return sync;
});

/// Live online/offline + backlog state for the till's status badge. Seeded with
/// the service's current status so the badge is correct the instant it mounts,
/// before the first stream event arrives.
final syncStatusProvider = StreamProvider<SyncStatus>((ref) {
  final sync = ref.watch(syncServiceProvider);
  return sync.status;
});

void main() {
  runApp(const ProviderScope(child: VesopaEposApp()));
}

class VesopaEposApp extends ConsumerStatefulWidget {
  const VesopaEposApp({super.key});

  @override
  ConsumerState<VesopaEposApp> createState() => _VesopaEposAppState();
}

class _VesopaEposAppState extends ConsumerState<VesopaEposApp> {
  bool _splashDone = false;

  @override
  Widget build(BuildContext context) {
    // Dark until the stored preference loads, so the app never flashes white
    // on startup before settling into the operator's actual choice.
    final mode = ref.watch(themeControllerProvider).value ?? ThemeMode.dark;
    final session = ref.watch(sessionControllerProvider);

    return MaterialApp(
      title: 'VesopaEPOS',
      debugShowCheckedModeBanner: false,
      theme: buildPosTheme(Brightness.light),
      darkTheme: buildPosTheme(Brightness.dark),
      themeMode: mode,
      home: !_splashDone
          ? SplashPage(onDone: () => setState(() => _splashDone = true))
          : switch (session) {
              // Not commissioned yet, or signed out: ask who this is. The till
              // cannot sell before it knows which venue's catalogue to load.
              AsyncData(value: final s) when !s.signedIn => const SignInPage(),
              AsyncData() => const PosShell(),
              _ => const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              ),
            },
    );
  }
}
