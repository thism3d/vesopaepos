import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'config/constants.dart';
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
import 'payments/connect_pac.dart';
import 'payments/connect_ws.dart';
import 'payments/dojo_config.dart';
import 'payments/dojo_desktop.dart';
import 'payments/dojo_native.dart';
import 'payments/payment_provider.dart';
import 'ui/shell.dart';
import 'ui/sign_in_page.dart';
import 'ui/splash_page.dart';
import 'ui/theme.dart';
import 'ui/theme_controller.dart';

/// Where the server lives. Both resolve from [Api], which reads the single
/// `useLiveServer` switch in `config/constants.dart` — see that file to move
/// the app between the local and live servers.
final apiBaseProvider = Provider<String>((_) => Api.resolvedBase);

final wsUrlProvider = Provider<String>((_) => Api.resolvedWs);

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

/// The REST client for whichever acquirer this till is configured against.
///
/// Which one is decided by the **base URL**, because Dojo and Paymentsense
/// Connect are two different APIs behind one brand: Connect gives each merchant
/// their own host and drives the PDQ directly, Dojo shares one host and routes
/// by the key. Null until both a key and a URL are present.
({DojoProvider? dojo, ConnectPacProvider? connect})? _cardClients(
  DojoConfig? config, {
  required bool keyed,
}) {
  if (config == null || !config.configured) return null;

  final key = config.apiKey.trim();
  final terminal = config.terminalId.trim();
  final softwareHouse = config.softwareHouseId.trim();
  final reseller = config.resellerId.trim();

  if (config.platform == CardPlatform.connect) {
    // Connect keeps the reader for both routes: a keyed sale is the same
    // terminal transaction with `cardholderNotPresent` set, which sends the PDQ
    // straight to its "Key card number" screen. There is no other card surface
    // on a Connect account, so dropping the TID for the keyed route would leave
    // the button with nothing to talk to.
    return (
      dojo: null,
      connect: ConnectPacProvider(
        baseUrl: config.normalisedBaseUrl,
        apiKey: key,
        terminalId: terminal.isEmpty ? null : terminal,
        softwareHouseId: softwareHouse.isEmpty ? null : softwareHouse,
        installerId: reseller.isEmpty ? null : reseller,
      )
        // The socket is the preferred transport: the reader pushes each prompt
        // as it happens rather than the till polling for it once a second. The
        // provider falls back to REST on its own if this will not open, so a
        // venue is never left unable to take a card.
        ..socket = ConnectSocket(
          baseUrl: config.normalisedBaseUrl,
          apiKey: key,
          softwareHouseId: softwareHouse.isEmpty ? null : softwareHouse,
          installerId: reseller.isEmpty ? null : reseller,
        ),
    );
  }

  return (
    dojo: DojoProvider(
      apiKey: key,
      baseUrl: config.normalisedBaseUrl,
      // A keyed card must never reach for the reader, even on a till that has
      // one paired: a card machine can only take a card that is in the room.
      terminalId: keyed || terminal.isEmpty ? null : terminal,
      softwareHouseId: softwareHouse.isEmpty ? null : softwareHouse,
      resellerId: reseller.isEmpty ? null : reseller,
    ),
    connect: null,
  );
}

/// **Card** — a card the customer presents. Always the card machine where one
/// is configured, on Android and on Windows alike: that is what integrated
/// payments are for, and it is the only route that takes a chip or a tap.
///
/// Built from the terminal's runtime config ([dojoConfigProvider]) rather than
/// a build-time flag, so a till already installed can have its credentials
/// entered in Settings without a rebuild. Null until they are, so a till
/// without them shows cash only instead of failing at the moment of payment.
///
/// With no reader configured there is nothing to present a card *to*, so this
/// falls back to the same card-entry route as [manualCardProvider] rather than
/// leaving the Card button dead. Settings says plainly which of the two is
/// live.
final dojoProvider = Provider<PaymentProvider?>((ref) {
  final config = ref.watch(dojoConfigProvider).value;
  final clients = _cardClients(config, keyed: false);
  if (clients == null) return null;

  final connect = clients.connect;
  if (connect != null) return connect;

  final rest = clients.dojo!;
  // A reader on the counter drives the sale directly, on every platform.
  if (rest.canUseTerminal) return rest;

  return _keyedFallback(rest, config!);
});

/// **Manual card** — the number is keyed rather than presented, for a chip that
/// will not read, a telephone order, or a card taken from a booking. Recorded
/// separately because it carries different liability from a dipped card.
///
/// Where the keying happens is the acquirer's business, not the till's:
///
///   * Connect — on the PDQ itself, via `cardholderNotPresent`.
///   * Dojo on Android — the native drop-in SDK's own card form
///     (`tech.dojo.pay:uisdk`), in the app.
///   * Dojo on Windows — Dojo publish no desktop card SDK (`Dojo.Net` is a
///     server-side `PaymentIntentsClient` with no UI), so it is the hosted
///     checkout, rendered inside the till by `CardCheckoutPage` rather than
///     handed to a browser.
final manualCardProvider = Provider<PaymentProvider?>((ref) {
  final config = ref.watch(dojoConfigProvider).value;
  final clients = _cardClients(config, keyed: true);
  if (clients == null) return null;

  final connect = clients.connect;
  if (connect != null) return connect;

  return _keyedFallback(clients.dojo!, config!);
});

/// Card entry with no reader involved: the native drop-in on Android, the
/// hosted checkout on desktop. Plain REST polling is deliberately not an
/// option — it presents no card at all, which is what once left the till stuck
/// on "Waiting for the card…".
PaymentProvider _keyedFallback(DojoProvider rest, DojoConfig config) {
  if (Platform.isAndroid) {
    return NativeDojoProvider(
      intents: rest,
      isSandbox: config.isSandboxKey,
      // Google Pay rides along with the drop-in: same sheet, same result code.
      // Passed unconditionally — blank values are how the SDK is told there is
      // no wallet, so there is nothing to branch on here.
      walletMerchantName: config.walletMerchantName.trim(),
      walletMerchantId: config.walletMerchantId.trim(),
      walletGatewayMerchantId: config.walletGatewayMerchantId.trim(),
    );
  }
  if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
    return DesktopDojoProvider(intents: rest);
  }
  return rest;
}

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
