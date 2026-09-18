import 'package:flutter/material.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';

import '../../core/platform/notification_bridge.dart';

/// Status of the two permissions this app needs that Android only grants through a
/// system Settings screen, never a normal runtime dialog.
class PermissionStatus {
  final bool notificationAccessGranted;
  final bool overlayGranted;

  const PermissionStatus({required this.notificationAccessGranted, required this.overlayGranted});

  bool get allGranted => notificationAccessGranted && overlayGranted;

  static Future<PermissionStatus> current() async {
    final results = await Future.wait([
      NotificationBridge.isNotificationAccessGranted(),
      FlutterOverlayWindow.isPermissionGranted(),
    ]);
    return PermissionStatus(
      notificationAccessGranted: results[0],
      overlayGranted: results[1],
    );
  }
}

/// Two permission indicators ("Notification Access" / "Display over other apps"). Each one is
/// a full card (status, description, a "Grant" button deep-linking to the relevant Settings
/// screen) only while it still needs the user's action — the description text and button only
/// matter during onboarding, so once granted it collapses to a single compact line, and once
/// *both* are granted the whole thing collapses to one line total. Since this sits at the top
/// of the home screen above the actually-useful "now playing"/"recent songs" content, and both
/// permissions are normally granted once after setup and never touched again, the common case
/// (already granted) is the one worth optimizing for. The caller is responsible for re-checking
/// status on resume, since these are external Settings screens rather than blocking dialogs.
class PermissionOnboarding extends StatelessWidget {
  final PermissionStatus status;
  final VoidCallback onRequestNotificationAccess;
  final VoidCallback onRequestOverlayPermission;

  const PermissionOnboarding({
    super.key,
    required this.status,
    required this.onRequestNotificationAccess,
    required this.onRequestOverlayPermission,
  });

  @override
  Widget build(BuildContext context) {
    if (status.allGranted) {
      return const _CompactGrantedRow(label: '알림 접근 · 오버레이 권한 모두 허용됨');
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _PermissionRow(
          title: '알림 접근 권한',
          description: '재생 중인 곡 제목/아티스트를 감지하는 데 필요합니다 (마이크 미사용)',
          granted: status.notificationAccessGranted,
          onGrant: onRequestNotificationAccess,
        ),
        const SizedBox(height: 6),
        _PermissionRow(
          title: '다른 앱 위에 표시',
          description: '가사 플로팅 창을 띄우는 데 필요합니다',
          granted: status.overlayGranted,
          onGrant: onRequestOverlayPermission,
        ),
      ],
    );
  }
}

class _CompactGrantedRow extends StatelessWidget {
  const _CompactGrantedRow({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.check_circle, color: Colors.green, size: 16),
        const SizedBox(width: 6),
        Expanded(
          child: Text(label, style: Theme.of(context).textTheme.bodySmall),
        ),
      ],
    );
  }
}

class _PermissionRow extends StatelessWidget {
  final String title;
  final String description;
  final bool granted;
  final VoidCallback onGrant;

  const _PermissionRow({
    required this.title,
    required this.description,
    required this.granted,
    required this.onGrant,
  });

  @override
  Widget build(BuildContext context) {
    // Already granted but its sibling still isn't — no longer actionable, so this doesn't
    // need the description or a card at all, just enough to say "this one's done".
    if (granted) {
      return _CompactGrantedRow(label: title);
    }
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        leading: const Icon(Icons.error_outline, color: Colors.orange, size: 20),
        title: Text(title, style: Theme.of(context).textTheme.bodyMedium),
        subtitle: Text(description, style: Theme.of(context).textTheme.bodySmall),
        trailing: TextButton(onPressed: onGrant, child: const Text('허용')),
      ),
    );
  }
}
