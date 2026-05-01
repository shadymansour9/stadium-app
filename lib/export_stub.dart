import 'dart:io';

Future<String> saveExcelFile(List<int> bytes, String filename) async {
  try {
    final dir = Directory('/storage/emulated/0/Download');
    if (await dir.exists()) {
      final file = File('${dir.path}/$filename');
      await file.writeAsBytes(bytes);
      return file.path;
    }
  } catch (_) {}
  try {
    final tmp = Directory.systemTemp;
    final file = File('${tmp.path}/$filename');
    await file.writeAsBytes(bytes);
    return file.path;
  } catch (_) {}
  return '';
}
