import 'dart:developer' as developer;
import 'package:url_launcher/url_launcher.dart';

/// Helper service for safely launching external URLs.
class UrlLauncherService {
  UrlLauncherService._();

  /// Attempts to launch a given URL in the external browser.
  static Future<bool> launchLink(String rawUrl) async {
    String formattedUrl = rawUrl.trim();
    if (formattedUrl.isEmpty) return false;

    if (!formattedUrl.startsWith('http://') && !formattedUrl.startsWith('https://')) {
      formattedUrl = 'https://$formattedUrl';
    }

    try {
      final Uri uri = Uri.parse(formattedUrl);
      if (await canLaunchUrl(uri)) {
        return await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        developer.log('Could not launch URL: $formattedUrl');
        return false;
      }
    } catch (e) {
      developer.log('Error launching URL: $e');
      return false;
    }
  }
}
