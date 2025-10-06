import 'dart:ui';

import 'package:flutter/foundation.dart' show kIsWeb; // web-safe blur
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/api_service.dart';
import 'pay_page.dart'; // Account / Subscribe page

const accent = Color(0xFF37F689);
const bgTop = Color(0xFF0B0F0B);
const bgBottom = Color(0xFF0B130E);

// API bases
const deBase = 'https://api-de.nokz.io';
const usBase = 'https://api-us.nokz.io';

class ServerItem {
  final String id;
  final String name;
  final String base;
  final String pingHint;
  const ServerItem(this.id, this.name, this.base, this.pingHint);
}

const servers = <ServerItem>[
  ServerItem('de-fra-1', 'Germany • Frankfurt', deBase, '~35ms'),
  ServerItem('us-nyc-1', 'USA • New York', usBase, '~95ms'),
];

class ServerListPage extends StatefulWidget {
  const ServerListPage({super.key});
  @override
  State<ServerListPage> createState() => _ServerListPageState();
}

class _ServerListPageState extends State<ServerListPage> {
  bool _busy = false;
  String? _error;
  String? _lastConfig;
  String? _activeServer;

  // per-region JWT cache (so US calls don’t 401)
  final Map<String, String> _jwtByBase = {};

  @override
  void initState() {
    super.initState();
    // Ensure there’s a DE token ready (your PayPage often reuses it)
    _ensureJwtForBase(deBase);
  }

  String _jwtKeyForBase(String base) => 'jwt_${Uri.parse(base).host}';
  String _akKeyForBase(String base)  => 'account_key_${Uri.parse(base).host}';

  // Create or fetch an anon JWT that’s valid for the given API base
  Future<String> _ensureJwtForBase(String base) async {
    final cached = _jwtByBase[base];
    if (cached != null && cached.isNotEmpty) return cached;

    final sp = await SharedPreferences.getInstance();
    final stored = sp.getString(_jwtKeyForBase(base));
    if (stored != null && stored.isNotEmpty) {
      _jwtByBase[base] = stored;
      return stored;
    }

    // Mint anon for this base and persist BOTH jwt and account_key
    final api = ApiService(base);
    final resp = await api.anonCreate();

    final token = resp.accessToken;
    final accountKey = resp.accountKey;

    _jwtByBase[base] = token;
    await sp.setString(_jwtKeyForBase(base), token);

    // Save per-base account key and a generic fallback if one isn't set yet
    await sp.setString(_akKeyForBase(base), accountKey);
    sp.getString('account_key') ?? await sp.setString('account_key', accountKey);

    // Keep a legacy key for older code that might read 'jwt'
    if (base == deBase) await sp.setString('jwt', token);

    return token;
  }

