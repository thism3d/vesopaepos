import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/local/database.dart';
import '../data/mix_match_engine.dart';
import '../data/order_repository.dart';
import '../main.dart';
import 'layout.dart';
import 'customer_picker.dart';
import 'payment_page.dart';
import 'table_picker.dart';
import 'tables_page.dart' show parkedOrdersProvider;
import 'theme.dart';
import 'void_dialog.dart';
import 'widgets/action_bar.dart';
import 'widgets/basket_panel.dart';
import 'widgets/line_editor.dart';

/// Live catalogue, straight from the local database so the grid renders with
/// no network at all.
final productsProvider = StreamProvider<List<Product>>((ref) {
  final db = ref.watch(databaseProvider);
  return db.select(db.products).watch();
});

/// Which department the clerk is looking at. StateProvider was removed in
/// Riverpod 3, so this is the Notifier equivalent.
class SelectedCategory extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String category) => state = category;
}

final selectedCategoryProvider = NotifierProvider<SelectedCategory, String?>(
  SelectedCategory.new,
);

/// The mix & match deals firing on this bill. Recomputed whenever the lines
/// change, so the saving appears the moment the qualifying item is rung up.
final dealsProvider = FutureProvider.family<MixMatchResult, String>((
  ref,
  orderId,
) async {
  final repo = ref.watch(orderRepositoryProvider);
  // Re-run when the basket changes.
  await ref.watch(orderLinesProvider(orderId).future);
  return repo.dealsOn(orderId);
});

final orderLinesProvider = StreamProvider.family<List<OrderLine>, String>((
  ref,
  orderId,
) {
  return ref.watch(orderRepositoryProvider).watchLines(orderId);
});

class SalePage extends ConsumerWidget {
  const SalePage({
    super.key,
    required this.orderId,
    required this.onNewOrder,
    required this.onSwitchOrder,
  });

  final String orderId;
  final VoidCallback onNewOrder;

  /// Jump to another open bill — a parked table the clerk wants to add to or
  /// settle. Runs several tables at once without losing any of them.
  final void Function(String orderId) onSwitchOrder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(orderRepositoryProvider);
    final products = ref.watch(productsProvider).value ?? const <Product>[];

    // Departments drive the right-hand rail: whatever the back office defines
    // is what the clerk sees, no hardcoded menu.
    final categories = {
      for (final p in products)
        if (p.departmentName != null && p.departmentName!.isNotEmpty)
          p.departmentName!,
    }.toList()..sort();

    final selected =
        ref.watch(selectedCategoryProvider) ??
        (categories.isNotEmpty ? categories.first : null);

    // Honour the button layout set in the back office: positioned products come
    // first, in the manager's order; anything unassigned follows alphabetically
    // rather than disappearing.
    final visible = products.where((p) => p.departmentName == selected).toList()
      ..sort((a, b) {
        final ap = a.buttonPosition;
        final bp = b.buttonPosition;
        if (ap != null && bp != null) return ap.compareTo(bp);
        if (ap != null) return -1;
        if (bp != null) return 1;
        return a.name.compareTo(b.name);
      });

