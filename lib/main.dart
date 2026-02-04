import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:app_links/app_links.dart';
import 'package:webview_flutter/webview_flutter.dart';

const appTitle = 'Alkhudor';
const fixedBaseUrl = 'https://unnervous-supplicatingly-rosanna.ngrok-free.dev';
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

const _odooNotificationChannels = <AndroidNotificationChannel>[
  AndroidNotificationChannel(
    'AtMention',
    'At Mention',
    description: 'Mentions in channels',
    importance: Importance.defaultImportance,
  ),
  AndroidNotificationChannel(
    'ChannelMessage',
    'Channel Message',
    description: 'Messages in channels',
    importance: Importance.defaultImportance,
  ),
  AndroidNotificationChannel(
    'DirectMessage',
    'Direct Message',
    description: 'Direct messages',
    importance: Importance.defaultImportance,
  ),
  AndroidNotificationChannel(
    'Following',
    'Following',
    description: 'Messages from followed threads',
    importance: Importance.defaultImportance,
  ),
  AndroidNotificationChannel(
    'ODOO',
    'Odoo',
    description: 'General Odoo notifications',
    importance: Importance.defaultImportance,
  ),
];

Future<void> _configureNotificationChannels() async {
  if (!Platform.isAndroid) {
    return;
  }
  final plugin = FlutterLocalNotificationsPlugin();
  final androidPlugin =
      plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
  if (androidPlugin == null) {
    return;
  }
  for (final channel in _odooNotificationChannels) {
    await androidPlugin.createNotificationChannel(channel);
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp();
  } catch (error) {
    debugPrint('Firebase initialization failed: $error');
  }
  FirebaseMessaging.onBackgroundMessage(_firebaseBackgroundHandler);
  await _configureNotificationChannels();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: appTitle,
      navigatorKey: appNavigatorKey,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
        useMaterial3: true,
      ),
      home: const AppBootstrap(),
    );
  }
}

class AppBootstrap extends StatefulWidget {
  const AppBootstrap({super.key});

  @override
  State<AppBootstrap> createState() => _AppBootstrapState();
}