  Future<void> _openPayPage() async {
    final sp = await SharedPreferences.getInstance();
    final jwt = sp.getString(_jwtKeyForBase(deBase)) ??
        sp.getString('jwt') ??
        await _ensureJwtForBase(deBase);
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PayPage(
          jwt: jwt,
          initialRegionBase: deBase,
        ),
      ),
    );
  }

  Future<void> _provision(ServerItem s) async {
    setState(() {
      _busy = true;
      _error = null;
      _lastConfig = null;
      _activeServer = s.name;
    });
    try {
      final sp = await SharedPreferences.getInstance();

      // Region-scoped JWT (e.g., DE when provisioning DE)
      final regionJwt = await _ensureJwtForBase(s.base);

      // US-scoped JWT (needed to mint entitlement on US)
      final usJwt = await _ensureJwtForBase(usBase);

      // Use the US account key (must match the US JWT subject)
      final usAkKey = _akKeyForBase(usBase);
      final accountKeyUS =
          sp.getString(usAkKey) ?? sp.getString('account_key') ?? '';

      // Ask US to mint an entitlement if we have the US account_key
      String? entitlement;
      if (accountKeyUS.isNotEmpty) {
        entitlement = await ApiService.mintEntitlement(
          usJwt: usJwt,
          accountKey: accountKeyUS,
        );
      }

      final api = ApiService(s.base);
      final cfg = await api.userProvisionWithEntitlement(
        jwt: regionJwt,
        serverId: s.id,
        label: 'nokz-${DateTime.now().millisecondsSinceEpoch}',
        entitlement: entitlement, // may be null if not paid yet
      );

      setState(() => _lastConfig = cfg);
      if (!mounted) return;
      _showQrSheet(context, 'Config – ${s.name}', cfg);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [bgTop, bgBottom],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Column(
              children: [
                // ---- tiny account icon, top-right ----
                Align(
                  alignment: Alignment.topRight,
                  child: IconButton(
                    tooltip: 'Account / Subscribe',
                    icon: const Icon(Icons.account_circle_outlined, color: Colors.white70),
                    onPressed: _openPayPage,
                  ),
                ),

                // ---- centered header ----
                Image.asset(
                  'assets/images/logo.png',
                  height: 64,
                  errorBuilder: (_, __, ___) => const Icon(Icons.shield, color: accent, size: 64),
                ),
                const SizedBox(height: 10),
                const Text(
                  'NOKZ VPN',
                  style: TextStyle(
                    color: accent,
                    fontSize: 36,
                    letterSpacing: 6,
                    fontWeight: FontWeight.w700,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 6),
                const Text('No logs • 100% privacy', style: TextStyle(color: Colors.white70, letterSpacing: 1.2)),
                const SizedBox(height: 24),

                if (_error != null) ...[
                  Text(_error!, style: const TextStyle(color: Colors.redAccent)),
                  const SizedBox(height: 12),
                ],

                for (final s in servers)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Card(
                      color: const Color(0x1AFFFFFF),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        title: Text(
                          s.name,
                          style: const TextStyle(
                            color: accent,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1,
                          ),
                        ),
                        subtitle: Text(
                          '${Uri.parse(s.base).host} • ${s.pingHint}',
                          style: const TextStyle(color: Colors.white70),
                        ),
                        trailing: _busy && _activeServer == s.name
                            ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
                            : IconButton(
                                tooltip: 'Provision & Show QR',
                                icon: const Icon(Icons.qr_code_2_rounded, color: Colors.white70),
                                onPressed: _busy ? null : () => _provision(s),
                              ),
                      ),
                    ),
                  ),

                if (_lastConfig != null) ...[
                  const SizedBox(height: 18),
                  _sectionTitle('Config preview'),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(8)),
                    child: SelectableText(_lastConfig!, style: const TextStyle(fontFamily: 'monospace')),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _sectionTitle(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            t.toUpperCase(),
            style: const TextStyle(
              color: accent,
              fontSize: 14,
              letterSpacing: 2,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      );

  void _showQrSheet(BuildContext context, String title, String configText) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF111511),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) {
        final content = Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              height: 4,
              width: 56,
              decoration: BoxDecoration(color: Colors.white12, borderRadius: BorderRadius.circular(99)),
            ),
            const SizedBox(height: 14),
            Text(
              title,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, letterSpacing: 1.2, color: Colors.white),
            ),
            const SizedBox(height: 12),
            Card(
              elevation: 6,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: SizedBox(
                  width: 280,
                  height: 280,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: ColoredBox(
                      color: Colors.white,
                      child: Center(
                        child: QrImageView(
                          data: configText,
                          gapless: true,
                          errorCorrectionLevel: QrErrorCorrectLevel.L,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                ElevatedButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: configText));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Config copied to clipboard')),
                    );
                  },
                  icon: const Icon(Icons.copy),
                  label: const Text('Copy config'),
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  onPressed: () => showDialog(
                    context: context,
                    builder: (_) => AlertDialog(
                      title: const Text('WireGuard Config'),
                      content: SingleChildScrollView(
                        child: SelectableText(
                          configText,
                          style: const TextStyle(fontFamily: 'monospace'),
                        ),
                      ),
                      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
                    ),
                  ),
                  icon: const Icon(Icons.description_outlined),
                  label: const Text('Preview'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Padding(
              padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
              child: const SizedBox.shrink(),
            ),
          ],
        );

        if (kIsWeb) {
          return Padding(padding: const EdgeInsets.fromLTRB(16, 14, 16, 24), child: content);
        } else {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
                child: content,
              ),
            ),
          );
        }
      },
    );
  }
}