    return StreamBuilder<Order>(
      stream: repo.watchOrder(orderId),
      builder: (context, orderSnap) {
        return StreamBuilder<List<OrderLine>>(
          stream: repo.watchLines(orderId),
          builder: (context, linesSnap) {
            final order = orderSnap.data;
            final lines = linesSnap.data ?? const <OrderLine>[];
            final total = order?.totalMinor ?? 0;

            final grid = _ProductGrid(
              products: visible,
              color: Pos.categoryColor(selected ?? ''),
              onTap: (p) => repo.addLine(orderId, p),
            );

            void selectCategory(String c) =>
                ref.read(selectedCategoryProvider.notifier).select(c);

            return Column(
              children: [
                // Switch between concurrent bills: every booked table plus this
                // one, so several parties can be served at once.
                _OpenOrdersBar(
                  currentOrderId: orderId,
                  currentOrder: order,
                  onSwitch: onSwitchOrder,
                  onNew: onNewOrder,
                ),
                Expanded(
                  child: context.isPhone
                      // One thing at a time: categories as a scrolling strip,
                      // the grid below, and the bill behind a pull-up sheet.
                      ? Column(
                          children: [
                            _CategoryStrip(
                              categories: categories,
                              selected: selected,
                              onSelect: selectCategory,
                            ),
                            Expanded(child: grid),
                            _BasketBar(
                              order: order,
                              lineCount: lines.length,
                              onTap: () => _showBasketSheet(
                                context,
                                ref: ref,
                                orderId: orderId,
                                repo: repo,
                              ),
                            ),
                          ],
                        )
                      : Row(
                          children: [
                            BasketPanel(
                              lines: lines,
                              order: order,
                              // Named deals, so the customer can see why the
                              // total dropped.
                              deals:
                                  ref.watch(dealsProvider(orderId)).value ??
                                  MixMatchResult.none,
                              onTapLine: (l) => showLineEditor(
                                context,
                                ref,
                                orderId: orderId,
                                line: l,
                              ),
                              onRemoveLine: (l) =>
                                  repo.removeLine(orderId, l.id),
                            ),
                            Expanded(child: grid),
                            _CategoryRail(
                              categories: categories,
                              selected: selected,
                              onSelect: selectCategory,
                            ),
                          ],
                        ),
                ),
                PosActionBar(
                  primaryLabel: 'PAY',
                  primaryIcon: Icons.credit_card,
                  onPrimary: total == 0
                      ? null
                      : () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => PaymentPage(
                              orderId: orderId,
                              onSettled: onNewOrder,
                            ),
                          ),
                        ),
                  actions: [
                    // Void is red and stays on the bar even on a phone: it is
                    // the one destructive key a clerk needs at a moment's
                    // notice.
                    PosAction(
                      label: 'Void',
                      icon: Icons.block,
                      color: Pos.red,
                      onTap: () async {
                        // Nothing on the bill: clear silently, no reason needed.
                        if (lines.isEmpty) {
                          await repo.voidOrder(orderId, reason: 'Empty');
                          onNewOrder();
                          return;
                        }
                        final reason = await showVoidDialog(context, ref);
                        if (reason == null) return;
                        await repo.voidOrder(orderId, reason: reason);
                        // A void queues an audit record — push it now rather
                        // than waiting for the periodic flush, so the back
                        // office sees the reversal in real time when online.
                        unawaited(ref.read(syncServiceProvider).flush());
                        onNewOrder();
                      },
                    ),
                    PosAction(
                      label: 'Save Table',
                      icon: Icons.table_restaurant,
                      onTap: () => _promptTable(context, ref),
                    ),
                    PosAction(
                      label: 'Covers',
                      icon: Icons.people,
                      onTap: () => _promptCovers(context, ref),
                    ),
                    PosAction(
                      label: 'Customer',
                      icon: Icons.person,
                      onTap: () => _promptCustomer(context, ref),
                    ),
                    PosAction(
                      label: 'Discount',
                      icon: Icons.percent,
                      onTap: () => _promptDiscount(context, ref),
                    ),
                    PosAction(
                      label: 'Notes',
                      icon: Icons.edit_note,
                      onTap: () => _promptNotes(context, ref),
                    ),
                    PosAction(
                      label: 'No Sale',
                      icon: Icons.point_of_sale,
                      onTap: () => _todo(context, 'Opening the cash drawer'),
                    ),
                    PosAction(
                      label: 'Print',
                      icon: Icons.print,
                      onTap: () => _todo(context, 'Receipt printing'),
                    ),
                    PosAction(
                      label: 'Last Bill',
                      icon: Icons.receipt_long,
                      onTap: () => _todo(context, 'Reprinting the last bill'),
                    ),
                  ],
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _promptTable(BuildContext context, WidgetRef ref) async {
    // Visual picker off the real floor plan — free tables are tappable, booked
    // ones show their bill and are blocked — instead of typing a number blind.
    final value = await showTablePicker(context, ref);
    if (value == null) return;

    // Park the current bill against the table and clear the till for the next
    // customer. Parking keeps the order live (it is not takings until settled)
    // and frees the sale screen so several tables can run at once; the clerk
    // hops back to any of them from the open-orders bar or the tables plan.
    await ref.read(tableRepositoryProvider).park(orderId, value);
    onNewOrder();
  }

  Future<void> _promptCovers(BuildContext context, WidgetRef ref) async {
    final value = await _numberDialog(context, 'Covers');
    if (value != null) {
      await ref.read(orderRepositoryProvider).setCovers(orderId, value);
    }
  }

  Future<void> _promptCustomer(BuildContext context, WidgetRef ref) async {
    final customer = await pickCustomer(context, ref);
    if (customer == null) return;
    await ref
        .read(orderRepositoryProvider)
        .attachCustomer(
          orderId,
          id: customer.id,
          name: customer.name,
          discountType: customer.discountType,
          discountValue: customer.discountValue,
        );
    if (context.mounted && customer.hasDiscount) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${customer.name} attached — ${customer.discountLabel} applied.',
          ),
        ),
      );
    }
  }

  Future<void> _promptDiscount(BuildContext context, WidgetRef ref) async {
    final pounds = await _textDialog(context, 'Discount (£)');
    if (pounds == null) return;
    final value = double.tryParse(pounds);
    if (value == null) return;
    await ref
        .read(orderRepositoryProvider)
        .applyDiscount(orderId, (value * 100).round());
  }

  Future<void> _promptNotes(BuildContext context, WidgetRef ref) async {
    final value = await _textDialog(context, 'Order notes');
    if (value != null) {
      await ref.read(orderRepositoryProvider).setNotes(orderId, value);
    }
  }

  void _todo(BuildContext context, String what) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('$what is not wired up yet.')));
  }
}

