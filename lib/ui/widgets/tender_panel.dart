import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../data/commerce.dart';
import '../../data/tender_engine.dart';

String _money(int minor) =>
    NumberFormat.currency(locale: 'en_GB', symbol: '£').format(minor / 100);

/// The tender side of the payment screen: keypad, quick cash, and every way
/// the venue can take money.
///
/// Sits beside the live receipt rather than covering it, so the clerk can see
/// the bill while taking payment for it. On a phone it is the whole screen;
/// on a Windows touch till it is a docked column.
class TenderPanel extends StatelessWidget {
  const TenderPanel({
    super.key,
    required this.state,
    required this.settings,
    required this.entry,
    required this.onKey,
    required this.onTender,
    this.onGratuity,
    this.onSplit,
    this.onSelectShare,
    this.onClearSplit,
    this.onUndo,
    this.onCustomer,
    this.onDiscount,
    this.compact = false,
  });

  final TenderState state;
  final TenderSettings settings;

  /// What the clerk has keyed in, as typed. Empty means "settle the balance".
  final String entry;

  final void Function(String key) onKey;
  final void Function(TenderKind kind, int amountMinor) onTender;

  final void Function()? onGratuity;
  final void Function()? onSplit;
  final void Function(int index)? onSelectShare;
  final void Function()? onClearSplit;
  final void Function()? onUndo;
  final void Function()? onCustomer;

  /// Take the keyed amount off the bill as the clerk's own discount.
  final void Function()? onDiscount;

  /// Tighter spacing for a docked column on a desktop till.
  final bool compact;

  /// The amount a tender button will take: what was keyed, or the balance.
  int get _amount {
    final keyed = double.tryParse(entry);
    if (keyed != null && keyed > 0) return (keyed * 100).round();
    return state.dueNowMinor;
  }

  /// Whether the keyed amount is a *part* payment rather than the whole
  /// balance. A venue can turn part-payment by card off — some do, because two
  /// card fees on one bill costs them more than the convenience is worth — and
  /// the setting existed but was never honoured, so the switch did nothing.
  bool get _isPartial => _amount > 0 && _amount < state.dueNowMinor;

  /// What the card keys will take, or null when they should be refused.
  int? get _cardAmount {
    if (state.dueNowMinor <= 0) return null;
    if (_isPartial && !settings.allowPartialCard) return null;
    // Never charge a card more than is owed: an overpayment on a card is a
    // refund to arrange, not change to hand over.
    return _amount > state.dueNowMinor ? state.dueNowMinor : _amount;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final due = state.dueNowMinor;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // What is being asked for right now.
        Container(
          padding: EdgeInsets.symmetric(
              vertical: compact ? 10 : 14, horizontal: 14),
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            children: [
              Text(
                state.isSplit
                    ? 'Share ${state.activeShare + 1} of ${state.shares.length}'
                    : 'To pay',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: scheme.onPrimaryContainer.withValues(alpha: 0.8),
                ),
              ),
              Text(
                _money(due),
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: scheme.onPrimaryContainer,
                ),
              ),
              // The keyed amount, when it differs from the balance — this is
              // what makes a part payment visible before it is taken.
              if (entry.isNotEmpty)
                Text(
                  'Taking ${_money(_amount)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onPrimaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
        ),
        SizedBox(height: compact ? 8 : 12),

        // Quick cash. Only amounts at or above what is owed, so a key can
        // never take a payment the customer has not made.
        if (due > 0) ...[
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final amount in state.cashSuggestions(settings.cashPresets))
                _Chip(
                  label: amount == due ? 'Exact' : _money(amount),
                  tone: _ChipTone.cash,
                  onTap: () => onTender(TenderKind.cash, amount),
                ),
            ],
          ),
          SizedBox(height: compact ? 8 : 12),
        ],

        _Keypad(onKey: onKey, compact: compact),
        SizedBox(height: compact ? 8 : 12),

        // Primary tenders.
        Row(
          children: [
            Expanded(
              child: _TenderButton(
                icon: Icons.payments,
                label: 'Cash',
                onTap: due > 0 ? () => onTender(TenderKind.cash, _amount) : null,
                tone: _ChipTone.cash,
                compact: compact,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _TenderButton(
                icon: Icons.credit_card,
                label: _isPartial && settings.allowPartialCard
                    ? 'Part card'
                    : 'Card',
                onTap: _cardAmount == null
                    ? null
                    : () => onTender(TenderKind.card, _cardAmount!),
                tone: _ChipTone.primary,
                compact: compact,
              ),
            ),
          ],
        ),

        // Say why the card keys are refused, rather than leaving a dead button
        // the clerk taps twice before giving up.
        if (due > 0 && _isPartial && !settings.allowPartialCard)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Part payment by card is switched off for this venue — the card '
              'has to cover the whole ${_money(due)}.',
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
            ),
          ),
        const SizedBox(height: 8),

        // Manual card: keyed into the reader by hand, for a card that will not
        // read or a telephone order. Deliberately its own button, because it
        // is recorded differently and carries different liability.
        Row(
          children: [
            Expanded(
              child: _TenderButton(
                icon: Icons.dialpad,
                label: 'Manual card',
                onTap: _cardAmount == null
                    ? null
                    : () => onTender(TenderKind.manualCard, _cardAmount!),
                compact: compact,
              ),
            ),
            if (settings.allowSplitBill) ...[
              const SizedBox(width: 8),
              Expanded(
                child: _TenderButton(
                  icon: Icons.call_split,
                  label: state.isSplit ? 'Shares' : 'Split bill',
                  onTap: onSplit,
                  compact: compact,
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 8),

        // Everything that redeems held money or a discount.
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            _Chip(
              label: 'Gift card',
              icon: Icons.card_giftcard,
              onTap: due > 0
                  ? () => onTender(TenderKind.giftCard, _amount)
                  : null,
            ),
            _Chip(
              label: 'Voucher',
              icon: Icons.confirmation_number_outlined,
              onTap: () => onTender(TenderKind.voucher, _amount),
            ),
            _Chip(
              label: 'Deposit',
              icon: Icons.account_balance_wallet_outlined,
              onTap: due > 0
                  ? () => onTender(TenderKind.deposit, _amount)
                  : null,
            ),
            _Chip(
              label: 'Points',
              icon: Icons.stars_outlined,
              onTap: () => onTender(TenderKind.points, _amount),
            ),
            if (onDiscount != null)
              _Chip(
                label: 'Discount',
                icon: Icons.percent,
                onTap: onDiscount,
              ),
            if (onCustomer != null)
              _Chip(
                label: 'Customer',
                icon: Icons.person_outline,
                onTap: onCustomer,
              ),
            if (settings.gratuityEnabled && onGratuity != null)
              _Chip(
                label: state.totals.gratuityMinor > 0
                    ? 'Service ${_money(state.totals.gratuityMinor)}'
                    : 'Add gratuity',
                icon: Icons.volunteer_activism_outlined,
                tone: state.totals.gratuityMinor > 0
                    ? _ChipTone.active
                    : _ChipTone.plain,
                onTap: onGratuity,
              ),
          ],
        ),

        // Shares of a split, tappable so the clerk can jump between people.
        if (state.isSplit) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text('Shares',
                    style: theme.textTheme.labelMedium
                        ?.copyWith(color: scheme.onSurfaceVariant)),
              ),
              if (onClearSplit != null)
                TextButton(
                  onPressed: onClearSplit,
                  child: const Text('Un-split'),
                ),
            ],
          ),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final share in state.shares)
                _Chip(
                  label: share.settled
                      ? '${share.index + 1} ✓'
                      : '${share.index + 1}: ${_money(share.outstandingMinor)}',
                  tone: share.settled
                      ? _ChipTone.done
                      : share.index == state.activeShare
                          ? _ChipTone.active
                          : _ChipTone.plain,
                  onTap: onSelectShare == null
                      ? null
                      : () => onSelectShare!(share.index),
                ),
            ],
          ),
        ],

        // Undo, once something has been taken.
        if (state.tenders.isNotEmpty && onUndo != null) ...[
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: onUndo,
            icon: const Icon(Icons.undo, size: 18),
            label: Text('Undo ${state.tenders.last.label} '
                '${_money(state.tenders.last.amountMinor)}'),
          ),
        ],
      ],
    );
  }
}