class _AppBootstrapState extends State<AppBootstrap> {
  SessionData? _session;
  String? _pendingLink;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    await NotificationCoordinator.init(appNavigatorKey);
    await LinkCoordinator.init(appNavigatorKey);
    final session = await SessionStore.loadSession();
    final pendingLink = await SessionStore.consumePendingLink();
    if (session != null) {
      await WebViewCookieManager().setCookie(
        WebViewCookie(
          name: 'session_id',
          value: session.sessionId,
          domain: Uri.parse(session.baseUrl).host,
          path: '/',
        ),
      );
    }
    if (mounted) {
      setState(() {
        _session = session;
        _pendingLink = pendingLink;
        _ready = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (_session == null) {
      return OdooSetupPage(initialLink: _pendingLink);
    }
    return OdooWebViewPage(
      baseUrl: _session!.baseUrl,
      initialUrl: LinkResolver.resolve(_session!.baseUrl, _pendingLink),
    );
  }
}

class OdooSetupPage extends StatefulWidget {
  const OdooSetupPage({super.key, this.initialLink});

  final String? initialLink;

  @override
  State<OdooSetupPage> createState() => _OdooSetupPageState();
}

class _OdooSetupPageState extends State<OdooSetupPage> {
  final _formKey = GlobalKey<FormState>();
  final _baseUrlController = TextEditingController();
  final _dbController = TextEditingController();
  final _loginController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _isChecking = false;
  bool _isLoggingIn = false;
  List<String> _databases = [];
  String? _selectedDb;
  String? _statusMessage;
  String? _pendingLink;

  @override
  void initState() {
    super.initState();
    _baseUrlController.text = fixedBaseUrl;
    _pendingLink = widget.initialLink;
  }

  @override
  void dispose() {
    _baseUrlController.dispose();
    _dbController.dispose();
    _loginController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  String _normalizeBaseUrl(String input) {
    var trimmed = input.trim();
    if (trimmed.isEmpty) {
      return trimmed;
    }
    if (!trimmed.startsWith('http://') && !trimmed.startsWith('https://')) {
      trimmed = 'https://$trimmed';
    }
    final uri = Uri.parse(trimmed);
    return uri.origin;
  }

  Future<void> _checkLink() async {
    final baseUrl = _normalizeBaseUrl(_baseUrlController.text);
    if (baseUrl.isEmpty) {
      setState(() {
        _statusMessage = 'Enter a valid Odoo URL.';
      });
      return;
    }

    setState(() {
      _isChecking = true;
      _statusMessage = 'Checking server and loading databases...';
      _databases = [];
      _selectedDb = null;
    });

    try {
      final dbs = await OdooApi.fetchDatabases(baseUrl);
      setState(() {
        _databases = dbs;
        if (dbs.isNotEmpty) {
          _selectedDb = dbs.first;
        }
        _statusMessage = dbs.isEmpty
            ? 'Database listing is disabled. Enter DB manually.'
            : 'Server OK. Select a database and login.';
      });
    } catch (error) {
      setState(() {
        _statusMessage = 'Failed to fetch databases: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isChecking = false;
        });
      }
    }
  }

  Future<void> _login({String? totp}) async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    final baseUrl = _normalizeBaseUrl(_baseUrlController.text);
    final db = _selectedDb ?? _dbController.text.trim();

    setState(() {
      _isLoggingIn = true;
      _statusMessage = totp == null
          ? 'Logging in...'
          : 'Verifying two-factor code...';
    });

    try {
      final session = await OdooApi.authenticate(
        baseUrl: baseUrl,
        db: db,
        login: _loginController.text.trim(),
        password: _passwordController.text,
        totp: totp,
      );

      await WebViewCookieManager().setCookie(
        WebViewCookie(
          name: 'session_id',
          value: session.sessionId,
          domain: Uri.parse(baseUrl).host,
          path: '/',
        ),
      );

        await SessionStore.saveSession(baseUrl, session.sessionId);

      try {
        await FcmRegistration.registerDevice(
          baseUrl: baseUrl,
          sessionId: session.sessionId,
        );
      } catch (error) {
        if (mounted) {
          setState(() {
            _statusMessage =
                'Logged in, but push registration failed: ${error.toString()}';
          });
        }
      }

      if (!mounted) {
        return;
      }

      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => OdooWebViewPage(
            baseUrl: baseUrl,
            initialUrl: LinkResolver.resolve(baseUrl, _pendingLink),
          ),
        ),
      );
    } on OdooTwoFactorRequiredException {
      final code = await Navigator.of(context).push<String>(
        MaterialPageRoute(
          builder: (_) => const TwoFactorPage(),
        ),
      );
      if (code == null || code.isEmpty) {
        setState(() {
          _statusMessage = 'Two-factor code is required.';
        });
      } else {
        await _login(totp: code);
      }
    } catch (error) {
      setState(() {
        _statusMessage = 'Login failed: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoggingIn = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasDatabaseList = _databases.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text(appTitle),
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                'Connect to your Odoo server',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _baseUrlController,
                decoration: const InputDecoration(
                  labelText: 'Odoo URL',
                  hintText: 'https://odoo.example.com',
                  helperText: 'This app uses a fixed server URL.',
                ),
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.next,
                readOnly: true,
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Enter your Odoo URL';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _isChecking ? null : _checkLink,
                icon: const Icon(Icons.search),
                label: const Text('Check Link & Load Databases'),
              ),
              const SizedBox(height: 16),
              if (hasDatabaseList)
                DropdownButtonFormField<String>(
                  value: _selectedDb,
                  items: _databases
                      .map(
                        (db) => DropdownMenuItem(
                          value: db,
                          child: Text(db),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    setState(() {
                      _selectedDb = value;
                    });
                  },
                  decoration: const InputDecoration(
                    labelText: 'Database',
                  ),
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Select a database';
                    }
                    return null;
                  },
                )
              else
                TextFormField(
                  controller: _dbController,
                  decoration: const InputDecoration(
                    labelText: 'Database',
                    hintText: 'Enter database name',
                  ),
                  validator: (value) {
                    if ((value == null || value.trim().isEmpty) &&
                        _selectedDb == null) {
                      return 'Enter database name';
                    }
                    return null;
                  },
                ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _loginController,
                decoration: const InputDecoration(
                  labelText: 'Login',
                ),
                textInputAction: TextInputAction.next,
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Enter login';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _passwordController,
                decoration: const InputDecoration(
                  labelText: 'Password',
                ),
                obscureText: true,
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Enter password';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _isLoggingIn ? null : _login,
                child: const Text('Login'),
              ),
              if (_statusMessage != null) ...[
                const SizedBox(height: 16),
                Text(
                  _statusMessage!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.secondary,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class TwoFactorPage extends StatefulWidget {
  const TwoFactorPage({super.key});

  @override
  State<TwoFactorPage> createState() => _TwoFactorPageState();
}

class _TwoFactorPageState extends State<TwoFactorPage> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Two-Factor Authentication')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Enter the authentication code from your app.'),
            const SizedBox(height: 12),
            TextField(
              controller: _controller,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Authentication code',
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () =>
                  Navigator.of(context).pop(_controller.text.trim()),
              child: const Text('Verify'),
            ),
          ],
        ),
      ),
    );
  }
}

