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

/// Two permission cards ("Notification Access" / "Display over other apps"), each with
/// a status indicator and a "Grant" button that deep-links to the relevant Settings screen.
/// The caller is responsible for re-checking status on resume, since these are external
/// Settings screens rather than blocking dialogs.
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
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _PermissionCard(
          title: '알림 접근 권한',
          description: '재생 중인 곡 제목/아티스트를 감지하는 데 필요합니다 (마이크 미사용)',
          granted: status.notificationAccessGranted,
          onGrant: onRequestNotificationAccess,
        ),
        const SizedBox(height: 12),
        _PermissionCard(
          title: '다른 앱 위에 표시',
          description: '가사 플로팅 창을 띄우는 데 필요합니다',
          granted: status.overlayGranted,
          onGrant: onRequestOverlayPermission,
        ),
      ],
    );
  }
}

class _PermissionCard extends StatelessWidget {
  final String title;
  final String description;
  final bool granted;
  final VoidCallback onGrant;

  const _PermissionCard({
    required this.title,
    required this.description,
    required this.granted,
    required this.onGrant,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(
          granted ? Icons.check_circle : Icons.error_outline,
          color: granted ? Colors.green : Colors.orange,
        ),
        title: Text(title),
        subtitle: Text(description),
        trailing: granted ? null : TextButton(onPressed: onGrant, child: const Text('허용')),
      ),
    );
  }
}