Future<int?> _numberDialog(BuildContext context, String title) async {
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

Future<String?> _textDialog(BuildContext context, String title) async {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(controller: controller, autofocus: true),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text.trim()),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

class _ProductGrid extends StatelessWidget {
  const _ProductGrid({
    required this.products,
    required this.color,
    required this.onTap,
  });

  final List<Product> products;
  final Color color;
  final void Function(Product) onTap;

  @override
  Widget build(BuildContext context) {
    if (products.isEmpty) {
      return const Center(child: Text('No products in this category.'));
    }

    // Two columns on a phone, three on a wider screen. The tiles stay tall
    // enough to be a comfortable thumb target rather than the wide, shallow
    // buttons that suit a desk-mounted till.
    final phone = context.isPhone;

    // Media tiles are near-square to give the image/emoji room; a plain text
    // menu keeps the wide, shallow buttons.
    final ratio = _hasMedia ? (phone ? 1.0 : 1.3) : (phone ? 1.6 : 3.1);

    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: phone ? 2 : 3,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: ratio,
      ),
      itemCount: products.length,
      itemBuilder: (context, i) => _ProductTile(
        product: products[i],
        color: Pos.parseColor(products[i].buttonColor) ?? color,
        showPrice: phone || _hasMedia,
        onTap: () => onTap(products[i]),
      ),
    );
  }

  /// When any product carries an image or emoji, the whole grid switches to
  /// taller media tiles so the visuals have room — a menu of pictures should
  /// not sit in wide, shallow buttons.
  bool get _hasMedia => products.any(
    (p) => (p.imageUrl?.isNotEmpty ?? false) || (p.emoji?.isNotEmpty ?? false),
  );
}

class _ProductTile extends StatelessWidget {
  const _ProductTile({
    required this.product,
    required this.color,
    required this.showPrice,
    required this.onTap,
  });

  final Product product;
  final Color color;
  final bool showPrice;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hasImage = product.imageUrl?.isNotEmpty ?? false;
    final hasEmoji = product.emoji?.isNotEmpty ?? false;

