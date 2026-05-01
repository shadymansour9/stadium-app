import 'dart:js_interop';
import 'dart:typed_data';
import 'package:web/web.dart' as web;

Future<String> saveExcelFile(List<int> bytes, String filename) async {
  final uint8 = Uint8List.fromList(bytes).toJS;
  final blob = web.Blob(
    [uint8].toJS,
    web.BlobPropertyBag(
      type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    ),
  );
  final url = web.URL.createObjectURL(blob);
  final anchor = web.document.createElement('a') as web.HTMLAnchorElement
    ..href = url
    ..download = filename;
  web.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  web.URL.revokeObjectURL(url);
  return 'downloaded';
}
