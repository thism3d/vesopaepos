import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:drift/drift.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'local/database.dart';

/// A snapshot of the terminal's link to the back office, for the till's
/// online/offline badge.
class SyncStatus {
  const SyncStatus({required this.online, required this.pending});

  /// True when the last push to the server succeeded — the terminal is live.
  final bool online;

  /// How many sales are still queued in the outbox, waiting to reach the
  /// server. Non-zero while offline, or briefly during a flush.
  final int pending;

  bool get hasBacklog => pending > 0;
}

/// Drains the outbox to the server and receives live updates from it.
///
/// Sending uses plain HTTP, deliberately. A till must be able to record a sale
/// with no network at all, so the send path has to be something that can fail,
/// be retried later, and survive the process being killed mid-flight. A socket
/// is a live connection — when it drops, in-flight frames are simply lost, and
/// there is no connection to speak of on an offline terminal. The outbox plus
/// an idempotent POST gives us at-least-once delivery that the order id then
/// de-duplicates server side.
///
/// The socket is used for the thing it is actually good at: the server pushing
/// to us — kitchen tickets, table status changing on another terminal, price
/// updates from the back office.
class SyncService {
  SyncService(
    this._db, {
    required this.apiBase,
    required this.wsUrl,
    required this.office,
  });

  final AppDatabase _db;
  final String apiBase;
  final String wsUrl;

  /// Which venue this terminal belongs to. The server keys the catalogue and
  /// the sales by it, so without it a till would be handed every business's
  /// products.
  final String office;

  WebSocketChannel? _channel;
  StreamSubscription<void>? _connectivitySub;
  Timer? _retryTimer;

  /// Whether the terminal currently has a live link to the back office: the
  /// socket is up and the last flush succeeded. Drives the online/offline badge
  /// on the till. Broadcast so the UI can listen without owning the service.
  final _status = StreamController<SyncStatus>.broadcast();
  Stream<SyncStatus> get status => _status.stream;
  var _online = false;
  var _pending = 0;

  /// The last status seen, for a listener that subscribes after start().
  SyncStatus get currentStatus =>
      SyncStatus(online: _online, pending: _pending);

  void _emit() {
    if (_status.isClosed) return;
    _status.add(currentStatus);
  }