class OdooApi {
  static Future<List<String>> fetchDatabases(String baseUrl) async {
    final uri = Uri.parse('$baseUrl/web/database/list');
    final response = await http.post(
      uri,
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'jsonrpc': '2.0',
        'method': 'call',
        'params': {},
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (data['error'] != null) {
      throw Exception((data['error'] as Map)['message'] ?? 'Unknown error');
    }

    final result = (data['result'] as List).cast<String>();
    return result;
  }

  static Future<OdooSession> authenticate({
    required String baseUrl,
    required String db,
    required String login,
    required String password,
    String? totp,
  }) async {
    final uri = Uri.parse('$baseUrl/web/session/authenticate');
    final params = {
      'db': db,
      'login': login,
      'password': password,
      if (totp != null) 'totp': totp,
    };

    final response = await http.post(
      uri,
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'jsonrpc': '2.0',
        'method': 'call',
        'params': params,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (data['error'] != null) {
      if (_isTwoFactorError(data['error'] as Map<String, dynamic>)) {
        throw OdooTwoFactorRequiredException();
      }
      throw Exception((data['error'] as Map)['message'] ?? 'Unknown error');
    }

    final result = data['result'];
    if (result is Map) {
      final uid = result['uid'];
      final uidString = uid?.toString().toLowerCase();
      if (uidString == 'null' || uidString == 'false' || uidString == '0') {
        throw OdooTwoFactorRequiredException();
      }
    }

    final sessionId = _extractSessionId(response.headers['set-cookie']);
    if (sessionId == null) {
      throw Exception('Missing session cookie');
    }

    return OdooSession(sessionId: sessionId);
  }

  static Future<void> registerPushToken({
    required String baseUrl,
    required String sessionId,
    required String token,
  }) async {
    final uri = Uri.parse('$baseUrl/push_notification');
    final response = await http.post(
      uri,
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'Cookie': 'session_id=$sessionId',
      },
      body: {'name': token},
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Push registration failed: HTTP ${response.statusCode}');
    }
  }

  static bool _isTwoFactorError(Map<String, dynamic> error) {
    final message = (error['message'] ?? '').toString().toLowerCase();
    final data = (error['data'] ?? '').toString().toLowerCase();
    return message.contains('two-factor') ||
        message.contains('2fa') ||
        message.contains('totp') ||
        message.contains('authentication code') ||
        data.contains('totp') ||
        data.contains('2fa');
  }

  static String? _extractSessionId(String? setCookieHeader) {
    if (setCookieHeader == null) {
      return null;
    }
    final match = RegExp(r'session_id=([^;]+)').firstMatch(setCookieHeader);
    return match?.group(1);
  }
}

class OdooSession {
  const OdooSession({required this.sessionId});

