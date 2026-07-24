import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/commerce.dart';

String _money(int minor) =>
    NumberFormat.currency(locale: 'en_GB', symbol: '£').format(minor / 100);

/// Confirm a tender before it is taken.
///
/// Every other route to money on this screen already has a confirmation built
/// in — a gift card is looked up, a voucher is validated, points are chosen —
/// but Cash and Card went straight through on a single tap. On a touch till
/// that is one mis-hit away from a card payment nobody asked for, or a cash
/// sale rung up at the wrong amount and then needing a void.
///
/// So this is the last step: it states the method, the amount, and what the
/// tap will actually do to the bill — settle it, leave a balance, or hand back
/// change — because those are the three things the clerk is about to have to
/// tell the customer.
///
/// Returns true to go ahead.
Future<bool> confirmTender(
  BuildContext context, {
  required TenderKind kind,
  required int amountMinor,
  required int dueMinor,
  bool manual = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    // A confirmation that can be dismissed by a stray tap on the backdrop is
    // not a confirmation.
    barrierDismissible: false,
    builder: (context) => _ConfirmTenderDialog(
      kind: kind,
      amountMinor: amountMinor,
      dueMinor: dueMinor,
      manual: manual,
    ),
  );
  return result ?? false;
}

class _ConfirmTenderDialog extends StatelessWidget {
  const _ConfirmTenderDialog({
    required this.kind,
    required this.amountMinor,
    required this.dueMinor,
    required this.manual,
  });

  final TenderKind kind;
  final int amountMinor;
  final int dueMinor;
  final bool manual;

  /// Cash is the only tender that can be overpaid — the surplus is change.
  /// Anything else is capped at what is owed before it gets here.
  int get _changeMinor {
    if (kind != TenderKind.cash) return 0;
    final over = amountMinor - dueMinor;
    return over > 0 ? over : 0;
  }

  int get _remainingMinor {
    final left = dueMinor - amountMinor;
    return left > 0 ? left : 0;
  }

  (IconData, String) get _identity => switch (kind) {
    TenderKind.cash => (Icons.payments, 'Cash'),
    TenderKind.manualCard => (Icons.dialpad, 'Manual card'),
    TenderKind.card => (
      Icons.credit_card,
      manual ? 'Manual card' : 'Card',
    ),
    TenderKind.giftCard => (Icons.card_giftcard, 'Gift card'),
    TenderKind.voucher => (Icons.confirmation_number_outlined, 'Voucher'),
    TenderKind.deposit => (Icons.account_balance_wallet_outlined, 'Deposit'),
    TenderKind.points => (Icons.stars_outlined, 'Points'),
    TenderKind.account => (Icons.receipt_long, 'On account'),
  };

  /// What happens next, in the words the clerk will use at the counter.
  String get _consequence {
    if (_changeMinor > 0) {
      return 'Settles the bill and gives ${_money(_changeMinor)} change.';
    }
    if (_remainingMinor > 0) {
      return '${_money(_remainingMinor)} will still be left to pay.';
    }
    return 'This settles the bill.';
  }

  String get _action => switch (kind) {
    TenderKind.cash => 'Take cash',
    TenderKind.card ||
    TenderKind.manualCard => manual ? 'Key the card' : 'Take card',
    _ => 'Take payment',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (icon, label) = _identity;
    final isCard = kind == TenderKind.card || kind == TenderKind.manualCard;

    return AlertDialog(
      icon: Icon(icon, size: 30, color: scheme.primary),
      title: Text('$label payment'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // The amount is the thing being confirmed, so it is the largest
            // thing on the dialog.
            Container(
              padding: const EdgeInsets.symmetric(vertical: 16),
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  Text(
                    'Taking',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: scheme.onPrimaryContainer.withValues(alpha: 0.8),
                    ),
                  ),
                  Text(
                    _money(amountMinor),
                    style: theme.textTheme.displaySmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: scheme.onPrimaryContainer,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            _Line(label: 'Bill outstanding', value: _money(dueMinor)),
            if (_changeMinor > 0)
              _Line(label: 'Change owed', value: _money(_changeMinor), bold: true)
            else if (_remainingMinor > 0)
              _Line(
                label: 'Left to pay after this',
                value: _money(_remainingMinor),
                bold: true,
              ),
            const SizedBox(height: 12),
            Text(_consequence, style: theme.textTheme.bodyMedium),
            if (isCard) ...[
              const SizedBox(height: 10),
              Text(
                manual
                    ? 'The card number is keyed rather than presented. Only do '
                          'this when the card cannot be read or the customer is '
                          'not here.'
                    : 'The customer will be asked to present their card next.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: () => Navigator.pop(context, true),
          icon: Icon(icon, size: 18),
          label: Text('$_action ${_money(amountMinor)}'),
        ),
      ],
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.label, required this.value, this.bold = false});

  final String label;
  final String value;
  final bool bold;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 13.5,
            ),
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 14.5,
            fontWeight: bold ? FontWeight.w800 : FontWeight.w600,
          ),
        ),
      ],
    ),
  );
}