    // A product with a picture shows the picture ALONE — no name, no price
    // overlaid. The image was cropped square in the back office for exactly
    // this, and the clerk recognises the item by sight. Emoji and plain-text
    // products keep their label and price.
    if (hasImage) {
      return Material(
        color: color,
        borderRadius: BorderRadius.circular(6),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Image.network(
            product.imageUrl!,
            fit: BoxFit.cover,
            // A broken image URL falls back to the name on the coloured tile,
            // so the button is still usable rather than blank.
            errorBuilder: (_, _, _) => _LabelTile(
              name: product.name,
              priceMinor: showPrice ? product.priceMinor : null,
            ),
          ),
        ),
      );
    }

    return Material(
      color: color,
      borderRadius: BorderRadius.circular(6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Only reserve space for the emoji when there is one — a plain
              // text button has no media slot, so the name and price sit
              // centred with no dead space above them.
              if (hasEmoji) ...[
                Text(product.emoji!, style: const TextStyle(fontSize: 30)),
                const SizedBox(height: 4),
              ],
              Text(
                product.name,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (showPrice)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    money(product.priceMinor),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The label+price shown on a coloured tile, used as the fallback when a
/// product's image fails to load.
class _LabelTile extends StatelessWidget {
  const _LabelTile({required this.name, this.priceMinor});

  final String name;
  final int? priceMinor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            name,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (priceMinor != null)
            Text(
              money(priceMinor!),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
        ],
      ),
    );
  }
}

/// A strip of every bill currently in play — this one plus each booked table —
/// so the clerk can serve several parties at once and hop between their bills
/// without losing any. Updates live as tables are booked and settled.
class _OpenOrdersBar extends ConsumerWidget {
  const _OpenOrdersBar({
    required this.currentOrderId,
    required this.currentOrder,
    required this.onSwitch,
    required this.onNew,
  });

  final String currentOrderId;
  final Order? currentOrder;
  final void Function(String orderId) onSwitch;
  final VoidCallback onNew;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final booked = ref.watch(parkedOrdersProvider).value ?? const <Order>[];

    // The current bill is shown first when it is not itself one of the booked
    // tables (i.e. a fresh walk-in, or a table just recalled onto the till).
    final currentIsBooked = booked.any((o) => o.id == currentOrderId);

    // Nothing else on the go and this bill is a plain walk-in: the bar would
    // just say "Current" on its own, so keep it out of the way.
    if (booked.isEmpty && !currentIsBooked) return const SizedBox.shrink();

    return Container(
      height: 52,
      color: Theme.of(context).posSurface,
      child: Row(
        children: [
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              children: [
                if (!currentIsBooked)
                  _OrderChip(
                    label: currentOrder?.tableNumber != null
                        ? 'Table ${currentOrder!.tableNumber}'
                        : 'Current',
                    total: currentOrder?.totalMinor ?? 0,
                    active: true,
                    onTap: () {},
                  ),
                for (final o in booked)
                  _OrderChip(
                    label: 'Table ${o.tableNumber}',
                    total: o.totalMinor,
                    active: o.id == currentOrderId,
                    onTap: () => onSwitch(o.id),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextButton.icon(
              onPressed: onNew,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('New'),
            ),
          ),
        ],
      ),
    );
  }
}

class _OrderChip extends StatelessWidget {
  const _OrderChip({
    required this.label,
    required this.total,
    required this.active,
    required this.onTap,
  });

