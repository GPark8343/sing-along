import 'package:flutter/material.dart';

import '../../data/api/deepl_client.dart';
import '../../data/secure/translation_key_storage.dart';
import '../theme/metal_theme.dart';

/// Lets the user optionally supply their own DeepL API key for a higher-quality translation
/// tier — the on-device ML Kit tier stays as the always-available default (see
/// LyricsRepository._buildResult), this is purely an opt-in upgrade for whoever wants it and
/// is willing to get their own key. Only reachable at all in builds compiled with
/// `--dart-define=ENABLE_CUSTOM_TRANSLATION_KEY=true` — see main.dart's home screen for the
/// entry point this is gated behind.
class TranslationSettingsPage extends StatefulWidget {
  const TranslationSettingsPage({super.key});

  @override
  State<TranslationSettingsPage> createState() => _TranslationSettingsPageState();
}

enum _KeyStatus { none, saved, testing, valid, invalid }

class _TranslationSettingsPageState extends State<TranslationSettingsPage> {
  final _controller = TextEditingController();
  final _deepLClient = DeepLClient();
  bool _obscure = true;
  _KeyStatus _status = _KeyStatus.none;

  @override
  void initState() {
    super.initState();
    _loadExistingKey();
  }

  Future<void> _loadExistingKey() async {
    final key = await TranslationKeyStorage.getDeepLKey();
    if (!mounted) return;
    setState(() {
      if (key != null) {
        _controller.text = key;
        _status = _KeyStatus.saved;
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _test() async {
    final key = _controller.text.trim();
    if (key.isEmpty) return;
    setState(() => _status = _KeyStatus.testing);
    final valid = await _deepLClient.isKeyValid(key);
    if (!mounted) return;
    setState(() => _status = valid ? _KeyStatus.valid : _KeyStatus.invalid);
  }

  Future<void> _save() async {
    final key = _controller.text.trim();
    if (key.isEmpty) {
      await _clear();
      return;
    }
    await TranslationKeyStorage.saveDeepLKey(key);
    if (!mounted) return;
    setState(() => _status = _KeyStatus.saved);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('DeepL 키를 저장했어요')),
    );
  }

  Future<void> _clear() async {
    await TranslationKeyStorage.clearDeepLKey();
    if (!mounted) return;
    setState(() {
      _controller.clear();
      _status = _KeyStatus.none;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('DeepL 키를 삭제했어요 — 다시 온디바이스 번역만 사용해요')),
    );
  }

  String get _statusLabel {
    switch (_status) {
      case _KeyStatus.none:
        return '설정 안 됨 — 온디바이스 번역(ML Kit)만 사용';
      case _KeyStatus.saved:
        return '저장됨';
      case _KeyStatus.testing:
        return '연결 테스트 중…';
      case _KeyStatus.valid:
        return '연결 테스트 · 성공';
      case _KeyStatus.invalid:
        return '연결 테스트 · 실패 (키를 다시 확인해주세요)';
    }
  }

  Color get _statusColor {
    switch (_status) {
      case _KeyStatus.valid:
        return MetalTheme.steelBright;
      case _KeyStatus.invalid:
        return Colors.redAccent;
      default:
        return MetalTheme.textMuted;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('번역 설정')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            MetalCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'DeepL API 키 (선택)',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '기본으로는 기기 안에서 무료로 처리되는 번역(ML Kit)을 써요. '
                    '더 자연스러운 번역을 원하면 본인의 DeepL API 키를 넣어주세요 — '
                    '키는 이 기기의 보안 저장소에만 저장되고, 오직 DeepL 서버로만 전송돼요.',
                    style: TextStyle(color: MetalTheme.textSecondary),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _controller,
                    obscureText: _obscure,
                    style: const TextStyle(color: MetalTheme.textPrimary),
                    decoration: InputDecoration(
                      hintText: 'DeepL API 키를 붙여넣으세요',
                      hintStyle: const TextStyle(color: MetalTheme.textMuted),
                      filled: true,
                      fillColor: MetalTheme.surfaceDark,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: MetalTheme.edgeHighlight),
                      ),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                          color: MetalTheme.steel,
                        ),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                    onChanged: (_) {
                      if (_status != _KeyStatus.none) {
                        setState(() => _status = _KeyStatus.none);
                      }
                    },
                  ),
                  const SizedBox(height: 8),
                  Text(_statusLabel, style: TextStyle(color: _statusColor)),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: MetalButton(
                          label: '연결 테스트',
                          icon: Icons.wifi_tethering,
                          onPressed: _status == _KeyStatus.testing ? null : _test,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: MetalButton(
                          label: '저장',
                          icon: Icons.check,
                          onPressed: _save,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  MetalButton(
                    label: '키 삭제',
                    icon: Icons.delete_outline,
                    onPressed: _clear,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
