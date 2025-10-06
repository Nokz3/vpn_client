import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData; // for copy
import 'package:shared_preferences/shared_preferences.dart';          // save/load keys
import 'package:url_launcher/url_launcher.dart';
import '../services/api_service.dart';

const accent = Color(0xFF37F689);

// Centralize billing on one API (US). Change if you prefer DE.
const String billingBase = 'https://api-us.nokz.io';

// Regions we consider for global status
const String deBase = 'https://api-de.nokz.io';
const String usBase = 'https://api-us.nokz.io';

class PayPage extends StatefulWidget {
  final String jwt;                 // JWT from wherever you came from
  final String initialRegionBase;   // kept for compatibility

  const PayPage({
    super.key,
    required this.jwt,
    required this.initialRegionBase,
  });

  @override
  State<PayPage> createState() => _PayPageState();
}

class _PayPageState extends State<PayPage> {
  bool _busy = false;
  String? _error;

  Map<String, dynamic>? _meDE;
  Map<String, dynamic>? _meUS;

  // We’ll surface an account key so users can restore on other devices.
  String? _accountKeyUS;
  String? _accountKeyDE;

  String _jwtKeyForBase(String base) => 'jwt_${Uri.parse(base).host}';
  String _akKeyForBase(String base)  => 'account_key_${Uri.parse(base).host}';

  @override
  void initState() {
    super.initState();
    _loadAccountKeys();
    _refreshAllStatus();
  }

  Future<void> _loadAccountKeys() async {
    final sp = await SharedPreferences.getInstance();
    _accountKeyUS = sp.getString(_akKeyForBase(usBase));
    _accountKeyDE = sp.getString(_akKeyForBase(deBase));
    if (mounted) setState(() {});
  }

  bool _isActive(Map<String, dynamic>? me) {
    if (me == null) return false;
    final plan = (me['plan'] ?? '').toString().toLowerCase();
    final active = me['subscription_active'] == true;
    return active || plan == 'paid';
  }

  bool get _activeGlobal => _isActive(_meDE) || _isActive(_meUS);

  /// Reuse a JWT for the region if present; otherwise mint anon and persist
  Future<String> _getOrCreateJwt(ApiService api, String base) async {
    final sp = await SharedPreferences.getInstance();

    // Reuse saved JWT for this base
    final saved = sp.getString(_jwtKeyForBase(base));
    if (saved != null && saved.isNotEmpty) return saved;

    // If we navigated from the same base, reuse the incoming token
    if (widget.initialRegionBase == base && widget.jwt.isNotEmpty) {
      await sp.setString(_jwtKeyForBase(base), widget.jwt);
      return widget.jwt;
    }

    // Else mint anon for that base and save both jwt + account_key
    final anon = await api.anonCreate();
    await sp.setString(_jwtKeyForBase(base), anon.accessToken);
    await sp.setString(_akKeyForBase(base), anon.accountKey);
    // mirror-save so other pages (ServerList) can pick it up
    await sp.setString('account_key', anon.accountKey);

    await _loadAccountKeys(); // refresh displayed keys
    return anon.accessToken;
  }

