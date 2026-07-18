import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/session_controller.dart';
import '../data/sync_service.dart';
import '../main.dart';
import 'layout.dart';
import 'about_page.dart';
import 'functions_page.dart';
import 'logout_dialog.dart';
import 'placeholder_page.dart';
import 'products_page.dart';
import 'settings_page.dart';
import 'receipts_page.dart';
import 'reports_page.dart';
import 'sale_page.dart';
import 'tables_page.dart';
import 'theme.dart';
import 'widgets/nav_rail.dart';

/// The till frame: fixed nav rail on the left, the selected page beside it.
class PosShell extends ConsumerStatefulWidget {
  const PosShell({super.key});

  @override
  ConsumerState<PosShell> createState() => _PosShellState();
}

class _PosShellState extends ConsumerState<PosShell> {
  int _index = 0;
  String? _orderId;

  @override
  void initState() {
    super.initState();
    // Start syncing only once the terminal knows which venue it belongs to —
    // before sign-in there is no catalogue to pull.
    ref.read(syncServiceProvider).start();
    _newOrder();
  }

  Future<void> _newOrder() async {
    final id = await ref.read(orderRepositoryProvider).openOrder();
    if (mounted) setState(() => _orderId = id);
  }

  /// Sign out. The dialog verifies the password against the live server and
  /// refuses while this terminal still holds sales the server has never seen.
  Future<void> _logout() async {
    final done = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const LogoutDialog(),
    );

