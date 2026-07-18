import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/floor_repository.dart';
import '../data/local/database.dart';
import '../main.dart';
import 'placeholder_page.dart';
import 'theme.dart';
import 'widgets/basket_panel.dart' show money;

final parkedOrdersProvider = StreamProvider<List<Order>>(
  (ref) => ref.watch(tableRepositoryProvider).watchParked(),
);

/// Table plan. A table with a bill on it shows the running total; an empty one
/// is free.
class TablesPage extends ConsumerWidget {
  const TablesPage({
    super.key,
    required this.currentOrderId,
    required this.onRecall,
  });

  final String currentOrderId;

  /// Called with the recalled order so the shell can switch to it.
  final void Function(String orderId) onRecall;

  /// Matches the designer's grid unit, so a table drawn at (5,3) lands at (5,3)
  /// here.
  static const _grid = 40.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final parked = ref.watch(parkedOrdersProvider).value ?? const <Order>[];
    final byTable = {
      for (final o in parked)
        if (o.tableNumber != null) o.tableNumber!: o,
    };
    final plan = ref.watch(floorPlanProvider);

    return Padding(
      padding: const EdgeInsets.all(16),
      child: plan.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) =>
            Center(child: Text('Could not load the floor plan.\n$e')),
        data: (rooms) {
          final withTables = rooms.where((r) => r.tables.isNotEmpty).toList();

          // No plan drawn yet: say so, rather than showing an invented grid of
          // tables that do not exist in the venue.
          if (withTables.isEmpty) {
            return const PlaceholderPage(
              title: 'Tables',
              icon: Icons.grid_view,
              description:
                  'No floor plan has been drawn yet. Lay out your rooms and '
                  'tables in the back office and they will appear here.',
              points: [
                'Drag tables into position on a room plan',
                'Set seats, size and shape per table',
                'Occupied tables show their running total',
              ],
            );
          }

          return DefaultTabController(
            length: withTables.length,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text(
                      'Tables',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: 'Refresh plan',
                      icon: const Icon(Icons.refresh),
                      onPressed: () => ref.invalidate(floorPlanProvider),
                    ),
                  ],
                ),
                if (withTables.length > 1)
                  TabBar(
                    isScrollable: true,
                    tabAlignment: TabAlignment.start,
                    tabs: [for (final room in withTables) Tab(text: room.name)],
                  ),
                Expanded(
                  child: TabBarView(
                    children: [
                      for (final room in withTables)
                        _RoomPlan(
                          room: room,
                          byTable: byTable,
                          onTap: (number, order) =>
                              _onTap(context, ref, number, order),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _onTap(
    BuildContext context,
    WidgetRef ref,
    int number,
    Order? order,
  ) async {
    final tables = ref.read(tableRepositoryProvider);

    if (order == null) {
      // Empty table: park the sale currently on the till against it.
      final lines = await ref
          .read(orderRepositoryProvider)
          .watchLines(currentOrderId)
          .first;
      if (lines.isEmpty) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Ring up some items first.')),
        );
        return;
      }
      await tables.park(currentOrderId, number);
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Saved to table $number.')));
      return;
    }

    if (!context.mounted) return;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                'Table $number — ${money(order.totalMinor)}',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.open_in_new),
              title: const Text('Recall to till'),
              onTap: () => Navigator.pop(context, 'recall'),
            ),
            ListTile(
              leading: const Icon(Icons.swap_horiz),
              title: const Text('Transfer to another table'),
              onTap: () => Navigator.pop(context, 'transfer'),
            ),
            ListTile(
              leading: const Icon(Icons.call_split),
              title: const Text('Split bill'),
              onTap: () => Navigator.pop(context, 'split'),
            ),
          ],
        ),
      ),
    );

    if (action == null || !context.mounted) return;

    switch (action) {
      case 'recall':
        // onRecall (the shell) performs the recall and switches to the bill.
        onRecall(order.id);
      case 'transfer':
        final to = await _askNumber(context, 'Transfer to table');
        if (to == null) return;
        try {
          await tables.transfer(order.id, to);
        } on StateError catch (e) {
          if (!context.mounted) return;
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(e.message)));
        }
      case 'split':
        if (!context.mounted) return;
        await _splitDialog(context, ref, order);
    }
  }

  Future<void> _splitDialog(
    BuildContext context,
    WidgetRef ref,
    Order order,
  ) async {
    final ways = await _askNumber(context, 'Split evenly how many ways?');
    if (ways == null || !context.mounted) return;

    try {
      final ids = await ref
          .read(tableRepositoryProvider)
          .splitEvenly(order.id, ways);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Split into ${ids.length} bills.')),
      );
    } on ArgumentError catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('${e.message}')));
    }
  }

  Future<int?> _askNumber(BuildContext context, String title) {
    final controller = TextEditingController();
    return showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, int.tryParse(controller.text.trim())),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }
}