enum _ChipTone { plain, cash, primary, active, done }

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    this.icon,
    this.onTap,
    this.tone = _ChipTone.plain,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final _ChipTone tone;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (bg, fg) = switch (tone) {
      _ChipTone.cash => (scheme.tertiaryContainer, scheme.onTertiaryContainer),
      _ChipTone.primary => (scheme.primary, scheme.onPrimary),
      _ChipTone.active => (scheme.primary, scheme.onPrimary),
      _ChipTone.done => (scheme.primaryContainer, scheme.onPrimaryContainer),
      _ChipTone.plain => (scheme.surfaceContainerHighest, scheme.onSurface),
    };

    return Material(
      color: onTap == null ? scheme.surfaceContainerHighest : bg,
      borderRadius: BorderRadius.circular(9),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(9),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 15,
                    color: onTap == null ? scheme.outline : fg),
                const SizedBox(width: 6),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: onTap == null ? scheme.outline : fg,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TenderButton extends StatelessWidget {
  const _TenderButton({
    required this.icon,
    required this.label,
    this.onTap,
    this.tone = _ChipTone.plain,
    this.compact = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final _ChipTone tone;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (bg, fg) = switch (tone) {
      _ChipTone.cash => (scheme.tertiaryContainer, scheme.onTertiaryContainer),
      _ChipTone.primary => (scheme.primary, scheme.onPrimary),
      _ => (scheme.surfaceContainerHighest, scheme.onSurface),
    };

    return SizedBox(
      height: compact ? 52 : 60,
      child: FilledButton.icon(
        onPressed: onTap,
        style: FilledButton.styleFrom(
          backgroundColor: bg,
          foregroundColor: fg,
          padding: const EdgeInsets.symmetric(horizontal: 8),
        ),
        icon: Icon(icon, size: 19),
        label: Text(
          label,
          style: const TextStyle(fontWeight: FontWeight.w700),
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}

class _Keypad extends StatelessWidget {
  const _Keypad({required this.onKey, this.compact = false});

  final void Function(String key) onKey;
  final bool compact;

  static const _keys = [
    '7', '8', '9',
    '4', '5', '6',
    '1', '2', '3',
    '.', '0', 'CL',
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 6,
      crossAxisSpacing: 6,
      childAspectRatio: compact ? 2.1 : 1.9,
      children: [
        for (final key in _keys)
          Material(
            color: key == 'CL'
                ? scheme.errorContainer
                : scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(9),
            child: InkWell(
              onTap: () => onKey(key),
              borderRadius: BorderRadius.circular(9),
              child: Center(
                child: Text(
                  key,
                  style: TextStyle(
                    fontSize: compact ? 17 : 19,
                    fontWeight: FontWeight.w700,
                    color: key == 'CL'
                        ? scheme.onErrorContainer
                        : scheme.onSurface,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
