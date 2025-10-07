class WebUtil {
  void printPage() {}
  void downloadJson(String filename, String content) {}
  Future<String?> pickJson() async => null; // not used on mobile yet
  bool get isWeb => false;
}
final web = WebUtil();
