import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'data/auth_service.dart';
import 'data/branding.dart';
import 'data/commerce.dart';
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

/// Card payments where the card is **keyed in** rather than presented.
///
/// Deliberately skips the terminal path that [dojoProvider] prefers. A card
/// machine can only take a card that is physically there; "manual card" is for
/// a chip that will not read, a telephone order, or a card taken from a
/// booking — so it routes to the same card-entry product the till used before
/// readers were supported:
///
///   * Android — Dojo's native drop-in SDK, which presents its own card form.
///   * Desktop — Dojo's hosted checkout in a browser window.
///
/// Returns null when Dojo is not configured at all, so the button can be
/// refused cleanly rather than failing at the moment of payment.
final manualCardProvider = Provider<PaymentProvider?>((ref) {
  final config = ref.watch(dojoConfigProvider).value;
  if (config == null || !config.configured) return null;

  // No terminalId: this provider must never reach for the card machine, even
  // on a till that has one paired.
  final rest = DojoProvider(
    apiKey: config.apiKey.trim(),
    baseUrl: config.baseUrl,
    softwareHouseId: config.softwareHouseId.trim().isEmpty
        ? null
        : config.softwareHouseId.trim(),
    resellerId: config.resellerId.trim().isEmpty
        ? null
        : config.resellerId.trim(),
  );

  if (Platform.isAndroid) {
    return NativeDojoProvider(intents: rest, isSandbox: config.isSandboxKey);
  }
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

/// What this venue prints on its receipts, owned by the back office.
final brandingRepositoryProvider = Provider<BrandingRepository>(
  (ref) => BrandingRepository(
    apiBase: ref.watch(apiBaseProvider),
    office: ref.watch(officeProvider),
  ),
);

/// The branding a receipt is built from.
///
/// Exposed as the plain [Branding] rather than an AsyncValue: printing must
/// never block on this, so a till that has not loaded it yet prints with
/// defaults instead of waiting or failing.
/// Reads whatever branding has already been fetched.
///
/// Deliberately pure: it starts no network work of its own, so reading it on
/// the way to the printer cannot stall a receipt (or, in a test, leave a
/// pending timer behind). [brandingRefreshProvider] does the fetching.
final brandingProvider = Provider<Branding>(
  (ref) => ref.watch(brandingRepositoryProvider).cached ?? const Branding(),
);

/// Keeps branding current in the background.
///
/// Watched once by the shell at startup rather than at print time, and
/// re-fetched when the back office broadcasts a change, so a new footer or
/// logo reaches the tills without anyone restarting a terminal.
final brandingRefreshProvider = FutureProvider<Branding>((ref) async {
  final office = ref.watch(officeProvider);
  // Before sign-in there is no venue to fetch for.
  if (office.isEmpty) return const Branding();

  ref.listen(syncEventsProvider, (_, next) {
    if (next.value == 'branding') ref.invalidateSelf();
  });

  final branding = await ref.watch(brandingRepositoryProvider).load();
  // Publish the freshly cached copy to anything about to print.
  ref.invalidate(brandingProvider);
  return branding;
});

/// Vouchers, gift cards, deposits, loyalty and promotions.
final commerceRepositoryProvider = Provider<CommerceRepository>(
  (ref) => CommerceRepository(
    apiBase: ref.watch(apiBaseProvider),
    office: ref.watch(officeProvider),
  ),
);

/// How this venue takes money. Cached, so the payment screen never waits.
final tenderSettingsProvider = Provider<TenderSettings>(
  (ref) => ref.watch(commerceRepositoryProvider).tenderSettings,
);

/// The offers live right now. Read from cache for the same reason: pricing a
/// basket happens on every tap and must not touch the network.
final promotionsProvider = Provider<List<Promotion>>(
  (ref) => ref.watch(commerceRepositoryProvider).promotions,
);

/// Pulls tender settings and promotions in the background, and refreshes them
/// when the back office changes either.
final commerceRefreshProvider = FutureProvider<void>((ref) async {
  final office = ref.watch(officeProvider);
  if (office.isEmpty) return;

  ref.listen(syncEventsProvider, (_, next) {
    const watched = {'promotions', 'tender.settings', 'loyalty', 'vouchers'};
    if (watched.contains(next.value)) ref.invalidateSelf();
  });

  final repo = ref.watch(commerceRepositoryProvider);
  await repo.loadTenderSettings();
  await repo.loadPromotions();

  // Publish the freshly cached copies to anything about to price a basket.
  ref.invalidate(tenderSettingsProvider);
  ref.invalidate(promotionsProvider);
});

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