/// Renders one room exactly as it was laid out in the back office. The plan
/// scales to fit the terminal, so the same layout reads correctly on a phone,
/// a tablet and a desktop till.
class _RoomPlan extends StatelessWidget {
  const _RoomPlan({
    required this.room,
    required this.byTable,
    required this.onTap,
  });

  final FloorRoom room;
  final Map<int, Order> byTable;
  final void Function(int number, Order? order) onTap;

  @override
  Widget build(BuildContext context) {
    // How far the plan extends, so it can be scaled to the space available.
    var maxX = 1;
    var maxY = 1;
    for (final t in room.tables) {
      maxX = t.x + t.width > maxX ? t.x + t.width : maxX;
      maxY = t.y + t.height > maxY ? t.y + t.height : maxY;
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        const grid = TablesPage._grid;

        // Fit the plan on both axes so a wide or tall room never runs off the
        // edge and hides its last tables. Height can be unbounded (inside a
        // scroll view); when it is, fall back to fitting on width alone.
        final availW = constraints.maxWidth;
        final availH = constraints.maxHeight;
        final scaleW = availW / (maxX * grid);
        final hasBoundedHeight = availH.isFinite;
        final scaleH = hasBoundedHeight ? availH / (maxY * grid) : scaleW;
        final scale = (scaleW < scaleH ? scaleW : scaleH)
            .clamp(0.3, 1.6)
            .toDouble();
        final unit = grid * scale;

        final planW = maxX * unit;
        final planH = maxY * unit;

        return SingleChildScrollView(
          scrollDirection: Axis.vertical,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: planW < availW ? availW : planW,
              height: planH + 16,
              child: Stack(
                children: [
                  for (final table in room.tables)
                    Positioned(
                      left: table.x * unit,
                      top: table.y * unit,
                      width: table.width * unit - 6,
                      height: table.height * unit - 6,
                      child: _TableShape(
                        table: table,
                        order: byTable[table.number],
                        onTap: () => onTap(table.number, byTable[table.number]),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _TableShape extends StatelessWidget {
  const _TableShape({
    required this.table,
    required this.order,
    required this.onTap,
  });

  final FloorTable table;
  final Order? order;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final occupied = order != null;
    final radius = table.isCircle
        ? BorderRadius.circular(400)
        : BorderRadius.circular(8);

    return Material(
      // An idle table used a fixed light-grey even in dark mode, so its
      // near-white number was invisible on it. Both now come from the theme.
      color: occupied ? Pos.brand : Theme.of(context).posIdle,
      borderRadius: radius,
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                table.label?.isNotEmpty == true
                    ? table.label!
                    : '${table.number}',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: occupied
                      ? Colors.white
                      : Theme.of(context).colorScheme.onSurface,
                ),
              ),
              if (occupied)
                Text(
                  money(order!.totalMinor),
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                )
              else
                Text(
                  '${table.seats} seats',
                  style: TextStyle(
                    color: Theme.of(context).hintColor,
                    fontSize: 11,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
