// lib/io/io_stub.dart
import 'package:flutter/material.dart';

/// Fallback: no real download on mobile/desktop in this stub.
/// You can later replace with platform file pickers or share sheets.
Future<void> downloadBytes({
  required String filename,
  required List<int> bytes,
  required String mime,
  BuildContext? context,
}) async {
  if (context != null) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Download "$filename" is only supported on Web right now.')),
    );
  }
}

/// Fallback: no real picker in this stub. Return null and show a note.
Future<String?> pickTextFile({
  List<String>? acceptMime,
  BuildContext? context,
}) async {
  if (context != null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('File import is only supported on Web right now.')),
    );
  }
  return null;
}

/// No-op print on mobile/desktop stub.
void triggerPrint(BuildContext? context) {
  if (context != null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Printing is only supported on Web right now.')),
    );
  }
}
Future<void> printHtmlDocument(String htmlDoc, {BuildContext? context}) async {
  if (context != null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Printing a web page is only supported on Web for now.')),
    );
  }
}
