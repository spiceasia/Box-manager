// lib/io/io_web.dart
import 'dart:async';
import 'dart:html' as html;
import 'package:flutter/material.dart';

/// Download raw bytes as a file in the browser.
Future<void> downloadBytes({
  required String filename,
  required List<int> bytes,
  required String mime,
  BuildContext? context, // optional; not used on web but kept for API symmetry
}) async {
  final blob = html.Blob([bytes], mime);
  final url = html.Url.createObjectUrlFromBlob(blob);
  final anchor = html.AnchorElement(href: url)..download = filename;
  anchor.click();
  html.Url.revokeObjectUrl(url);
}

/// Let the user pick a text file and return its contents as a String.
Future<String?> pickTextFile({
  List<String>? acceptMime, // e.g. ['application/json','.json'] or ['text/csv','.csv']
  BuildContext? context,    // optional; not used on web but kept for API symmetry
}) async {
  final input = html.FileUploadInputElement();
  if (acceptMime != null && acceptMime.isNotEmpty) {
    input.accept = acceptMime.join(','); // ".csv,text/csv"
  }
  final completer = Completer<String?>();
  input.onChange.listen((_) async {
    final file = input.files?.first;
    if (file == null) {
      completer.complete(null);
      return;
    }
    final reader = html.FileReader();
    reader.readAsText(file);
    await reader.onLoad.first;
    completer.complete(reader.result as String);
  });
  input.click();
  return completer.future;
}

/// Trigger the browser’s print dialog.
void triggerPrint(BuildContext? context) {
  html.window.print();
}
Future<void> printHtmlDocument(String htmlDoc, {BuildContext? context}) async {
  final blob = html.Blob([htmlDoc], 'text/html');
  final url = html.Url.createObjectUrlFromBlob(blob);
  html.window.open(url, '_blank');
  // Revoke a bit later; some browsers need the URL alive until the tab loads
  Future.delayed(const Duration(seconds: 2), () {
    html.Url.revokeObjectUrl(url);
  });
}
