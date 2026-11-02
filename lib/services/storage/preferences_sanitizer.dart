import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../utils/app_storage.dart';

/// Defensive self-healing for file-backed SharedPreferences (Windows/Linux).
///
/// On desktop platforms where shared_preferences persists state into a JSON
/// file, an abrupt OS shutdown, power loss, or crash during a write can leave
/// `shared_preferences.json` zeroed-out (all null bytes `\x00`) or malformed.
/// When that happens, `SharedPreferences.getInstance` throws a [FormatException]
/// on startup before any UI can render.
///
/// This sanitizer inspects the file before SharedPreferences initializes,
/// creates a dated `.bak` of any corrupt payload for safety, and restores
/// a minimal valid JSON object (`{}`) so the app boots cleanly.
abstract final class PreferencesSanitizer {
  static const String fileName = 'shared_preferences.json';

  /// Examines `shared_preferences.json` in [AppStorage.support] and repairs it
  /// if it is empty, null-byte padded, or malformed JSON.
  static Future<bool> repairIfCorrupted({Directory? supportDirectory}) async {
    if (kIsWeb) return false;
    try {
      final support = supportDirectory ?? await AppStorage.support();
      final file = File(p.join(support.path, fileName));
      if (!await file.exists()) return false;

      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) {
        await file.writeAsString('{}', flush: true);
        return true;
      }

      var isCorrupted = false;
      try {
        // Fast scan: if the first 16 bytes are all null, it's definitely corrupt NTFS zero-fill.
        if (bytes.length >= 16 && bytes.take(16).every((b) => b == 0)) {
          isCorrupted = true;
        } else {
          final decoded = jsonDecode(utf8.decode(bytes));
          if (decoded is! Map) {
            isCorrupted = true;
          }
        }
      } catch (_) {
        isCorrupted = true;
      }

      if (!isCorrupted) return false;

      // Preserve the corrupted bytes in a timestamped backup before resetting.
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final backup = File('${file.path}.corrupt-$timestamp.bak');
      try {
        await file.copy(backup.path);
      } catch (_) {}

      await file.writeAsString('{}', flush: true);
      debugPrint(
        'PreferencesSanitizer: repaired corrupted $fileName '
        '(backed up to ${backup.path})',
      );
      return true;
    } catch (error) {
      // Self-healing must never throw or prevent application startup.
      debugPrint('PreferencesSanitizer: check failed: $error');
      return false;
    }
  }
}
