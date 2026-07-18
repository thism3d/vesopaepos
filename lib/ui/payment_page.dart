import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:printing/printing.dart';

import '../data/local/database.dart';
import '../data/receipt_repository.dart';
import '../main.dart';
import '../payments/dojo_desktop.dart';
import '../payments/payment_provider.dart';
import 'layout.dart';
import 'receipt_pdf.dart';
import 'receipts_page.dart' show receiptListProvider;
import 'theme.dart';
import 'widgets/basket_panel.dart';

/// Tender screen. Everything here writes locally and settles immediately —
/// taking money must never wait on the network.
class PaymentPage extends ConsumerStatefulWidget {
  const PaymentPage({
    super.key,
    required this.orderId,
    required this.onSettled,
  });

  final String orderId;
  final VoidCallback onSettled;

  @override
  ConsumerState<PaymentPage> createState() => _PaymentPageState();
}

class _PaymentPageState extends ConsumerState<PaymentPage> {
  /// What the clerk has keyed in, in minor units. Null means "no override", in
  /// which case a tender settles the whole outstanding balance.
  String _entry = '';

  int? get _keyedMinor {
    if (_entry.isEmpty) return null;
    final value = double.tryParse(_entry);
    if (value == null) return null;
    return (value * 100).round();
  }

  void _key(String k) {
    setState(() {
      if (k == 'CL') {
        _entry = '';
      } else if (k == '.' && _entry.contains('.')) {
        return;
      } else {
        _entry += k;
      }
    });
  }