  final String sessionId;
}

class OdooTwoFactorRequiredException implements Exception {
  @override
  String toString() => 'Two-factor authentication required';
}

class SessionData {
  const SessionData({required this.baseUrl, required this.sessionId});

  final String baseUrl;
  final String sessionId;
}

class SessionStore {
  static const _baseUrlKey = 'odoo.baseUrl';
  static const _sessionIdKey = 'odoo.sessionId';
  static const _pendingLinkKey = 'odoo.pendingLink';

  static Future<void> saveSession(String baseUrl, String sessionId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_baseUrlKey, baseUrl);
    await prefs.setString(_sessionIdKey, sessionId);
  }

  static Future<SessionData?> loadSession() async {
    final prefs = await SharedPreferences.getInstance();
    final baseUrl = prefs.getString(_baseUrlKey);
    final sessionId = prefs.getString(_sessionIdKey);
    if (baseUrl == null || sessionId == null) {
      return null;
    }
    return SessionData(baseUrl: baseUrl, sessionId: sessionId);
  }

  static Future<void> clearSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_baseUrlKey);
    await prefs.remove(_sessionIdKey);
  }

  static Future<void> savePendingLink(String link) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pendingLinkKey, link);
  }

  static Future<String?> consumePendingLink() async {
    final prefs = await SharedPreferences.getInstance();
    final link = prefs.getString(_pendingLinkKey);
    if (link != null) {
      await prefs.remove(_pendingLinkKey);
    }
    return link;
  }
}

class LinkResolver {
  static String? resolve(String baseUrl, String? link) {
    if (link == null || link.isEmpty) {
      return null;
    }
    if (link.startsWith('http://') || link.startsWith('https://')) {
      return link;
    }
    if (link.startsWith('/')) {
      return '$baseUrl$link';
    }
    return '$baseUrl/$link';
  }
}

class NotificationCoordinator {
  static bool _initialized = false;

  static Future<void> init(GlobalKey<NavigatorState> navigatorKey) async {
    if (_initialized) {
      return;
    }
    _initialized = true;
    FirebaseMessaging.onMessageOpenedApp.listen(
      (message) => _handleMessage(message, navigatorKey),
    );
    final initialMessage = await FirebaseMessaging.instance.getInitialMessage();
    if (initialMessage != null) {
      await _handleMessage(initialMessage, navigatorKey);
    }
  }

  static Future<void> _handleMessage(
    RemoteMessage message,
    GlobalKey<NavigatorState> navigatorKey,
  ) async {
    final link = message.data['link']?.toString();
    if (link == null || link.isEmpty) {
      return;
    }
    final session = await SessionStore.loadSession();
    if (session == null) {
      await SessionStore.savePendingLink(link);
      return;
    }
    final url = LinkResolver.resolve(session.baseUrl, link) ?? session.baseUrl;
    await WebViewCookieManager().setCookie(
      WebViewCookie(
        name: 'session_id',
        value: session.sessionId,
        domain: Uri.parse(session.baseUrl).host,
        path: '/',
      ),
    );
    navigatorKey.currentState?.pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => OdooWebViewPage(
          baseUrl: session.baseUrl,
          initialUrl: url,
        ),
      ),
      (route) => false,
    );
  }
}

Future<void> _firebaseBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  final link = message.data['link']?.toString();
  if (link != null && link.isNotEmpty) {
    await SessionStore.savePendingLink(link);
  }
}

class LinkCoordinator {
  static final AppLinks _appLinks = AppLinks();
  static StreamSubscription<Uri?>? _subscription;
  static bool _initialized = false;