    if (done == true) {
      // Wipe this venue's cached catalogue and deals. Without this, a terminal
      // re-commissioned to another office would open showing the previous
      // office's products.
      final db = ref.read(databaseProvider);
      await db.delete(db.products).go();
      await db.delete(db.mixMatchProducts).go();
      await db.delete(db.mixMatchDeals).go();

      // Clearing the session drops the app back to the sign-in screen, which is
      // what the next person on this terminal should see.
      await ref.read(sessionControllerProvider.notifier).signOut();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Pull the venue's receipt branding down once the till is running, so the
    // first receipt of the day already carries the logo and footer. Watched
    // here rather than at print time: printing must read a cache, never wait
    // on the network.
    ref.watch(brandingRefreshProvider);
    ref.watch(commerceRefreshProvider);

    final orderId = _orderId;
    final body = orderId == null
        ? const Center(child: CircularProgressIndicator())
        : _page(orderId);

    // Below desktop width the left rail would eat a third of the screen, so it
    // becomes a drawer reached from the app bar instead.
    if (context.useCompactNav) {
      return Scaffold(
        appBar: AppBar(
          backgroundColor: Pos.chrome,
          foregroundColor: Colors.white,
          title: Row(
            children: [
              Icon(navDestinations[_index].icon, size: 20, color: Pos.brand),
              const SizedBox(width: 10),
              Text(navDestinations[_index].label),
            ],
          ),
          actions: const [
            Padding(
              padding: EdgeInsets.only(right: 12),
              child: Center(child: SyncStatusBadge()),
            ),
          ],
          elevation: 0,
        ),
        drawer: Drawer(
          child: SafeArea(
            child: PosNavRail(
              selected: _index,
              onSelect: (i) {
                setState(() => _index = i);
                Navigator.of(context).pop();
              },
              onLogout: () {
                Navigator.of(context).pop();
                _logout();
              },
            ),
          ),
        ),
        body: body,
      );
    }

    return Scaffold(
      body: Column(
        children: [
          const _TitleBar(),
          Expanded(
            child: Row(
              children: [
                PosNavRail(
                  selected: _index,
                  onSelect: (i) => setState(() => _index = i),
                  onLogout: _logout,
                ),
                Expanded(child: body),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Bring a parked bill onto the till and show it on the sale screen. Recalls
  /// it (flips it back to open) so it is no longer counted as a separate booked
  /// table while it is the active bill.
  Future<void> _switchToOrder(String id) async {
    await ref.read(tableRepositoryProvider).recall(id);
    if (!mounted) return;
    setState(() {
      _orderId = id;
      _index = navDestinations.indexWhere((d) => d.label == 'Sale');
    });
  }

  Widget _page(String orderId) {
    // Routed by label rather than index, so adding a nav item cannot silently
    // shift what each screen points to.
    switch (navDestinations[_index].label) {
      case 'Sale':
        return SalePage(
          orderId: orderId,
          onNewOrder: _newOrder,
          onSwitchOrder: _switchToOrder,
        );
      case 'Table':
        return TablesPage(currentOrderId: orderId, onRecall: _switchToOrder);
      case 'Receipts':
        return const ReceiptsPage();
      case 'Settings':
        return const SettingsPage();
      case 'Reports':
        return const ReportsPage();
      case 'Product':
        return const ProductsPage();
      case 'Functions':
        return FunctionsPage(
          orderId: orderId,
          onGoToReports: () => _goTo('Reports'),
          onGoToReceipts: () => _goTo('Receipts'),
          onGoToTables: () => _goTo('Table'),
        );
      default:
        return _sectionInfo(_index);
    }
  }

  /// Jump to another nav section by its label, from a button inside a page.
  void _goTo(String label) {
    final i = navDestinations.indexWhere((d) => d.label == label);
    if (i != -1) setState(() => _index = i);
  }

  /// Sections driven from the back office. Each explains what it does rather
  /// than showing an empty screen.
  Widget _sectionInfo(int index) {
    switch (navDestinations[index].label) {
      case 'Product':
        return PlaceholderPage(
          title: 'Products',
          icon: Icons.shopping_bag,
          description:
              'Your catalogue, synced from the back office and cached on this '
              'terminal so it keeps selling with no network. Tap a product on '
              'the Sale screen to add it to the bill.',
          points: const [
            'Assign products to specific buttons and colours',
            'Products with a picture show the picture on the button',
            'Set prices, VAT rates and stock levels',
            'Route items to a kitchen or bar printer',
          ],
          action: ('Go to Sale', () => _goTo('Sale')),
        );
      case 'Settings':
        return const PlaceholderPage(
          title: 'Settings',
          icon: Icons.settings,
          description: 'Printers, tax rates and terminal configuration.',
          points: [
            'Receipt printer: network (any platform) or serial (desktop only)',
            'Kitchen and bar printer routing',
            'Card terminal and tax rates',
          ],
        );
      case 'About':
        return const AboutPage();
      default:
        return PlaceholderPage(
          title: navDestinations[index].label,
          icon: navDestinations[index].icon,
          description: 'Managed from the Vesopa Back Office.',
        );
    }
  }
}

class _TitleBar extends StatelessWidget {
  const _TitleBar();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 22,
      color: Pos.chrome,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.centerLeft,
      child: const Row(
        children: [
          Icon(Icons.point_of_sale, color: Colors.white, size: 13),
          SizedBox(width: 6),
          Text(
            'VesopaEPOS',
            style: TextStyle(color: Colors.white, fontSize: 12),
          ),
          Spacer(),
          // The clerk needs to know at a glance whether the till is live with
          // the back office or working offline with a backlog to send.
          SyncStatusBadge(compact: true),
        ],
      ),
    );
  }
}

/// Online/offline + backlog indicator, driven by [syncStatusProvider].
///
/// Green when the terminal is live with the back office and nothing is queued;
/// amber while a backlog is draining; grey/red when offline. It reassures the
/// clerk that a sale rung up offline is safely queued and will sync, rather
/// than leaving them guessing whether the till is talking to the server.
class SyncStatusBadge extends ConsumerWidget {
  const SyncStatusBadge({super.key, this.compact = false});

  /// The slim variant for the desktop title bar; the app bar uses the fuller
  /// one with a label.
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Fall back to the service's current snapshot until the first stream event,
    // so the badge is never blank.
    final status =
        ref.watch(syncStatusProvider).value ??
        ref.watch(syncServiceProvider).currentStatus;

    final (color, label, icon) = switch (status) {
      SyncStatus(online: false) => (
        Pos.red,
        status.hasBacklog ? 'Offline · ${status.pending}' : 'Offline',
        Icons.cloud_off,
      ),
      SyncStatus(hasBacklog: true) => (
        Pos.amber,
        'Syncing ${status.pending}',
        Icons.cloud_sync,
      ),
      _ => (Pos.green, 'Online', Icons.cloud_done),
    };

    final foreground = compact ? Colors.white : color;

    return Tooltip(
      message: switch (status) {
        SyncStatus(online: false) when status.hasBacklog =>
          '${status.pending} sale(s) queued — will sync when back online.',
        SyncStatus(online: false) =>
          'Working offline. Sales are saved locally.',
        SyncStatus(hasBacklog: true) =>
          'Sending ${status.pending} queued sale(s) to the back office.',
        _ => 'Live with the back office. All sales synced.',
      },
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 6 : 10,
          vertical: 4,
        ),
        decoration: BoxDecoration(
          color: compact ? null : color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: compact ? 13 : 16, color: foreground),
            SizedBox(width: compact ? 5 : 7),
            Text(
              label,
              style: TextStyle(
                color: foreground,
                fontSize: compact ? 11 : 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
