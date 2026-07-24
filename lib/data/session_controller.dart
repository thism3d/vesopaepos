import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Who is signed into this terminal.
class Session {
  const Session({
    this.email,
    this.name,
    this.office,
    this.officeName,
    this.token,
  });

  final String? email;
  final String? name;

  /// The venue whose catalogue and sales this terminal belongs to, as its
  /// **contact email** — the tenancy key every catalogue read and write is
  /// scoped by. It is an identifier, not a name: never show it to a customer.
  final String? office;

  /// The venue's trading name, for anything a customer sees.
  ///
  /// Separate from [office] because that one is an email address, and printing
  /// it at the top of a receipt put a staff address in the customer's hand.
  final String? officeName;

  final String? token;

  bool get signedIn => token != null && office != null;

  /// What to print above a receipt. Falls back to the product name rather than
  /// to [office]: a till that has not been told its trading name should say
  /// nothing about the venue rather than leak an email address.
  String get venueName =>
      officeName?.trim().isNotEmpty ?? false ? officeName!.trim() : 'Vesopa';

  static const empty = Session();

  Map<String, dynamic> toJson() => {
        'email': email,
        'name': name,
        'office': office,
        'officeName': officeName,
        'token': token,
      };

  factory Session.fromJson(Map<String, dynamic> json) => Session(
        email: json['email'] as String?,
        name: json['name'] as String?,
        office: json['office'] as String?,
        officeName: json['officeName'] as String?,
        token: json['token'] as String?,
      );
}

class SignInFailed implements Exception {
  SignInFailed(this.message);
  final String message;

  @override
  String toString() => message;
}

/// The terminal's sign-in.
///
/// The till is commissioned by signing in once with a back-office account. That
/// tells it which venue it belongs to — so the office is no longer a build-time
/// flag baked into the APK, and the same binary can be installed in any venue.
///
/// The session is persisted, so the terminal does not demand a password every
/// morning; it is cleared only on an explicit, verified sign-out.
class SessionController extends AsyncNotifier<Session> {
  static const _key = 'session';

  @override
  Future<Session> build() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return Session.empty;
    try {
      return Session.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return Session.empty;
    }
  }

  /// Sign in against the back office. Only a successful, live response
  /// commissions the terminal — there is no offline path in, because a terminal
  /// that has never spoken to the server has no catalogue to sell from anyway.
  Future<void> signIn({
    required String apiBase,
    required String email,
    required String password,
  }) async {
    final http.Response res;
    try {
      res = await http
          .post(
            Uri.parse('$apiBase/api/login'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'email': email, 'password': password}),
          )
          .timeout(const Duration(seconds: 15));
    } catch (e) {
      throw SignInFailed(
        'Cannot reach the server at $apiBase.\n'
        'Check the address and the network, then try again.',
      );
    }

    final body = jsonDecode(res.body) as Map<String, dynamic>;

    if (res.statusCode == 401) {
      throw SignInFailed('That email or password is not correct.');
    }
    if (res.statusCode != 200) {
      throw SignInFailed((body['error'] as String?) ?? 'Sign-in failed.');
    }

    final user = body['user'] as Map<String, dynamic>;

    // The catalogue is keyed by the office's contact email, so a user with no
    // office has nothing to sell and must not be allowed to commission a till.
    final office = (user['officeEmail'] ?? user['email']) as String?;
    if (office == null) {
      throw SignInFailed('This account is not attached to an office.');
    }

    final session = Session(
      email: user['email'] as String?,
      name: user['name'] as String?,
      office: office,
      // The server has always sent this; the till simply never kept it, which
      // is why receipts printed the office email as the venue's name.
      officeName: user['officeName'] as String?,
      token: body['token'] as String?,
    );

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(session.toJson()));
    state = AsyncData(session);
  }

  /// Clear the session. The caller is responsible for having verified the
  /// password and flushed the outbox first — see AuthService.
  Future<void> signOut() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
    state = const AsyncData(Session.empty);
  }
}

final sessionControllerProvider =
    AsyncNotifierProvider<SessionController, Session>(SessionController.new);
