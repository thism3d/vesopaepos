import 'dart:convert';

import 'package:http/http.dart' as http;

/// A receipt in the history list.
class ReceiptSummary {
  const ReceiptSummary({
    required this.id,
    required this.totalMinor,
    required this.taxMinor,
    required this.discountMinor,
    required this.closedAt,
    this.tableNumber,
  });

  final String id;
  final int totalMinor;
  final int taxMinor;
  final int discountMinor;
  final DateTime closedAt;
  final int? tableNumber;

  factory ReceiptSummary.fromJson(Map<String, dynamic> j) => ReceiptSummary(
        id: j['id'] as String,
        totalMinor: j['total_minor'] as int? ?? 0,
        taxMinor: j['tax_minor'] as int? ?? 0,
        discountMinor: j['discount_minor'] as int? ?? 0,
        tableNumber: j['table_number'] as int?,
        closedAt:
            DateTime.tryParse(j['closed_at'] as String? ?? '') ?? DateTime.now(),
      );
}

class ReceiptLine {
  const ReceiptLine({
    required this.name,
    required this.quantity,
    required this.unitPriceMinor,
  });

  final String name;
  final double quantity;
  final int unitPriceMinor;

  factory ReceiptLine.fromJson(Map<String, dynamic> j) => ReceiptLine(
        name: j['name'] as String? ?? '',
        quantity: (j['quantity'] as num? ?? 1).toDouble(),
        unitPriceMinor: j['unit_price_minor'] as int? ?? 0,
      );
}

class ReceiptTender {
  const ReceiptTender({required this.method, required this.amountMinor});
  final String method;
  final int amountMinor;

  factory ReceiptTender.fromJson(Map<String, dynamic> j) => ReceiptTender(
        method: j['method'] as String? ?? '',
        amountMinor: j['amount_minor'] as int? ?? 0,
      );
}

/// A full receipt: header, lines, tenders.
class ReceiptDetail {
  const ReceiptDetail({
    required this.summary,
    required this.lines,
    required this.tenders,
  });

  final ReceiptSummary summary;
  final List<ReceiptLine> lines;
  final List<ReceiptTender> tenders;
}

/// Reads settled receipts back from the server for the history screen.
///
/// This is deliberately server-backed rather than local: history is a
/// look-back over everything the venue has taken, across all its terminals,
/// which no single till holds. It therefore needs the network — unlike taking a
/// sale, which never does.
class ReceiptRepository {
  ReceiptRepository({required this.apiBase, required this.office});

  final String apiBase;
  final String office;

  String get _officeParam => 'office=${Uri.encodeComponent(office)}';

  Future<List<ReceiptSummary>> list({DateTime? from, DateTime? to}) async {
    final params = [
      _officeParam,
      if (from != null) 'from=${_date(from)}',
      if (to != null) 'to=${_date(to)}',
    ].join('&');

    final res = await http
        .get(Uri.parse('$apiBase/till/receipts?$params'))
        .timeout(const Duration(seconds: 12));
    if (res.statusCode != 200) {
      throw Exception('Could not load receipts (${res.statusCode}).');
    }
    return (jsonDecode(res.body) as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .map(ReceiptSummary.fromJson)
        .toList();
  }

  Future<ReceiptDetail> detail(String id) async {
    final res = await http
        .get(Uri.parse('$apiBase/till/receipts/$id?$_officeParam'))
        .timeout(const Duration(seconds: 12));
    if (res.statusCode != 200) {
      throw Exception('Could not load the receipt (${res.statusCode}).');
    }

    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return ReceiptDetail(
      summary: ReceiptSummary.fromJson(body['order'] as Map<String, dynamic>),
      lines: (body['lines'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map(ReceiptLine.fromJson)
          .toList(),
      tenders: (body['payments'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map(ReceiptTender.fromJson)
          .toList(),
    );
  }

  static String _date(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}
