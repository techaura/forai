import 'package:flutter/services.dart';

class ClipboardService {
  static Future<void> copyText(String value) {
    return Clipboard.setData(ClipboardData(text: value));
  }
}
