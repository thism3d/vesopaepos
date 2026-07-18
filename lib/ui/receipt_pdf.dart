import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../data/receipt_repository.dart';

String _money(int minor) =>
    NumberFormat.currency(locale: 'en_GB', symbol: '£').format(minor / 100);

final _stamp = DateFormat('dd/MM/yyyy HH:mm');

/// Builds a receipt as an 80mm-wide PDF — the same width as the thermal roll,
/// so the on-screen preview matches what prints. Used for both "view PDF" and
/// "reprint".
Future<Uint8List> buildReceiptPdf(
  ReceiptDetail receipt, {
  required String venueName,
}) async {
  final doc = pw.Document();
  final r = receipt;

  // 80mm roll. Height grows to fit the content.
  final format = PdfPageFormat(
    80 * PdfPageFormat.mm,
    double.infinity,
    marginAll: 6 * PdfPageFormat.mm,
  );

  pw.Widget row(String left, String right, {bool bold = false}) => pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(left,
              style: pw.TextStyle(
                  fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal)),
          pw.Text(right,
              style: pw.TextStyle(
                  fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal)),
        ],
      );

  final paid = r.tenders.fold<int>(0, (s, t) => s + t.amountMinor);
  final change = paid - r.summary.totalMinor;

  doc.addPage(
    pw.Page(
      pageFormat: format,
      build: (context) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          pw.Center(
            child: pw.Text(
              venueName,
              style:
                  pw.TextStyle(fontSize: 15, fontWeight: pw.FontWeight.bold),
            ),
          ),
          pw.SizedBox(height: 6),
          pw.Center(child: pw.Text(_stamp.format(r.summary.closedAt))),
          if (r.summary.tableNumber != null)
            pw.Center(child: pw.Text('Table ${r.summary.tableNumber}')),
          pw.Divider(),

          for (final line in r.lines)
            row(
              '${line.quantity.toStringAsFixed(line.quantity % 1 == 0 ? 0 : 2)}x ${line.name}',
              _money((line.unitPriceMinor * line.quantity).round()),
            ),

          pw.Divider(),
          if (r.summary.discountMinor > 0)
            row('Discount', '-${_money(r.summary.discountMinor)}'),
          row('VAT', _money(r.summary.taxMinor)),
          pw.SizedBox(height: 2),
          row('TOTAL', _money(r.summary.totalMinor), bold: true),
          pw.Divider(),

          for (final tender in r.tenders)
            row(tender.method.toUpperCase(), _money(tender.amountMinor)),
          if (change > 0) row('CHANGE', _money(change)),

          pw.SizedBox(height: 10),
          pw.Center(child: pw.Text('Thank you', style: pw.TextStyle(fontSize: 11))),
          pw.SizedBox(height: 4),
          pw.Center(
            child: pw.Text(
              r.summary.id.substring(0, 8),
              style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600),
            ),
          ),
        ],
      ),
    ),
  );

  return doc.save();
}
