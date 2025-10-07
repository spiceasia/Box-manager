import 'dart:convert';
import 'dart:async';
import 'dart:html' as html;

class WebUtil {
  void printPage() => html.window.print();

  void downloadJson(String filename, String content) {
    final bytes = utf8.encode(content);
    final blob = html.Blob([bytes], 'application/json');
    final url = html.Url.createObjectUrlFromBlob(blob);
    final a = html.AnchorElement(href: url)..download = filename;
    a.click();
    html.Url.revokeObjectUrl(url);
  }

  Future<String?> pickJson() async {
    final input = html.FileUploadInputElement()..accept = '.json,application/json';
    final completer = Completer<String?>();
    input.onChange.listen((_) async {
      final file = input.files?.first;
      if (file == null) { completer.complete(null); return; }
      final reader = html.FileReader();
      reader.readAsText(file);
      await reader.onLoad.first;
      completer.complete(reader.result as String);
    });
    input.click();
    return completer.future;
  }

  bool get isWeb => true;
}
final web = WebUtil();
