import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Outcome of asking a payment method for money.
class PaymentResult {
  const PaymentResult({
    required this.approved,
    required this.amountMinor,
    this.reference,
    this.message,
  });

  final bool approved;
  final int amountMinor;

  /// The acquirer's transaction reference, kept against the sale for
  /// reconciliation and refunds.
  final String? reference;
  final String? message;
}

/// A created Dojo payment intent: its id and the client session secret the
/// native drop-in SDK needs to drive the card presentation and 3-D Secure.
class DojoIntent {
  const DojoIntent({required this.id, this.clientSecret});
  final String id;
  final String? clientSecret;
}

/// A way of taking money. Cash needs no device; card goes to Dojo.
abstract class PaymentProvider {
  String get method;
  Future<PaymentResult> take(int amountMinor, {String? orderId});
}

/// Cash. Always succeeds — the clerk has the money in their hand.
class CashProvider implements PaymentProvider {
  @override
  String get method => 'cash';

  @override
  Future<PaymentResult> take(int amountMinor, {String? orderId}) async {
    return PaymentResult(approved: true, amountMinor: amountMinor);
  }
}

/// Dojo card payments.
///
/// Verified against the sandbox: base URL, `Basic` auth, and the mandatory
/// `version` header are all confirmed working. Creating an intent returns
/// status `Created` — an intent is only a request for money, NOT a payment.
/// The card still has to be presented, after which the intent moves to
/// `Succeeded`/`Captured`. Treating `Created` as paid would book money that was
/// never taken, so [take] polls until the intent actually settles.
///
/// NOT covered here: sending the intent to a physical card terminal. That path
/// needs a `software-house-id` header, which Dojo issues to integration
/// partners on onboarding — the sandbox key alone is rejected with
/// "A software house ID header is required". Set [softwareHouseId] once Dojo
/// grant one and the terminal call below becomes live.
class DojoProvider implements PaymentProvider {
  DojoProvider({
    required this.apiKey,
    this.terminalId,
    this.softwareHouseId,
    this.baseUrl = 'https://api.dojo.tech',
    this.apiVersion = '2024-01-01',
    this.pollTimeout = const Duration(minutes: 2),
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String apiKey;

  /// The physical card machine. Null means card-not-present.
  final String? terminalId;

  /// Partner credential required by Dojo's terminal endpoints.
  final String? softwareHouseId;

  final String baseUrl;
  final String apiVersion;
  final Duration pollTimeout;
  final http.Client _client;

  @override
  String get method => 'card';

  Map<String, String> get _headers => {
        // Dojo uses Basic auth with the raw key — NOT Bearer, and NOT
        // base64-encoded. Bearer is rejected with 401.
        'Authorization': 'Basic $apiKey',
        'version': apiVersion,
        'Content-Type': 'application/json',
      };

  /// Create the intent. Returns its id and client session secret.
  ///
  /// The request body uses PascalCase `Amount`/`Value`/`CurrencyCode`: the Dojo
  /// API rejects `{"amount": …}` with "The Amount field is required." Verified
  /// against the sandbox — this shape returns a `pi_sandbox_…` intent with a
  /// `clientSessionSecret`, which the native drop-in SDK needs.
  ///
  /// Dojo ignores `Idempotency-Key` — posting the same body twice creates two
  /// distinct intents. The caller must therefore hold onto the id it gets back
  /// and reuse it on retry, or a flaky connection will charge the customer
  /// twice. That is why this is separate from [confirm].
  Future<DojoIntent> createIntent(int amountMinor, {String? orderId}) async {
    final res = await _client
        .post(
          Uri.parse('$baseUrl/payment-intents'),
          headers: _headers,
          body: jsonEncode({
            'Amount': {'Value': amountMinor, 'CurrencyCode': 'GBP'},
            'Reference': orderId ?? 'vesopa',
            'CaptureMode': 'Auto',
          }),
        )
        .timeout(const Duration(seconds: 30));

    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw DojoException('Could not start payment: ${res.body}');
    }

    final json = jsonDecode(res.body) as Map<String, dynamic>;
    return DojoIntent(
      id: json['id'] as String,
      // Dojo returns the secret as `clientSessionSecret`; the SDK calls the same
      // value `clientSecret`.
      clientSecret: json['clientSessionSecret'] as String?,
    );
  }

  /// Read an intent's current state.
  Future<Map<String, dynamic>> fetchIntent(String intentId) async {
    final res = await _client
        .get(Uri.parse('$baseUrl/payment-intents/$intentId'),
            headers: _headers)
        .timeout(const Duration(seconds: 20));

    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw DojoException('Could not read payment: ${res.body}');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// Ask the card machine to take the payment.
  Future<void> sendToTerminal(String intentId) async {
    final id = softwareHouseId;
    if (id == null || terminalId == null) {
      throw DojoException(
        'Card terminal not configured. Dojo requires a software-house-id '
        '(issued on partner onboarding) plus a terminal id.',
      );
    }

    final res = await _client
        .post(
          Uri.parse('$baseUrl/payment-intents/$intentId/terminal'),
          headers: {..._headers, 'software-house-id': id},
          body: jsonEncode({'terminalId': terminalId}),
        )
        .timeout(const Duration(seconds: 30));

    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw DojoException('Terminal rejected the payment: ${res.body}');
    }
  }

  static const _paid = {'succeeded', 'captured'};
  static const _failed = {'failed', 'cancelled', 'canceled', 'expired'};

  /// Wait for the customer to present their card.
  Future<PaymentResult> confirm(String intentId, int amountMinor) async {
    final deadline = DateTime.now().add(pollTimeout);

    while (DateTime.now().isBefore(deadline)) {
      final intent = await fetchIntent(intentId);
      final status = (intent['status'] as String? ?? '').toLowerCase();

      if (_paid.contains(status)) {
        return PaymentResult(
          approved: true,
          amountMinor: amountMinor,
          reference: intentId,
          message: status,
        );
      }
      if (_failed.contains(status)) {
        return PaymentResult(
          approved: false,
          amountMinor: amountMinor,
          reference: intentId,
          message: 'Card payment $status',
        );
      }

      await Future<void>.delayed(const Duration(seconds: 2));
    }

    // Timed out with the intent still open. This is NOT a decline — the money
    // may yet be taken — so it must never be recorded as either paid or
    // refused. The clerk has to check the terminal.
    return PaymentResult(
      approved: false,
      amountMinor: amountMinor,
      reference: intentId,
      message: 'Timed out waiting for the card. Check the terminal before '
          'retrying — the payment may still have gone through.',
    );
  }

  @override
  Future<PaymentResult> take(int amountMinor, {String? orderId}) async {
    try {
      final intent = await createIntent(amountMinor, orderId: orderId);

      if (softwareHouseId != null && terminalId != null) {
        await sendToTerminal(intent.id);
      }

      return confirm(intent.id, amountMinor);
    } catch (e) {
      // An errored card payment is NOT a payment. Never fall back to assuming
      // it worked — the till would record money it never took.
      return PaymentResult(
        approved: false,
        amountMinor: amountMinor,
        message: '$e',
      );
    }
  }
}

class DojoException implements Exception {
  DojoException(this.message);
  final String message;

  @override
  String toString() => message;
}
