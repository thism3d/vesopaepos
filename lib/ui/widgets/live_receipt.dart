import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../data/branding.dart';
import '../../data/pricing_engine.dart';
import '../../data/tender_engine.dart';

String _money(int minor) =>
    NumberFormat.currency(locale: 'en_GB', symbol: '£').format(minor / 100);

String _qty(double q) =>
    q % 1 == 0 ? q.toStringAsFixed(0) : q.toStringAsFixed(2);

/// The bill, drawn as the receipt it will become.
///
/// Shown on both the sale screen and the payment screen, deliberately
/// identical: what the clerk approves is what prints, and a customer leaning
/// over the counter can read their own bill as it is rung up. Press £10 four
/// times and four lines appear here, with the running total underneath.
///
/// This is a *live* view of an unsettled bill, so it shows things a printed
/// receipt cannot — what is still to pay, which share of a split is being
/// taken, and which offers have been applied.
class LiveReceipt extends StatelessWidget {
  const LiveReceipt({
    super.key,
    required this.totals,
    this.branding = const Branding(),
    this.tender,
    this.customerName,
    this.tableNumber,
    this.covers,
    this.clerkName,
    this.onTapLine,
    this.onRemoveLine,
    this.showHeader = true,
    this.emptyMessage = 'No items yet',
  });

  final BasketTotals totals;
  final Branding branding;

  /// Payment progress, when the bill is being settled. Null on the sale
  /// screen, where nothing has been tendered yet.
  final TenderState? tender;

  final String? customerName;
  final int? tableNumber;
  final int? covers;
  final String? clerkName;

  final void Function(PricedLine line)? onTapLine;
  final void Function(PricedLine line)? onRemoveLine;

  final bool showHeader;
  final String emptyMessage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    // Monospace, because a receipt's columns have to line up and proportional
    // digits make a column of prices look ragged.
    final body = theme.textTheme.bodyMedium?.copyWith(
      fontFamily: 'monospace',
      fontFamilyFallback: const ['Menlo', 'Consolas', 'Courier New'],
      height: 1.35,
    );
    final small = body?.copyWith(
      fontSize: (body.fontSize ?? 14) - 2,
      color: scheme.onSurfaceVariant,
    );

    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          if (showHeader) _Header(branding: branding, small: small),

          Expanded(
            child: totals.lines.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.receipt_long_outlined,
                            size: 40, color: scheme.outlineVariant),
                        const SizedBox(height: 10),
                        Text(emptyMessage,
                            style: theme.textTheme.bodyMedium
                                ?.copyWith(color: scheme.onSurfaceVariant)),
                      ],
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
                    children: [
                      _Context(
                        tableNumber: tableNumber,
                        covers: covers,
                        clerkName: clerkName,
                        customerName: customerName,
                        style: small,
                      ),
                      const SizedBox(height: 4),
                      for (final line in totals.lines)
                        _LineRow(
                          line: line,
                          body: body,
                          small: small,
                          onTap: onTapLine,
                          onRemove: onRemoveLine,
                        ),
                    ],
                  ),
          ),

          _Totals(
            totals: totals,
            tender: tender,
            body: body,
            small: small,
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.branding, this.small});

  final Branding branding;
  final TextStyle? small;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final name = branding.venueName.isNotEmpty ? branding.venueName : 'VESOPA';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
      color: scheme.surfaceContainerHighest,
      child: Column(
        children: [
          Text(
            name.toUpperCase(),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.1,
                ),
          ),
          if (branding.addressLines.isNotEmpty)
            Text(
              branding.addressLines.first,
              textAlign: TextAlign.center,
              style: small,
            ),
        ],
      ),
    );
  }
}

class _Context extends StatelessWidget {
  const _Context({
    this.tableNumber,
    this.covers,
    this.clerkName,
    this.customerName,
    this.style,
  });

  final int? tableNumber;
  final int? covers;
  final String? clerkName;
  final String? customerName;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final bits = <String>[
      if (tableNumber != null) 'Table $tableNumber',
      if (covers != null && covers! > 0) '$covers covers',
      if (clerkName?.isNotEmpty ?? false) clerkName!,
      DateFormat('HH:mm').format(DateTime.now()),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(bits.join('  ·  '), style: style),
        if (customerName?.isNotEmpty ?? false)
          Text(customerName!,
              style: style?.copyWith(fontWeight: FontWeight.bold)),
        const Divider(height: 12),
      ],
    );
  }
}

/// One item, with whatever needs explaining underneath it: the unit price on a
/// multiple, a kitchen note, and the offer that reduced it.
class _LineRow extends StatelessWidget {
  const _LineRow({
    required this.line,
    this.body,
    this.small,
    this.onTap,
    this.onRemove,
  });