  Future<void> _settle(String method, int outstanding, {int? amount}) async {
    final take = amount ?? _keyedMinor ?? outstanding;
    if (take <= 0) return;

    // A card payment has to be approved by Dojo before it counts. Cash does
    // not — the clerk is holding it.
    if (method == 'card') {
      final approved = await _takeCard(take);
      if (!approved) return;
    }

    final repo = ref.read(orderRepositoryProvider);

    // Stamp the trading period the money falls into, or the Z report will not
    // see this sale at all.
    final session = await ref.read(sessionRepositoryProvider).current();
    await repo.settle(widget.orderId, method, take, sessionId: session.id);

    final order = await repo.watchOrder(widget.orderId).first;
    final paid = await repo.amountPaid(widget.orderId);
    final remaining = order.totalMinor - paid;

    if (!mounted) return;

    if (remaining <= 0) {
      // Fully paid. Push the closed sale to the server straight away rather
      // than waiting for the periodic flush, then invalidate the receipt list
      // so the new receipt appears in history on its own — no manual refresh.
      unawaited(_publishReceipt());

      // Offer the receipt now — printing is only meaningful once the money is
      // in.
      await _offerReceipt();
      if (!mounted) return;
      widget.onSettled();
      Navigator.of(context).pop();
    } else {
      // Split tender: stay put and let the clerk take the rest.
      setState(() => _entry = '');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${money(remaining)} still to pay')),
      );
    }
  }

  /// Get the just-closed sale onto the server and refresh the history, so the
  /// receipt shows up in the Receipts screen the moment it is paid instead of
  /// only after a manual refresh.
  ///
  /// The list is server-backed, so the sale has to reach the server first: we
  /// flush the outbox now rather than waiting for the periodic sync, then
  /// invalidate the list once that push has been attempted. If the till is
  /// offline the flush is a no-op and the sale stays queued — the receipt then
  /// appears when connectivity returns and the next flush lands, which is the
  /// best history can do without the network.
  ///
  /// The service and the container are read up front, before the page pops:
  /// this runs unawaited and the flush is slow, so by the time it finishes this
  /// State can be disposed — going through the root container rather than the
  /// widget's `ref` keeps the invalidation valid regardless.
  Future<void> _publishReceipt() async {
    final container = ProviderScope.containerOf(context, listen: false);
    await container.read(syncServiceProvider).flush();
    container.invalidate(receiptListProvider);
  }

  /// After payment, offer to print the receipt. Built from the just-settled
  /// local order, so it works even if the sale has not yet synced to the
  /// server — the customer gets their receipt regardless of the network.
  Future<void> _offerReceipt() async {
    final print = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.check_circle, color: Pos.green),
            SizedBox(width: 12),
            Text('Paid'),
          ],
        ),
        content: const Text('Print a receipt?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('No receipt'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.print),
            label: const Text('Print'),
          ),
        ],
      ),
    );

    if (print != true) return;

    final repo = ref.read(orderRepositoryProvider);
    final order = await repo.watchOrder(widget.orderId).first;
    final lines = await repo.watchLines(widget.orderId).first;
    final tenders = await repo.paymentsFor(widget.orderId);

    final detail = ReceiptDetail(
      summary: ReceiptSummary(
        id: order.id,
        totalMinor: order.totalMinor,
        taxMinor: order.taxMinor,
        discountMinor: order.discountMinor,
        tableNumber: order.tableNumber,
        closedAt: order.closedAt ?? DateTime.now(),
      ),
      lines: [
        for (final l in lines)
          ReceiptLine(
            name: l.name,
            quantity: l.quantity,
            unitPriceMinor: l.unitPriceMinor,
          ),
      ],
      tenders: [
        for (final t in tenders)
          ReceiptTender(method: t.method, amountMinor: t.amountMinor),
      ],
    );

    await Printing.layoutPdf(
      onLayout: (_) => buildReceiptPdf(
        detail,
        venueName: ref.read(sessionProvider).office ?? 'Vesopa',
      ),
    );
  }

  /// Run the card through Dojo. Returns true only if the money was actually
  /// taken — a decline, an error, or a timeout all return false, so the sale is
  /// never recorded as paid when it was not.
  Future<bool> _takeCard(int amountMinor) async {
    final dojo = ref.read(dojoProvider);
    if (dojo == null) {
      _toast(
        'Card payments are not set up. Add your Dojo key in '
        'Settings › Card payments.',
      );
      return false;
    }

    // The clerk needs to know the till is waiting on the customer, and must not
    // be able to press Card twice while it is.
    //
    // On desktop the provider reports what it is actually doing, and the wait
    // can be abandoned: a card payment can sit unanswered for minutes, and a
    // spinner with no message and no way out strands the till mid-service.
    final desktop = dojo is DesktopDojoProvider ? dojo : null;
    final stage = ValueNotifier<DojoStage>(DojoStage.creating);

    // When the sale runs on a card machine, show what the reader is telling the
    // customer ("present card", "enter PIN") rather than a generic wait — the
    // clerk is the one who has to prompt them.
    final prompt = ValueNotifier<String?>(null);
    final rest = dojo is DojoProvider
        ? dojo
        : desktop?.intents;
    rest?.onTerminalUpdate = (s) => prompt.value = s.prompt;

    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          content: Row(
            children: [
              const CircularProgressIndicator(),
              const SizedBox(width: 20),
              Expanded(
                // The reader's own prompt wins when there is one: "ask the
                // customer to present their card" is more use than "waiting".
                child: ValueListenableBuilder<String?>(
                  valueListenable: prompt,
                  builder: (_, p, _) => ValueListenableBuilder<DojoStage>(
                    valueListenable: stage,
                    builder: (_, s, _) => Text(
                      p ??
                          switch (s) {
                            DojoStage.creating => 'Starting the payment…',
                            DojoStage.sendingToTerminal =>
                              'Sending to the card machine…',
                            DojoStage.awaitingCard => 'Waiting for the card…',
                            DojoStage.checking => 'Checking with Dojo…',
                          },
                    ),
                  ),
                ),
              ),
            ],
          ),
          actions: desktop == null
              ? null
              : [
                  TextButton(
                    onPressed: () {
                      // Stop polling; the result comes back as "abandoned",
                      // never as paid or declined.
                      desktop.cancel();
                      Navigator.of(dialogContext).pop();
                    },
                    child: const Text('Cancel payment'),
                  ),
                ],
        ),
      ),
    );

    // Drive the dialog's message from the provider's progress.
    desktop?.onStageChanged = (s) => stage.value = s;

    final result = await dojo.take(amountMinor, orderId: widget.orderId);

    // Detach before disposing, or a late poll would write to a dead notifier.
    rest?.onTerminalUpdate = null;
    stage.dispose();
    prompt.dispose();
    // The dialog may already be gone if the clerk cancelled.
    if (mounted && Navigator.of(context, rootNavigator: true).canPop()) {
      Navigator.of(context, rootNavigator: true).pop();
    }

    if (!result.approved) {
      _toast(result.message ?? 'Card payment declined.');
      return false;
    }
    return true;
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 5)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(orderRepositoryProvider);

    return StreamBuilder<Order>(
      stream: repo.watchOrder(widget.orderId),
      builder: (context, orderSnap) {
        return StreamBuilder<List<OrderLine>>(
          stream: repo.watchLines(widget.orderId),
          builder: (context, linesSnap) {
            final order = orderSnap.data;
            final lines = linesSnap.data ?? const <OrderLine>[];
            final outstanding = order?.totalMinor ?? 0;

            // A Scaffold, not a bare Column: without one there is no Material
            // surface behind the page, so on Android it rendered over whatever
            // was beneath it and dialogs and snackbars had nowhere to attach.
            return Scaffold(
              appBar: AppBar(
                backgroundColor: Pos.chrome,
                foregroundColor: Colors.white,
                title: const Text('Payment'),
                leading: IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
              body: Column(
                children: [
                  Expanded(
                    child: context.isPhone
                        // Phone: the total and the tender keys are what matter.
                        // Vouchers move behind a tab rather than competing for
                        // width with the thing that takes the money.
                        ? _PhonePayment(
                            outstanding: outstanding,
                            entry: _entry,
                            onKey: _key,
                            onCash: (amount) =>
                                _settle('cash', outstanding, amount: amount),
                            onCard: () => _settle('card', outstanding),
                          )
                        : Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              BasketPanel(
                                lines: lines,
                                order: order,
                                footer: _Keypad(entry: _entry, onKey: _key),
                              ),
                              Expanded(child: _DiscountColumn()),
                              Expanded(
                                child: _TenderColumn(
                                  outstanding: outstanding,
                                  onCash: (amount) => _settle(
                                    'cash',
                                    outstanding,
                                    amount: amount,
                                  ),
                                  onCard: () => _settle('card', outstanding),
                                ),
                              ),
                            ],
                          ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

/// Payment on a phone: amount due at the top, then tenders. Everything else is
/// one tab away.
class _PhonePayment extends StatelessWidget {
  const _PhonePayment({
    required this.outstanding,
    required this.entry,
    required this.onKey,
    required this.onCash,
    required this.onCard,
  });

  final int outstanding;
  final String entry;
  final ValueChanged<String> onKey;
  final void Function(int? amount) onCash;
  final VoidCallback onCard;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          Container(
            width: double.infinity,
            color: Theme.of(context).posTotals,
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
              children: [
                const Text('Amount due', style: TextStyle(fontSize: 14)),
                const SizedBox(height: 4),
                Text(
                  money(outstanding),
                  style: const TextStyle(
                    fontSize: 34,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          const TabBar(
            tabs: [
              Tab(text: 'Pay'),
              Tab(text: 'Vouchers'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    _Keypad(entry: entry, onKey: onKey),
                    const SizedBox(height: 12),
                    _TenderColumn(
                      outstanding: outstanding,
                      onCash: onCash,
                      onCard: onCard,
                      shrinkWrap: true,
                    ),
                  ],
                ),
                _DiscountColumn(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Vouchers and discounts. Laid out as in the mockup; the handlers are stubs
/// until the loyalty/voucher backend exists.
class _DiscountColumn extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _Tile(label: 'Deposit', color: Pos.orange),
        _Tile(
          label: 'Deposit Reedem',
          color: Pos.orange.withValues(alpha: 0.85),
        ),
        _Tile(label: 'Room Charge', color: Pos.amber),
        _Tile(label: 'Paper Voucher', color: Pos.teal),
        const SizedBox(height: 4),
        Row(
          children: [
            _SmallTile(label: 'Gesture'),
            _SmallTile(label: 'X-Mas Voucher'),
            _SmallTile(label: 'Staff Discount 40%'),
          ],
        ),
        Row(
          children: [
            _SmallTile(label: '5% Off Royal Mall'),
            _SmallTile(label: '10% Off Royal Mall'),
            _SmallTile(label: 'Pete Fair'),
          ],
        ),
        Row(
          children: [
            _SmallTile(label: 'Complementary'),
            _SmallTile(label: 'Staffy'),
            _SmallTile(label: '5% Room Service Voucher'),
          ],
        ),
        const SizedBox(height: 4),
        _Tile(
          label: 'Smart Gift Voucher',
          color: Pos.green,
          icon: Icons.card_giftcard,
        ),
      ],
    );
  }
}

class _TenderColumn extends StatelessWidget {
  const _TenderColumn({
    required this.outstanding,
    required this.onCash,
    required this.onCard,
    this.shrinkWrap = false,
  });

  final int outstanding;
  final void Function(int? amount) onCash;
  final VoidCallback onCard;

  /// Set when nested inside another scrollable (the phone layout).
  final bool shrinkWrap;

  @override
  Widget build(BuildContext context) {
    return ListView(
      shrinkWrap: shrinkWrap,
      physics: shrinkWrap ? const NeverScrollableScrollPhysics() : null,
      padding: shrinkWrap ? EdgeInsets.zero : const EdgeInsets.all(12),
      children: [
        _Tile(label: 'Gratuity', color: Pos.amber),
        // Quick-cash keys: the note the customer handed over, so the clerk does
        // not have to key it.
        _Tile(
          label: '£10 Cash',
          color: Pos.cyan,
          icon: Icons.money,
          onTap: () => onCash(1000),
        ),
        _Tile(
          label: '£20 Cash',
          color: Pos.cyan,
          icon: Icons.money,
          onTap: () => onCash(2000),
        ),
        _Tile(
          label: '£50 Cash',
          color: Pos.cyan,
          icon: Icons.money,
          onTap: () => onCash(5000),
        ),
        _Tile(
          label: 'Cash',
          color: Pos.cyan,
          icon: Icons.money,
          onTap: () => onCash(null),
        ),
        _Tile(
          label: 'Card',
          color: Pos.purple,
          icon: Icons.credit_card,
          onTap: onCard,
        ),
        _Tile(
          label: 'Partial Card',
          color: Pos.purple,
          icon: Icons.credit_card,
        ),
        _Tile(label: 'Manual Card', color: Pos.purple, icon: Icons.credit_card),
        _Tile(
          label: 'Spend Loyalty Points',
          color: Pos.indigo,
          icon: Icons.loyalty,
        ),
      ],
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.label,
    required this.color,
    this.icon,
    this.onTap,
  });

  final String label;
  final Color color;
  final IconData? icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: color,
        borderRadius: BorderRadius.circular(3),
        child: InkWell(
          borderRadius: BorderRadius.circular(3),
          onTap:
              onTap ??
              () => ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('$label is not wired up yet.')),
              ),
          child: Container(
            height: 48,
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: [
                if (icon != null) ...[
                  Icon(icon, color: Colors.white, size: 20),
                  const SizedBox(width: 12),
                ],
                Text(
                  label,
                  style: const TextStyle(color: Colors.white, fontSize: 15),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SmallTile extends StatelessWidget {
  const _SmallTile({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.only(right: 4, bottom: 4),
        child: Material(
          color: Pos.red,
          child: InkWell(
            onTap: () => ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('$label is not wired up yet.')),
            ),
            child: Container(
              height: 44,
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Keypad extends StatelessWidget {
  const _Keypad({required this.entry, required this.onKey});

  final String entry;
  final ValueChanged<String> onKey;

  static const _keys = [
    ['1', '2', '3'],
    ['4', '5', '6'],
    ['7', '8', '9'],
    ['.', '0', 'CL'],
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Keys and the entry field read from the theme instead of fixed greys, so
    // the keypad is legible in dark mode rather than washed-out.
    final keyColor = theme.colorScheme.surfaceContainerHighest;
    final entryColor = theme.colorScheme.surfaceContainerHigh;

    return Column(
      children: [
        Container(
          color: entryColor,
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          alignment: Alignment.centerRight,
          child: Text(
            entry.isEmpty ? '0' : entry,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurface,
            ),
          ),
        ),
        for (final row in _keys)
          Row(
            children: [
              for (final k in row)
                Expanded(
                  child: Material(
                    color: keyColor,
                    child: InkWell(
                      onTap: () => onKey(k),
                      child: Container(
                        height: 40,
                        alignment: Alignment.center,
                        margin: const EdgeInsets.all(1),
                        child: Text(
                          k,
                          style: TextStyle(
                            fontSize: 16,
                            color: k == 'CL'
                                ? Pos.red
                                : theme.colorScheme.onSurface,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
      ],
    );
  }
}
