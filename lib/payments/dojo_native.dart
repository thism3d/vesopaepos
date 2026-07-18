import 'dart:async';

import 'package:flutter/services.dart';

import 'payment_provider.dart';

/// Card payments through Dojo's **native Android drop-in SDK**
/// (`tech.dojo.pay:uisdk`), rather than driving the REST API from Dart.
///
/// Why native at all: Dojo's card flow includes 3-D Secure (via Cardinal),
/// card entry UI and Google Pay — none of which the REST API alone can present.
/// The sandbox only completes a payment when a real card is presented through
/// this SDK, which is why the pure-REST path could create an intent but never
/// see it settle. See [DojoProvider] for the REST fallback used on platforms
/// where the SDK is not available (desktop).
///
/// The split of responsibilities:
///   1. Dart creates the payment intent over REST ([DojoProvider.createIntent])
///      to get a `paymentId` + `clientSecret`.
///   2. Dart hands those to the native side over [_channel]; the Kotlin handler
///      calls `DojoSDKDropInUI.startUIPaymentFlowForResult`.
///   3. The native result (a `DojoPaymentResult` code) comes back and is mapped
///      to a [PaymentResult].
///
/// Sandbox is selected on the native side from [isSandbox] via
/// `DojoSDKDebugConfig(isSandboxIntent = true)` — there is no separate host.
class NativeDojoProvider implements PaymentProvider {
  NativeDojoProvider({
    required this.intents,
    required this.isSandbox,
    MethodChannel? channel,
  }) : _channel = channel ?? const MethodChannel('vesopa/dojo');

  /// Creates the payment intent over REST. Reused from the REST provider so the
  /// intent-creation logic (auth, payload shape, retries) lives in one place.
  final DojoProvider intents;

  /// Passed to the SDK's debug config so a `sk_sandbox_` key completes in the
  /// sandbox environment.
  final bool isSandbox;

  final MethodChannel _channel;

  @override
  String get method => 'card';

  /// Dojo's `DojoPaymentResult` enum, by code. Kept in Dart so the mapping is
  /// visible here rather than hidden in Kotlin.
  static const _successful = 0;
  static const _declined = 5;
  static const _userClosed = 7780;

  @override
  Future<PaymentResult> take(int amountMinor, {String? orderId}) async {
    try {
      // 1. Create the intent (REST) to obtain the client session secret.
      final intent = await intents.createIntent(amountMinor, orderId: orderId);
      if (intent.clientSecret == null) {
        return PaymentResult(
          approved: false,
          amountMinor: amountMinor,
          reference: intent.id,
          message: 'Dojo did not return a client secret for this payment.',
        );
      }

      // 2. Launch the native drop-in and wait for the customer to present their
      //    card. The Kotlin side resolves with the integer result code.
      final code = await _channel.invokeMethod<int>('startPayment', {
        'paymentId': intent.id,
        'clientSecret': intent.clientSecret,
        'sandbox': isSandbox,
      });

      // 3. Map the SDK result. Anything other than SUCCESSFUL is not money in.
      if (code == _successful) {
        return PaymentResult(
          approved: true,
          amountMinor: amountMinor,
          reference: intent.id,
          message: 'succeeded',
        );
      }
      return PaymentResult(
        approved: false,
        amountMinor: amountMinor,
        reference: intent.id,
        message: switch (code) {
          _declined => 'Card declined.',
          _userClosed => 'Payment cancelled.',
          _ => 'Card payment failed (code $code).',
        },
      );
    } on MissingPluginException {
      // The native SDK is not bundled on this platform (e.g. desktop). Fall back
      // to the REST provider so the till still takes card where it can.
      return intents.take(amountMinor, orderId: orderId);
    } on PlatformException catch (e) {
      // A native-side error is NOT an approval — never record it as paid.
      return PaymentResult(
        approved: false,
        amountMinor: amountMinor,
        message: e.message ?? 'Card payment error.',
      );
    } catch (e) {
      return PaymentResult(
        approved: false,
        amountMinor: amountMinor,
        message: '$e',
      );
    }
  }
}