  static Future<void> init(GlobalKey<NavigatorState> navigatorKey) async {
    if (_initialized) {
      return;
    }
    _initialized = true;
    try {
      final initialUri = await _appLinks.getInitialLink();
      if (initialUri != null) {
        await _handleLink(initialUri.toString(), navigatorKey);
      }
    } catch (error) {
      debugPrint('Failed to read initial link: $error');
    }
    _subscription = _appLinks.uriLinkStream.listen(
      (uri) {
        if (uri != null) {
          _handleLink(uri.toString(), navigatorKey);
        }
      },
      onError: (error) {
        debugPrint('Link stream error: $error');
      },
    );
  }

  static Future<void> _handleLink(
    String link,
    GlobalKey<NavigatorState> navigatorKey,
  ) async {
    final session = await SessionStore.loadSession();
    if (session == null) {
      await SessionStore.savePendingLink(link);
      return;
    }
    final url = LinkResolver.resolve(session.baseUrl, link) ?? session.baseUrl;
    await WebViewCookieManager().setCookie(
      WebViewCookie(
        name: 'session_id',
        value: session.sessionId,
        domain: Uri.parse(session.baseUrl).host,
        path: '/',
      ),
    );
    navigatorKey.currentState?.pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => OdooWebViewPage(
          baseUrl: session.baseUrl,
          initialUrl: url,
        ),
      ),
      (route) => false,
    );
  }
}

class FcmRegistration {
  static StreamSubscription<String>? _tokenSubscription;

  static Future<void> registerDevice({
    required String baseUrl,
    required String sessionId,
  }) async {
    final messaging = FirebaseMessaging.instance;
    await messaging.requestPermission();

    final token = await messaging.getToken();
    if (token == null || token.isEmpty) {
      throw Exception('FCM token unavailable');
    }

    await OdooApi.registerPushToken(
      baseUrl: baseUrl,
      sessionId: sessionId,
      token: token,
    );

    _tokenSubscription ??= messaging.onTokenRefresh.listen(
      (newToken) async {
        if (newToken.isEmpty) {
          return;
        }
        try {
          await OdooApi.registerPushToken(
            baseUrl: baseUrl,
            sessionId: sessionId,
            token: newToken,
          );
        } catch (error) {
          debugPrint('FCM token refresh failed: $error');
        }
      },
    );
  }
}

class OdooWebViewPage extends StatefulWidget {
  const OdooWebViewPage({
    super.key,
    required this.baseUrl,
    this.initialUrl,
  });

  final String baseUrl;
  final String? initialUrl;

  @override
  State<OdooWebViewPage> createState() => _OdooWebViewPageState();
}

class _OdooWebViewPageState extends State<OdooWebViewPage> {
  late final WebViewController _controller;
  int _loadingProgress = 0;

  @override
  void initState() {
    super.initState();
    final startUrl = widget.initialUrl ?? widget.baseUrl;
    _controller =
        WebViewController()
          ..setJavaScriptMode(JavaScriptMode.unrestricted)
          ..setNavigationDelegate(
            NavigationDelegate(
              onProgress: (progress) {
                if (!mounted) {
                  return;
                }
                setState(() {
                  _loadingProgress = progress;
                });
              },
              onWebResourceError: (error) {
                if (!mounted) {
                  return;
                }
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      'Failed to load page: ${error.errorCode} ${error.description}',
                    ),
                  ),
                );
              },
            ),
          )
          ..loadRequest(Uri.parse(startUrl));
  }

  Future<bool> _handleBackPress() async {
    if (await _controller.canGoBack()) {
      await _controller.goBack();
      return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: _handleBackPress,
      child: Scaffold(
        appBar: AppBar(
          title: const Text(appTitle),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () => _controller.reload(),
              tooltip: 'Reload',
            ),
          ],
        ),
        body: Stack(
          children: [
            WebViewWidget(controller: _controller),
            if (_loadingProgress < 100)
              LinearProgressIndicator(value: _loadingProgress / 100),
          ],
        ),
      ),
    );
  }
}