  final String label;
  final int total;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: active ? Pos.brand : Theme.of(context).posIdle,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: active ? null : onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: active
                        ? Colors.white
                        : Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  money(total),
                  style: TextStyle(
                    fontSize: 13,
                    color: active
                        ? Colors.white70
                        : Theme.of(context).hintColor,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Phone: the bill lives behind this bar rather than taking a column. It always
/// shows the total, because that is the one number the clerk must never lose
/// sight of.
class _BasketBar extends StatelessWidget {
  const _BasketBar({
    required this.order,
    required this.lineCount,
    required this.onTap,
  });

  final Order? order;
  final int lineCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).posTotals,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: Theme.of(context).posLine)),
          ),
          child: Row(
            children: [
              const Icon(Icons.expand_less),
              const SizedBox(width: 8),
              Text(
                lineCount == 1 ? '1 item' : '$lineCount items',
                style: const TextStyle(fontSize: 15),
              ),
              const Spacer(),
              Text(
                money(order?.totalMinor ?? 0),
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Phone: departments scroll horizontally instead of occupying a rail.
class _CategoryStrip extends StatelessWidget {
  const _CategoryStrip({
    required this.categories,
    required this.selected,
    required this.onSelect,
  });

  final List<String> categories;
  final String? selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 52,
      // An explicit surface so the strip reads as a bar in both themes rather
      // than blending into whatever is behind it.
      color: Theme.of(context).posSurface,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: categories.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final category = categories[i];
          final active = category == selected;
          final color = Pos.categoryColor(category);

          return Material(
            // Idle chip reads from the theme, so it does not stay light-grey
            // (with pale text on it) in dark mode.
            color: active ? color : Theme.of(context).posIdle,
            borderRadius: BorderRadius.circular(18),
            child: InkWell(
              borderRadius: BorderRadius.circular(18),
              onTap: () => onSelect(category),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Center(
                  child: Text(
                    category,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: active
                          ? Colors.white
                          : Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// The full bill, as a sheet. Long-press a line to remove it, same as the
/// desktop basket.
Future<void> _showBasketSheet(
  BuildContext context, {
  required WidgetRef ref,
  required String orderId,
  required OrderRepository repo,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      builder: (context, controller) => StreamBuilder<Order>(
        stream: repo.watchOrder(orderId),
        builder: (context, orderSnap) => StreamBuilder<List<OrderLine>>(
          stream: repo.watchLines(orderId),
          builder: (context, linesSnap) {
            final lines = linesSnap.data ?? const <OrderLine>[];
            final order = orderSnap.data;

            return Column(
              children: [
                const SizedBox(height: 8),
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Theme.of(context).dividerColor,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Expanded(
                  child: lines.isEmpty
                      ? const Center(child: Text('No items'))
                      : ListView.builder(
                          controller: controller,
                          itemCount: lines.length,
                          itemBuilder: (context, i) {
                            final line = lines[i];
                            final total =
                                (line.unitPriceMinor * line.quantity).round() -
                                line.lineDiscountMinor;
                            final extras = [
                              if (line.lineDiscountMinor > 0)
                                '-${money(line.lineDiscountMinor)}',
                              if (line.notes?.isNotEmpty ?? false) line.notes!,
                            ].join('  •  ');

                            return ListTile(
                              title: Text(line.name),
                              subtitle: Text(
                                '${line.quantity.toStringAsFixed(line.quantity % 1 == 0 ? 0 : 2)} × '
                                '${money(line.unitPriceMinor)}'
                                '${extras.isEmpty ? '' : '\n$extras'}',
                              ),
                              isThreeLine: extras.isNotEmpty,
                              trailing: Text(
                                money(total),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              // Tap the line to edit it — quantity, discount,
                              // note, remove.
                              onTap: () => showLineEditor(
                                context,
                                ref,
                                orderId: orderId,
                                line: line,
                              ),
                            );
                          },
                        ),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Total',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        money(order?.totalMinor ?? 0),
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    ),
  );
}

class _CategoryRail extends StatelessWidget {
  const _CategoryRail({
    required this.categories,
    required this.selected,
    required this.onSelect,
  });

  final List<String> categories;
  final String? selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    // Proportional, for the same reason as the basket: a fixed width overflows
    // the row on a smaller tablet.
    final width = MediaQuery.sizeOf(context).width.clamp(600.0, 1600.0) * 0.22;

    return Container(
      width: width,
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: Theme.of(context).posLine)),
      ),
      child: ListView.builder(
        itemCount: categories.length,
        itemBuilder: (context, i) {
          final category = categories[i];
          final active = category == selected;
          return Material(
            // The active category takes its own colour, matching the grid, so
            // the two panels are visibly linked.
            color: active ? Pos.categoryColor(category) : Colors.transparent,
            child: InkWell(
              onTap: () => onSelect(category),
              child: Container(
                height: 48,
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  category,
                  style: TextStyle(
                    fontSize: 16,
                    color: active
                        ? Colors.white
                        : Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
