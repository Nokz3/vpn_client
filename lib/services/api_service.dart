import 'dart:convert';
import 'package:http/http.dart' as http;

/// API wrapper for Nokz anon accounts + billing + provisioning
class ApiService {
  final String base; // e.g. https://api-de.nokz.io or https://api-us.nokz.io
  ApiService(this.base);

  // ---- US entitlement endpoint base (central authority) ----
  static const String _entitlementBase = 'https://api-us.nokz.io';

  Future<Map<String, dynamic>> _json(http.Response r) async {
    final ct = (r.headers['content-type'] ?? '').toLowerCase();
    if (ct.contains('application/json')) return jsonDecode(r.body);
    return {'raw': r.body};
  }

  // ---- Auth ----
  Future<AnonCreateResp> anonCreate() async {
    final r = await http.post(Uri.parse('$base/auth/anon/create'));
    if (r.statusCode ~/ 100 == 2) {
      final j = await _json(r);
      return AnonCreateResp.fromJson(j as Map<String, dynamic>);
    }
    throw ApiError('HTTP ${r.statusCode}: ${r.body}');
  }

  /// Restore an existing anonymous account using its account_key.
  /// Server endpoint: POST $base/auth/anon/restore  { "account_key": "<key>" }
  Future<AnonCreateResp> anonRestore(String accountKey) async {
    final r = await http.post(
      Uri.parse('$base/auth/anon/restore'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'account_key': accountKey}),
    );
    if (r.statusCode ~/ 100 == 2) {
      final j = await _json(r);
      return AnonCreateResp.fromJson(j as Map<String, dynamic>);
    }
    throw ApiError('HTTP ${r.statusCode}: ${r.body}');
  }

  Future<Map<String, dynamic>> me(String jwt) async {
    final r = await http.get(
      Uri.parse('$base/auth/me'),
      headers: {'Authorization': 'Bearer $jwt'},
    );
    if (r.statusCode ~/ 100 == 2) return _json(r);
    throw ApiError('HTTP ${r.statusCode}: ${r.body}');
  }

  // ---- Billing ----
  Future<Map<String, dynamic>> redeem(String jwt, String code) async {
    final r = await http.post(
      Uri.parse('$base/billing/redeem'),
      headers: {
        'Authorization': 'Bearer $jwt',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'code': code.trim()}),
    );
    final j = await _json(r);
    if (r.statusCode ~/ 100 == 2) return j;
    throw ApiError(j['detail']?.toString() ?? 'Redeem failed');
  }

  /// Create a NowPayments invoice; returns { invoice_url, order_id, already_active, ... }
  Future<Map<String, dynamic>> pay({
    required String jwt,
    required String plan, // "monthly" | "yearly"
  }) async {
    final r = await http.post(
      Uri.parse('$base/billing/pay'),
      headers: {
        'Authorization': 'Bearer $jwt',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'plan': plan}),
    );
    final j = await _json(r);
    if (r.statusCode ~/ 100 == 2) return j;
    throw ApiError(j['detail']?.toString() ?? 'Payment init failed');
  }

  // ---- Provision via user endpoint ----
  Future<String> userProvision({
    required String jwt,
    required String serverId,
    String? label,
  }) async {
    final r = await http.post(
      Uri.parse('$base/v1/user/provision'),
      headers: {
        'Authorization': 'Bearer $jwt',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'server_id': serverId,
        if (label != null) 'label': label,
      }),
    );

    if (r.statusCode == 402) {
      throw ApiError('Subscription inactive or expired');
    }

    if (r.statusCode ~/ 100 == 2) {
      final ct = (r.headers['content-type'] ?? '').toLowerCase();
      if (ct.contains('application/json')) {
        final j = jsonDecode(r.body);
        final v = (j is Map) ? j['config_ini'] : null;
        if (v is String && v.contains('[Interface]')) return v;
      }
      if (r.body.contains('[Interface]')) return r.body;
      throw ApiError('Provision succeeded, but config was not returned.');
    }

    throw ApiError('HTTP ${r.statusCode}: ${r.body}');
  }

  // ---- Entitlement support (US-centered) ----

  /// Ask the US API to mint an entitlement token for account_key.
  /// IMPORTANT: `usJwt` must be a JWT issued by the US API.
  static Future<String?> mintEntitlement({
    required String usJwt,
    required String accountKey,
  }) async {
    final r = await http.post(
      Uri.parse('$_entitlementBase/auth/anon/entitlement'),
      headers: {
        'Authorization': 'Bearer $usJwt',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'account_key': accountKey}),
    );
    if (r.statusCode ~/ 100 == 2) {
      final j = jsonDecode(r.body);
      final ent = j['entitlement']?.toString();
      return (ent != null && ent.isNotEmpty) ? ent : null;
    }
    return null; // not paid yet or invalid
  }

  /// Provision but include X-Entitlement if you have one (optional).
  Future<String> userProvisionWithEntitlement({
    required String jwt,          // region-scoped JWT (DE/US/etc.)
    required String serverId,
    String? label,
    String? entitlement,          // pass an entitlement if you have it
  }) async {
    final headers = <String, String>{
      'Authorization': 'Bearer $jwt',
      'Content-Type': 'application/json',
    };
    if (entitlement != null && entitlement.isNotEmpty) {
      headers['X-Entitlement'] = entitlement;
    }

    final r = await http.post(
      Uri.parse('$base/v1/user/provision'),
      headers: headers,
      body: jsonEncode({
        'server_id': serverId,
        if (label != null) 'label': label,
      }),
    );

    if (r.statusCode == 402) {
      throw ApiError('Subscription inactive or expired');
    }

    if (r.statusCode ~/ 100 == 2) {
      final ct = (r.headers['content-type'] ?? '').toLowerCase();
      if (ct.contains('application/json')) {
        final j = jsonDecode(r.body);
        final v = (j is Map) ? j['config_ini'] : null;
        if (v is String && v.contains('[Interface]')) return v;
      }
      if (r.body.contains('[Interface]')) return r.body;
      throw ApiError('Provision succeeded, but config was not returned.');
    }

    throw ApiError('HTTP ${r.statusCode}: ${r.body}');
  }
}

class ApiError implements Exception {
  final String message;
  ApiError(this.message);
  @override
  String toString() => message;
}

/// Accept both `jwt` and `access_token` and expose a unified `.jwt` getter.
class AnonCreateResp {
  final String accountKey;
  final String accessToken; // raw token from API
  final String tokenType;   // usually "bearer"

  AnonCreateResp({
    required this.accountKey,
    required this.accessToken,
    required this.tokenType,
  });

  /// Unified name used by UI code
  String get jwt => accessToken;

  /// Convenience if you ever need the full Authorization header
  String get authorizationHeader =>
      '${(tokenType.isEmpty ? 'Bearer' : tokenType).toString().replaceFirstMapped(RegExp(r"^[a-z]"), (m) => m[0]!.toUpperCase())} $accessToken';

  factory AnonCreateResp.fromJson(Map<String, dynamic> j) {
    // Accept various field names from different server versions
    final token = (j['jwt'] ??
            j['access_token'] ??
            j['token'] ??
            j['value'] ??
            '')
        .toString();

    if (token.isEmpty) {
      throw ApiError('anon/create did not return a token');
    }

    return AnonCreateResp(
      accountKey: j['account_key']?.toString() ?? '',
      accessToken: token,
      tokenType: (j['token_type']?.toString().isNotEmpty == true)
          ? j['token_type'].toString()
          : 'bearer',
    );
  }
}