  void start() {
    // The network coming back is the moment to catch the terminal up: drain the
    // backlog to the server AND re-pull the catalogue and deals, since the back
    // office may have changed prices or promotions while we were offline and
    // those changes are only pushed over the socket to terminals that were
    // connected at the time. Then bring the socket back for live updates.
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      if (!results.contains(ConnectivityResult.none)) {
        unawaited(resync());
      } else {
        _online = false;
        _emit();
      }
    });

    _retryTimer = Timer.periodic(const Duration(seconds: 30), (_) => flush());
    _connectWebSocket();
    unawaited(resync());
  }

  /// Full catch-up with the back office: push everything queued, then pull the
  /// latest catalogue and deals. Runs on startup and on every reconnect, so a
  /// spell offline never leaves the till selling from a stale price list.
  Future<void> resync() async {
    _connectWebSocket();
    await flush();
    await pullCatalogue();
    await pullDeals();
  }

  /// True while a flush is in flight, so the periodic timer, a reconnect and a
  /// per-action push cannot run the outbox concurrently and double-post.
  bool _flushing = false;

  /// Push every queued mutation. Safe to call at any time, including with no
  /// network: failures leave the entry in place to be retried. Overlapping
  /// calls collapse into the one in-flight run.
  Future<void> flush() async {
    if (_flushing) return;
    _flushing = true;
    try {
      await _drain();
    } finally {
      _flushing = false;
    }
  }

  Future<void> _drain() async {
    final entries = await (_db.select(
      _db.outboxEntries,
    )..orderBy([(e) => OrderingTerm(expression: e.createdAt)])).get();

    // Surface the backlog before we start, so the badge shows the queue even if
    // the server is unreachable and every post below fails.
    _pending = entries.length;
    _emit();

    // A run with nothing to send that reaches this point is still evidence the
    // link works; but only a real 2xx proves it, so leave `_online` to the loop.
    var delivered = false;

    for (final entry in entries) {
      try {
        // Each kind of queued mutation has its own endpoint. Namespaced under
        // /till so the back office can own /orders and /products as browser
        // routes.
        final path = switch (entry.entity) {
          'void' => '/till/voids',
          _ => '/till/orders',
        };

        final res = await http
            .post(
              Uri.parse('$apiBase$path'),
              headers: {
                'Content-Type': 'application/json',
                // Lets the server discard a duplicate if our retry crossed with
                // its response, so a flaky link cannot double-book a sale.
                'Idempotency-Key': entry.entityId,
              },
              // Stamp the venue on the way out: the server keys everything by
              // it, and a paused office is refused on this field.
              body: jsonEncode({
                ...jsonDecode(entry.payload) as Map<String, dynamic>,
                'email': office,
                'office': office,
              }),
            )
            .timeout(const Duration(seconds: 10));

        // 2xx means accepted; 409 means the server already has it, which for an
        // idempotent push is success, not failure.
        if (res.statusCode >= 200 && res.statusCode < 300 ||
            res.statusCode == 409) {
          await _db.transaction(() async {
            await (_db.delete(
              _db.outboxEntries,
            )..where((e) => e.id.equals(entry.id))).go();
            await (_db.update(_db.orders)
                  ..where((o) => o.id.equals(entry.entityId)))
                .write(OrdersCompanion(syncedAt: Value(DateTime.now())));
          });
          // A real acknowledgement from the server: the link is live, and the
          // backlog just shrank by one. Emit as we go so the badge counts down.
          delivered = true;
          _online = true;
          _pending = _pending > 0 ? _pending - 1 : 0;
          _emit();
        } else {
          await _recordFailure(entry, 'HTTP ${res.statusCode}');
        }
      } catch (e) {
        // Offline or the server is down: keep the entry and try again later,
        // and mark the terminal offline so the badge reflects it.
        _online = false;
        _emit();
        await _recordFailure(entry, e.toString());
      }
    }

    // An empty queue that drained without error still means we are connected —
    // the socket keeps that current, but a clean flush is the clearest signal.
    if (entries.isEmpty && _channel != null) {
      _online = true;
    }
    if (delivered || entries.isEmpty) _emit();
  }

  Future<void> _recordFailure(OutboxEntry entry, String error) async {
    await (_db.update(
      _db.outboxEntries,
    )..where((e) => e.id.equals(entry.id))).write(
      OutboxEntriesCompanion(
        attempts: Value(entry.attempts + 1),
        lastError: Value(error),
      ),
    );
  }

  /// Server -> terminal push. Reconnects on drop; the till keeps working
  /// regardless of whether this is up.
  void _connectWebSocket() {
    if (_channel != null) return;
    try {
      final channel = WebSocketChannel.connect(Uri.parse(wsUrl));
      _channel = channel;
      channel.stream.listen(
        _onServerMessage,
        onDone: _resetSocket,
        onError: (_) => _resetSocket(),
      );
    } catch (_) {
      _resetSocket();
    }
  }

  void _resetSocket() {
    _channel = null;
    // The live link just dropped. Show offline immediately rather than waiting
    // for a queued push to fail — the connectivity listener and the periodic
    // timer will bring us back and flip the badge when the server answers again.
    _online = false;
    _emit();
  }

  Future<void> _onServerMessage(dynamic raw) async {
    final msg = jsonDecode(raw as String) as Map<String, dynamic>;
    final type = msg['type'] as String?;
    switch (type) {
      case 'catalogue.updated':
        await pullCatalogue();
      case 'programming.updated':
        // Deals, tax and finalise keys all live here.
        await pullDeals();
    }
    // Re-broadcast the event so providers that aren't DB-backed (the floor
    // plan, chiefly) can refresh themselves when the back office changes.
    if (type != null && !_events.isClosed) _events.add(type);
  }

  /// Server-push event types, for UI that needs to refresh on a back-office
  /// change but isn't fed by a database stream. Broadcast so many listeners can
  /// subscribe.
  final _events = StreamController<String>.broadcast();
  Stream<String> get events => _events.stream;

  /// Refresh the local product cache. Runs on startup and whenever the back
  /// office signals a change, so the till always has a sellable catalogue even
  /// if it is later cut off from the network.
  Future<void> pullCatalogue() async {
    final res = await http.get(
      Uri.parse('$apiBase/till/products?office=${Uri.encodeComponent(office)}'),
    );
    if (res.statusCode != 200) return;

    final items = jsonDecode(res.body) as List<dynamic>;
    await _db.batch((b) {
      b.insertAllOnConflictUpdate(_db.products, [
        for (final raw in items.cast<Map<String, dynamic>>())
          ProductsCompanion.insert(
            pluId: Value(raw['pluid'] as int),
            name: (raw['product_name'] ?? '') as String,
            departmentName: Value(raw['department_name'] as String?),
            groupName: Value(raw['group_name'] as String?),
            accountingCode: Value(raw['accounting_code'] as String?),
            // The server stores price as a float; convert to pence once, here,
            // so no rounding drift can reach the money maths.
            priceMinor: ((raw['price'] as num? ?? 0) * 100).round(),
            taxPercentage: Value(
              (raw['tax_percentage'] as num? ?? 0).toDouble(),
            ),
            stockQuantity: Value(
              (raw['stock_quantity'] as num? ?? 0).toDouble(),
            ),
            // Set in the back office: where the product sits on the till grid
            // and which kitchen printer it routes to.
            buttonPosition: Value(raw['button_position'] as int?),
            buttonColor: Value(raw['button_color'] as String?),
            printerRoute: Value(raw['printer_route'] as String?),
            emoji: Value(raw['emoji'] as String?),
            // Uploaded images are served relative to the server; store the
            // absolute URL so the till can load it directly.
            imageUrl: Value(_absoluteUrl(raw['image_url'] as String?)),
          ),
      ]);
    });
  }

  /// Turn a server-relative image path into an absolute URL the till can load.
  String? _absoluteUrl(String? path) {
    if (path == null || path.isEmpty) return null;
    if (path.startsWith('http')) return path;
    return '$apiBase$path';
  }

  /// Cache the back office's deals so they still apply when the network is
  /// down — a promotion that silently stops working offline would overcharge
  /// the customer.
  Future<void> pullDeals() async {
    final res = await http.get(
      Uri.parse('$apiBase/till/deals?office=${Uri.encodeComponent(office)}'),
    );
    if (res.statusCode != 200) return;

    final deals = (jsonDecode(res.body) as List<dynamic>)
        .cast<Map<String, dynamic>>();

    await _db.transaction(() async {
      // Replace wholesale: a deal withdrawn in the back office must stop
      // firing here, and a stale row would keep discounting.
      await _db.delete(_db.mixMatchProducts).go();
      await _db.delete(_db.mixMatchDeals).go();

      for (final deal in deals) {
        final id = deal['id'] as int;
        await _db
            .into(_db.mixMatchDeals)
            .insert(
              MixMatchDealsCompanion.insert(
                id: Value(id),
                name: (deal['name'] ?? '') as String,
                triggerQty: Value(deal['trigger_qty'] as int? ?? 2),
                dealPriceMinor: deal['deal_price_minor'] as int? ?? 0,
              ),
            );

        for (final plu
            in (deal['plu_ids'] as List<dynamic>? ?? []).cast<int>()) {
          await _db
              .into(_db.mixMatchProducts)
              .insert(MixMatchProductsCompanion.insert(dealId: id, pluId: plu));
        }
      }
    });
  }

  void dispose() {
    _retryTimer?.cancel();
    _connectivitySub?.cancel();
    _channel?.sink.close();
    _status.close();
    _events.close();
  }
}