  final PricedLine line;
  final TextStyle? body;
  final TextStyle? small;
  final void Function(PricedLine line)? onTap;
  final void Function(PricedLine line)? onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return InkWell(
      onTap: onTap == null ? null : () => onTap!(line),
      onLongPress: onRemove == null ? null : () => onRemove!(line),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 28,
                  child: Text(_qty(line.quantity), style: body),
                ),
                Expanded(child: Text(line.name, style: body)),
                const SizedBox(width: 8),
                Text(
                  _money(line.discounted ? line.netMinor : line.grossMinor),
                  style: body?.copyWith(fontWeight: FontWeight.w600),
                ),
              ],
            ),

            // Unit price, when it is not obvious from a single item.
            if (line.quantity != 1)
              Padding(
                padding: const EdgeInsets.only(left: 28),
                child: Text('@ ${_money(line.unitPriceMinor)} each',
                    style: small),
              ),

            // The kitchen note.
            if (line.note?.isNotEmpty ?? false)
              Padding(
                padding: const EdgeInsets.only(left: 28),
                child: Text(
                  '* ${line.note}',
                  style: small?.copyWith(fontStyle: FontStyle.italic),
                ),
              ),

            // The offer, and what it saved. Shown per line so a customer can
            // see why an item is cheaper than the menu says.
            if (line.discounted)
              Padding(
                padding: const EdgeInsets.only(left: 28, top: 1),
                child: Row(
                  children: [
                    Icon(Icons.local_offer,
                        size: 11, color: scheme.tertiary),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        line.promotionName ?? 'Offer',
                        style: small?.copyWith(
                          color: scheme.tertiary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Text(
                      '-${_money(line.discountMinor)}',
                      style: small?.copyWith(
                        color: scheme.tertiary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The money block. Reductions only appear when they are non-zero, so a plain
/// cash sale is not padded with rows of zeroes.
class _Totals extends StatelessWidget {
  const _Totals({
    required this.totals,
    this.tender,
    this.body,
    this.small,
  });

  final BasketTotals totals;
  final TenderState? tender;
  final TextStyle? body;
  final TextStyle? small;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final t = totals;
    final showBreakdown = t.savedMinor > 0 || t.gratuityMinor > 0;

    Widget row(String label, int minor,
        {bool bold = false, Color? colour, TextStyle? style}) {
      final base = (style ?? body)?.copyWith(
        fontWeight: bold ? FontWeight.bold : null,
        color: colour,
      );
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 1.5),
        child: Row(
          children: [
            Expanded(child: Text(label, style: base)),
            Text(_money(minor), style: base),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showBreakdown) ...[
            row('Subtotal', t.grossMinor, style: small),
            if (t.promoMinor > 0)
              row('Offers', -t.promoMinor,
                  colour: scheme.tertiary, style: small),
            if (t.manualDiscountMinor > 0)
              row('Discount', -t.manualDiscountMinor,
                  colour: scheme.tertiary, style: small),
            if (t.voucherMinor > 0)
              row('Voucher', -t.voucherMinor,
                  colour: scheme.tertiary, style: small),
            if (t.pointsMinor > 0)
              row('Points redeemed', -t.pointsMinor,
                  colour: scheme.tertiary, style: small),
            if (t.gratuityMinor > 0)
              row('Service ${(t.gratuityBp / 10).toStringAsFixed(t.gratuityBp % 10 == 0 ? 0 : 1)}%',
                  t.gratuityMinor, style: small),
            const Divider(height: 12),
          ],

          Row(
            children: [
              Expanded(
                child: Text('TOTAL',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w800)),
              ),
              Text(
                _money(t.totalMinor),
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
            ],
          ),

          // What has been taken so far, once the bill is being settled.
          if (tender != null && tender!.tenders.isNotEmpty) ...[
            const Divider(height: 14),
            for (final entry in tender!.tenders)
              row(
                entry.entryMode == 'manual'
                    ? '${entry.label} (keyed)'
                    : entry.label,
                entry.amountMinor,
                style: small,
              ),
            if (tender!.changeMinor > 0)
              row('Change', tender!.changeMinor, bold: true),
          ],

          if (tender != null && tender!.outstandingMinor > 0 &&
              tender!.tenders.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
                decoration: BoxDecoration(
                  color: scheme.errorContainer,
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text('Still to pay',
                          style: body?.copyWith(
                              color: scheme.onErrorContainer,
                              fontWeight: FontWeight.bold)),
                    ),
                    Text(
                      _money(tender!.outstandingMinor),
                      style: body?.copyWith(
                          color: scheme.onErrorContainer,
                          fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ),

          // Which share of a split is being taken.
          if (tender?.isSplit ?? false) ...[
            const SizedBox(height: 8),
            _SplitStrip(tender: tender!),
          ],
        ],
      ),
    );
  }
}

/// The shares of a split bill, with the active one highlighted.
class _SplitStrip extends StatelessWidget {
  const _SplitStrip({required this.tender});

  final TenderState tender;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final share in tender.shares)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
            decoration: BoxDecoration(
              color: share.settled
                  ? scheme.primaryContainer
                  : share.index == tender.activeShare
                      ? scheme.primary
                      : scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(7),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (share.settled)
                  Icon(Icons.check,
                      size: 13, color: scheme.onPrimaryContainer),
                if (share.settled) const SizedBox(width: 4),
                Text(
                  '${share.index + 1}: ${_money(share.outstandingMinor)}',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: share.settled
                        ? scheme.onPrimaryContainer
                        : share.index == tender.activeShare
                            ? scheme.onPrimary
                            : scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