  Future<void> _refreshAllStatus() async {
    setState(() => _error = null);
    try {
      final apiDE = ApiService(deBase);
      final apiUS = ApiService(usBase);

      Future<Map<String, dynamic>?> _tryMe(ApiService api, String base) async {
        try {
          final jwtToUse = await _getOrCreateJwt(api, base);
          return await api.me(jwtToUse);
        } catch (_) {
          return null; // ignore region errors so UI stays responsive
        }
      }

      final meDE = await _tryMe(apiDE, deBase);
      final meUS = await _tryMe(apiUS, usBase);

      setState(() {
        _meDE = meDE;
        _meUS = meUS;
      });
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  Future<void> _startPayment(String plan) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // Always bill on the centralized billingBase (US here).
      final billingApi = ApiService(billingBase);
      final sp = await SharedPreferences.getInstance();

      // Reuse existing US JWT if we have it; otherwise mint anon and SAVE it.
      String jwtUS = sp.getString(_jwtKeyForBase(usBase)) ?? '';
      if (jwtUS.isEmpty) {
        final anon = await billingApi.anonCreate();
        jwtUS = anon.accessToken;
        await sp.setString(_jwtKeyForBase(usBase), anon.accessToken);
        await sp.setString(_akKeyForBase(usBase), anon.accountKey);
        // mirror-save (global)
        await sp.setString('account_key', anon.accountKey);

        await _loadAccountKeys();
      }

      final r = await billingApi.pay(jwt: jwtUS, plan: plan);

      final raw = r['invoice_url'] ?? r['link'];
      if (raw == null || raw.toString().isEmpty) {
        throw ApiError('No payment URL returned');
      }
      final uri = Uri.parse(raw.toString());
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok) throw ApiError('Could not open payment URL');
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _busy = false);
    }
  }

  // ------- NEW: restore flow -------
  Future<void> _restoreAccountDialog() async {
    final controller = TextEditingController();
    final key = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Restore account'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: 'Paste your Account key (NOKZ-...)'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('Restore')),
        ],
      ),
    );
    if (key == null || key.isEmpty) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // Restore against billing region (US)
      final apiUS = ApiService(usBase);
      final resp = await apiUS.anonRestore(key); // requires backend route

      final sp = await SharedPreferences.getInstance();
      await sp.setString(_jwtKeyForBase(usBase), resp.accessToken);
      await sp.setString(_akKeyForBase(usBase), resp.accountKey);
      // mirror-save (global)
      await sp.setString('account_key', resp.accountKey);

      await _loadAccountKeys();
      await _refreshAllStatus();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Account restored on this device')),
      );
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _busy = false);
    }
  }
  // ------- end restore flow -------

  @override
  Widget build(BuildContext context) {
    final statusText  = _activeGlobal ? 'Status: ACTIVE (global)' : 'Status: INACTIVE';
    final statusColor = _activeGlobal ? accent : Colors.orangeAccent;

    // Prefer showing the US account key (billing region), else DE, else none
    final accountKey = _accountKeyUS ?? _accountKeyDE;

    return Scaffold(
      appBar: AppBar(title: const Text('Subscribe')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            if (_error != null) ...[
              Text(_error!, style: const TextStyle(color: Colors.redAccent)),
              const SizedBox(height: 8),
            ],

            // Header row
            Row(
              children: [
                const Text('Subscription', style: TextStyle(color: Colors.white70)),
                const Spacer(),
                Text(statusText, style: TextStyle(color: statusColor, fontWeight: FontWeight.w700)),
              ],
            ),

            // Account key (for restore on another device)
            if (accountKey != null) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: SelectableText(
                      'Account key: $accountKey',
                      style: const TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Copy account key',
                    icon: const Icon(Icons.copy, size: 18),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: accountKey));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Account key copied')),
                      );
                    },
                  ),
                  const SizedBox(width: 6),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _restoreAccountDialog,
                    icon: const Icon(Icons.key),
                    label: const Text('Restore account'),
                  ),
                ],
              ),
            ],

            const SizedBox(height: 16),

            // Monthly
            Card(
              color: const Color(0x1AFFFFFF),
              child: ListTile(
                title: const Text('Monthly', style: TextStyle(fontWeight: FontWeight.w700)),
                subtitle: const Text('\$4.99 / 30 days'),
                trailing: _busy
                    ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
                    : ElevatedButton(
                        onPressed: _busy ? null : () => _startPayment('monthly'),
                        child: const Text('Pay'),
                      ),
              ),
            ),
            const SizedBox(height: 8),

            // Yearly
            Card(
              color: const Color(0x1AFFFFFF),
              child: ListTile(
                title: const Text('Yearly', style: TextStyle(fontWeight: FontWeight.w700)),
                subtitle: const Text('\$49.99 / 365 days'),
                trailing: _busy
                    ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
                    : ElevatedButton(
                        onPressed: _busy ? null : () => _startPayment('yearly'),
                        child: const Text('Pay'),
                      ),
              ),
            ),

            const SizedBox(height: 18),
            Row(
              children: [
                ElevatedButton.icon(
                  onPressed: _busy
                      ? null
                      : () async {
                          await _refreshAllStatus();
                          if (!mounted) return;
                          if (_activeGlobal) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Subscription active — unlocked globally.')),
                            );
                            Navigator.pop(context, true);
                          } else {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Not active yet. If you just paid, give it a moment and retry.'),
                              ),
                            );
                          }
                        },
                  icon: const Icon(Icons.verified),
                  label: const Text("I've paid — check status"),
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  onPressed: _busy ? null : _refreshAllStatus,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Refresh'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              'After payment, our server receives a secure webhook and activates your time.\n'
              'One subscription unlocks all regions for your account.',
              style: TextStyle(color: Colors.white70),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
