import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Stores the user's own DeepL API key (see the optional higher-quality translation tier in
/// SettingsPage) via the platform's hardware-backed secure storage — Android Keystore
/// (AES-GCM with RSA-OAEP key wrapping, this package's own default), iOS Keychain — rather
/// than a plain Hive box, so the raw key can't be read straight out of the app's data
/// directory even on a rooted device. This is a user-supplied credential for the user's own
/// account, not a shared app secret, so the only thing at stake here is keeping it from
/// leaking off-device or into logs/backups, not defending against the device's own owner.
class TranslationKeyStorage {
  TranslationKeyStorage._();

  static const _storage = FlutterSecureStorage();
  static const _deeplKeyName = 'deepl_api_key';

  static Future<void> saveDeepLKey(String key) =>
      _storage.write(key: _deeplKeyName, value: key.trim());

  static Future<String?> getDeepLKey() async {
    final key = await _storage.read(key: _deeplKeyName);
    return (key != null && key.trim().isNotEmpty) ? key.trim() : null;
  }

  static Future<void> clearDeepLKey() => _storage.delete(key: _deeplKeyName);
}
