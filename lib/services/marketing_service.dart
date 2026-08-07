import 'dart:async';
import 'dart:developer';

import 'package:app_tracking_transparency/app_tracking_transparency.dart';
import 'package:chottu_link/chottu_link.dart';
import 'package:facebook_app_events/facebook_app_events.dart';
import 'package:short_navigation/short_navigation.dart';

/// Central marketing + attribution layer for Lavive.
///
/// Responsibilities:
///  - Facebook App Events (CompleteRegistration, Purchase) on the new app id.
///  - iOS App Tracking Transparency prompt + advertiser-tracking sync.
///  - ChottuLink init + incoming/deferred deep-link routing.
///
/// Facebook app install/activation events are auto-logged by the native SDK,
/// which now reads the new app id from strings.xml (Android) and Info.plist (iOS).
class MarketingService {
  MarketingService._();
  static final MarketingService instance = MarketingService._();

  // ---- ChottuLink config ----
  // Filled from ChottuLink dashboard. apiKey = Mobile SDK Integration Key (NOT the Rest API key).
  // apiKey: ChottuLink dashboard > API Keys (mobile SDK key).
  // domain: your branded subdomain, e.g. "lavive.chottu.link".
  static const String _chottuLinkApiKey = 'c_app_Qun1x4xBRrBzCSPdMf70gzvlf1anCuZ2';
  static const String chottuLinkDomain = 'lavive.chottu.link';
  static const List<String> deepLinkDomains = [
    'lavive.chottu.link',
    'go.lavive.app',
    'offer.lavive.app',
    'shop.lavive.app',
    'box.lavive.app',
  ];

  final FacebookAppEvents _fb = FacebookAppEvents();
  StreamSubscription<dynamic>? _linkSub;
  bool _initialised = false;

  /// Call once at startup, after WidgetsFlutterBinding.ensureInitialized().
  Future<void> init() async {
    if (_initialised) return;
    _initialised = true;

    // Initialise ChottuLink so deferred links resolve on first launch.
    try {
      await ChottuLink.init(apiKey: _chottuLinkApiKey);
    } catch (e) {
      log('ChottuLink init failed: $e');
    }

    // Listen for incoming + deferred deep links.
    try {
      _linkSub = ChottuLink.onLinkReceived.listen((link) {
        log('ChottuLink received: $link');
        _routeDeepLink(link?.toString());
      });
    } catch (e) {
      log('ChottuLink listener failed: $e');
    }

    // iOS App Tracking Transparency (no-op on Android), then sync to FB SDK.
    await _requestTrackingAndSync();
  }

  Future<void> _requestTrackingAndSync() async {
    try {
      var status = await AppTrackingTransparency.trackingAuthorizationStatus;
      if (status == TrackingStatus.notDetermined) {
        status = await AppTrackingTransparency.requestTrackingAuthorization();
      }
      await _fb.setAdvertiserTracking(
        enabled: status == TrackingStatus.authorized,
      );
    } catch (e) {
      log('ATT request failed: $e');
    }
  }

  /// Parses a Lavive deep link and routes using the app's existing named routes.
  /// Handles both the custom scheme (lavive://product/123) and ChottuLink https
  /// links (https://<domain>/product/123). Supported: product, category, offer.
  void _routeDeepLink(String? rawLink) {
    if (rawLink == null || rawLink.isEmpty) return;

    Uri uri;
    try {
      uri = Uri.parse(rawLink);
    } catch (_) {
      return;
    }

    final seg = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    String type;
    String? id;

    if (uri.scheme == 'lavive') {
      // lavive://product/123  -> host carries the type, first segment is the id.
      type = uri.host;
      id = seg.isNotEmpty ? seg[0] : null;
    } else {
      // https://<domain>/product/123  -> first segment is the type, second is the id.
      type = seg.isNotEmpty ? seg[0] : '';
      id = seg.length >= 2 ? seg[1] : null;
    }

    switch (type) {
      case 'product':
        if (id != null) {
          _navigate(() => Go.toName('product_details_page',
              arguments: int.tryParse(id!) ?? id));
        }
        break;
      case 'category':
        if (id != null) {
          _navigate(() => Go.toName('sub_categories_page',
              arguments: int.tryParse(id!) ?? id));
        }
        break;
      case 'offer':
        // TODO(owner): point to a dedicated first-order offer screen when one exists.
        _navigate(() => Go.toName('root_view'));
        break;
      default:
        _navigate(() => Go.toName('root_view'));
    }
  }

  /// Runs [action] once the global navigator is mounted. A deferred link can
  /// arrive during cold start before the navigator exists, so we retry briefly.
  void _navigate(void Function() action, [int tries = 0]) {
    if (Go.navigatorKey.currentState != null) {
      try {
        action();
      } catch (e) {
        log('Deep link navigation failed: $e');
      }
    } else if (tries < 20) {
      Future.delayed(const Duration(milliseconds: 300),
          () => _navigate(action, tries + 1));
    }
  }

  // ---- Facebook standard events ----

  /// Log when a user finishes registration.
  Future<void> logCompleteRegistration({String method = 'app'}) async {
    try {
      await _fb.logCompletedRegistration(registrationMethod: method);
    } catch (e) {
      log('FB CompleteRegistration failed: $e');
    }
  }

  /// Log a completed order. [amount] is the order total, currency defaults to EGP.
  Future<void> logPurchase(double amount, {String currency = 'EGP'}) async {
    try {
      await _fb.logPurchase(amount: amount, currency: currency);
    } catch (e) {
      log('FB Purchase failed: $e');
    }
  }

  void dispose() {
    _linkSub?.cancel();
  }
}
