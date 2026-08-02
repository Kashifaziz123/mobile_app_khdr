import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:app_links/app_links.dart';
import 'package:webview_flutter/webview_flutter.dart';

const appTitle = 'Alkhudor';
const fixedBaseUrl = 'https://khdrcars.com';
const fixedDatabaseName = 'khdrcars';
// AlKhoder Autocar logo asset
const logoImageAsset = 'assets/logo.png';
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
  AndroidNotificationChannel(
    'Downloads',
    'Downloads',
    description: 'File download progress',
    importance: Importance.defaultImportance,
  ),
];

Future<void> _configureNotificationChannels() async {
  const initializationSettings = InitializationSettings(
    android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    iOS: DarwinInitializationSettings(),
  );
  final plugin = FlutterLocalNotificationsPlugin();
  await plugin.initialize(initializationSettings);
  if (Platform.isIOS) {
    await plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >()
        ?.requestPermissions(alert: true, badge: true, sound: true);
  }
  if (!Platform.isAndroid) {
    return;
  }
  final androidPlugin = plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();
  if (androidPlugin == null) {
    return;
  }
  await androidPlugin.requestNotificationsPermission();
  for (final channel in _odooNotificationChannels) {
    await androidPlugin.createNotificationChannel(channel);
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  FirebaseMessaging.onBackgroundMessage(_firebaseBackgroundHandler);
  await _configureNotificationChannels();

  // iOS: show banners/sound/badge even when app is in the foreground
  if (Platform.isIOS) {
    await FirebaseMessaging.instance
        .setForegroundNotificationPresentationOptions(
          alert: true,
          badge: true,
          sound: true,
        );
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: appTitle,
      navigatorKey: appNavigatorKey,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.red),
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
    try {
      await NotificationCoordinator.init(
        appNavigatorKey,
      ).timeout(const Duration(seconds: 5));
    } catch (e) {
      debugPrint('NotificationCoordinator init timed out or failed: $e');
    }
    try {
      await LinkCoordinator.init(
        appNavigatorKey,
      ).timeout(const Duration(seconds: 5));
    } catch (e) {
      debugPrint('LinkCoordinator init timed out or failed: $e');
    }
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
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_session == null) {
      return OdooSetupPage(initialLink: _pendingLink);
    }
    return OdooWebViewPage(
      baseUrl: _session!.baseUrl,
      initialUrl:
          LinkResolver.resolve(_session!.baseUrl, _pendingLink) ??
          LinkResolver.webClientUrl(_session!.baseUrl),
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
  final _totpController = TextEditingController();

  bool _isChecking = false;
  bool _isLoggingIn = false;
  bool _showTwoFactor = false;
  bool _stopAfterAuthResponse = false;
  bool _handledTotpNavigation = false;
  List<String> _databases = [];
  String? _selectedDb;
  String? _statusMessageKey;
  String?
  _statusMessageExtra; // For error messages that include dynamic content
  String? _pendingLink;
  bool _isArabic = false;
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    _baseUrlController.text = fixedBaseUrl;
    _dbController.text = fixedDatabaseName;
    _selectedDb = fixedDatabaseName;
    _databases = [fixedDatabaseName];
    _pendingLink = widget.initialLink;
    // Auto-check link on mount
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkLink();
    });
  }

  void _toggleLanguage() {
    setState(() {
      _isArabic = !_isArabic;
      // Status message will auto-translate via _getStatusMessage()
    });
  }

  String _text(String en, String ar) => _isArabic ? ar : en;

  String _translateOdooError(String errorMessage) {
    final lowerError = errorMessage.toLowerCase();

    // Common Odoo error translations
    if (lowerError.contains('access denied') ||
        lowerError.contains('wrong login/password')) {
      return _text(
        'Wrong email or password. Please try again.',
        'البريد الإلكتروني أو كلمة المرور خاطئة. يرجى المحاولة مرة أخرى.',
      );
    }
    if (lowerError.contains('invalid credentials') ||
        lowerError.contains('invalid login')) {
      return _text(
        'Invalid email or password.',
        'البريد الإلكتروني أو كلمة المرور غير صحيح.',
      );
    }
    if (lowerError.contains('user not found') ||
        lowerError.contains('unknown user')) {
      return _text(
        'User not found. Please check your email.',
        'المستخدم غير موجود. يرجى التحقق من بريدك الإلكتروني.',
      );
    }
    if (lowerError.contains('password') && lowerError.contains('incorrect')) {
      return _text(
        'Incorrect password. Please try again.',
        'كلمة المرور غير صحيحة. يرجى المحاولة مرة أخرى.',
      );
    }
    if (lowerError.contains('account') &&
        (lowerError.contains('locked') || lowerError.contains('disabled'))) {
      return _text(
        'Your account is locked. Please contact administrator.',
        'حسابك مقفل. يرجى الاتصال بالمسؤول.',
      );
    }
    if (lowerError.contains('database') && lowerError.contains('not found')) {
      return _text(
        'Database not found. Please check the database name.',
        'قاعدة البيانات غير موجودة. يرجى التحقق من اسم قاعدة البيانات.',
      );
    }
    if (lowerError.contains('connection') || lowerError.contains('timeout')) {
      return _text(
        'Connection error. Please check your internet connection.',
        'خطأ في الاتصال. يرجى التحقق من اتصال الإنترنت.',
      );
    }

    // Return original if no translation found
    return errorMessage;
  }

  static String? _extractOdooErrorMessage(Map<String, dynamic> errorData) {
    // 1) error.data.message
    final data = errorData['data'];
    if (data is Map && data['message'] != null) {
      return data['message'].toString();
    }
    // 2) error.message
    if (errorData['message'] != null) {
      return errorData['message'].toString();
    }
    return null;
  }

  String? _getStatusMessage() {
    if (_statusMessageKey == null) return null;
    switch (_statusMessageKey) {
      case 'enter_valid_url':
        return _text('Enter a valid Odoo URL.', 'أدخل رابط أودو صحيح.');
      case 'checking_server':
        return _text(
          'Checking server and loading databases...',
          'جارٍ التحقق من الخادم وتحميل قواعد البيانات...',
        );
      case 'db_listing_disabled':
        return _text(
          'Database listing is disabled. Enter DB manually.',
          'قائمة قواعد البيانات معطلة. أدخل قاعدة البيانات يدوياً.',
        );
      case 'server_ok_single':
        return _text(
          'Server OK. Ready to login.',
          'الخادم جاهز. جاهز لتسجيل الدخول.',
        );
      case 'server_ok_multiple':
        return _text(
          'Server OK. Select a database and login.',
          'الخادم جاهز. اختر قاعدة البيانات وقم بتسجيل الدخول.',
        );
      case 'failed_fetch_db':
        return _text('$_statusMessageExtra', '$_statusMessageExtra');
      case 'logging_in':
        return _text('Logging in...', 'جارٍ تسجيل الدخول...');
      case 'verifying_2fa':
        return _text(
          'Verifying two-factor code...',
          'جارٍ التحقق من رمز المصادقة الثنائية...',
        );
      case 'push_reg_failed':
        return _text(
          'Logged in, but push registration failed: $_statusMessageExtra',
          'تم تسجيل الدخول، لكن فشل تسجيل الإشعارات: $_statusMessageExtra',
        );
      case '2fa_required':
        return _text(
          'Two-factor code is required.',
          'رمز المصادقة الثنائية مطلوب.',
        );
      case 'login_failed':
        if (_statusMessageExtra != null) {
          return _translateOdooError(_statusMessageExtra!);
        }
        return _text('Login failed', 'فشل تسجيل الدخول');
      case 'login_failed_raw':
        return _statusMessageExtra ?? _text('Login failed', 'فشل تسجيل الدخول');
      case 'login_success':
        return _text('Login success', 'تم تسجيل الدخول بنجاح');
      case 'link_unavailable':
        return _text(
          'Server is not accessible. Please try again in a few minutes.',
          'الخادم غير متاح. يرجى المحاولة مرة أخرى بعد بضع دقائق.',
        );
      case 'db_not_selected':
        return _text(
          'Please select a database.',
          'يرجى اختيار قاعدة البيانات.',
        );
      case 'db_not_found':
        return _text(
          'Database not found. Please check the database name.',
          'قاعدة البيانات غير موجودة. يرجى التحقق من اسم قاعدة البيانات.',
        );
      case 'db_required':
        return _text('Database name is required.', 'اسم قاعدة البيانات مطلوب.');
      case 'checking_before_login':
        return _text(
          'Verifying server and database...',
          'جارٍ التحقق من الخادم وقاعدة البيانات...',
        );
      default:
        return _statusMessageKey;
    }
  }

  InputDecoration _inputDecoration({
    required String label,
    required String placeholder,
    required IconData icon,
    Widget? suffix,
  }) {
    return InputDecoration(
      labelText: label,
      hintText: placeholder,
      filled: true,
      fillColor: const Color(0xFFF9FAFB),
      prefixIcon: Icon(icon),
      suffixIcon: suffix,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFE5E5E5), width: 2),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFE5E5E5), width: 2),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFDC2626), width: 2),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    );
  }

  @override
  void dispose() {
    _baseUrlController.dispose();
    _dbController.dispose();
    _loginController.dispose();
    _passwordController.dispose();
    _totpController.dispose();
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

  void _openResetPassword() {
    final baseUrl = _normalizeBaseUrl(_baseUrlController.text);
    if (baseUrl.isEmpty) {
      setState(() {
        _statusMessageKey = 'enter_valid_url';
        _statusMessageExtra = null;
      });
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => OdooWebViewPage(
          baseUrl: baseUrl,
          initialUrl: '$baseUrl/web/reset_password',
        ),
      ),
    );
  }

  Future<void> _checkLink() async {
    final baseUrl = _normalizeBaseUrl(_baseUrlController.text);
    if (baseUrl.isEmpty) {
      setState(() {
        _statusMessageKey = 'enter_valid_url';
        _statusMessageExtra = null;
      });
      return;
    }

    setState(() {
      _isChecking = true;
      _statusMessageKey = 'checking_server';
      _statusMessageExtra = null;
      _databases = [];
      _selectedDb = null;
    });

    try {
      setState(() {
        _databases = [fixedDatabaseName];
        _selectedDb = fixedDatabaseName;
        _statusMessageKey = 'server_ok_single';
        _statusMessageExtra = null;
      });
    } on SocketException catch (e) {
      setState(() {
        _statusMessageKey = 'link_unavailable';
        _statusMessageExtra = null;
      });
    } on HttpException catch (e) {
      setState(() {
        _statusMessageKey = 'link_unavailable';
        _statusMessageExtra = null;
      });
    } catch (error) {
      final errorStr = error.toString().toLowerCase();
      if (errorStr.contains('404') || errorStr.contains('not found')) {
        setState(() {
          _statusMessageKey = 'link_unavailable';
          _statusMessageExtra = null;
        });
      } else {
        // Show exact exception name and message
        final exceptionName = error.runtimeType.toString();
        final exceptionMessage = error.toString();
        setState(() {
          _statusMessageKey = 'failed_fetch_db';
          _statusMessageExtra = '$exceptionName: $exceptionMessage';
        });
      }
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
    if (baseUrl.isEmpty) {
      setState(() {
        _statusMessageKey = 'enter_valid_url';
        _statusMessageExtra = null;
      });
      return;
    }

    // Check link and database availability before login
    if (totp == null) {
      setState(() {
        _isLoggingIn = true;
        _statusMessageKey = 'checking_before_login';
        _statusMessageExtra = null;
      });

      // Verify server is accessible
      try {
        setState(() {
          _databases = [fixedDatabaseName];
          _selectedDb = fixedDatabaseName;
        });
      } on SocketException catch (e) {
        setState(() {
          _statusMessageKey = 'link_unavailable';
          _statusMessageExtra = null;
          _isLoggingIn = false;
        });
        return;
      } on HttpException catch (e) {
        setState(() {
          _statusMessageKey = 'link_unavailable';
          _statusMessageExtra = null;
          _isLoggingIn = false;
        });
        return;
      } catch (error) {
        final errorStr = error.toString().toLowerCase();
        if (errorStr.contains('404') || errorStr.contains('not found')) {
          setState(() {
            _statusMessageKey = 'link_unavailable';
            _statusMessageExtra = null;
            _isLoggingIn = false;
          });
          return;
        } else {
          // Show exact exception name and message
          final exceptionName = error.runtimeType.toString();
          final exceptionMessage = error.toString();
          setState(() {
            _statusMessageKey = 'failed_fetch_db';
            _statusMessageExtra = '$exceptionName: $exceptionMessage';
            _isLoggingIn = false;
          });
          return;
        }
      }
    }

    final db = _selectedDb ?? _dbController.text.trim();
    if (db.isEmpty) {
      setState(() {
        _statusMessageKey = 'db_required';
        _statusMessageExtra = null;
        _isLoggingIn = false;
      });
      return;
    }

    setState(() {
      _isLoggingIn = true;
      _statusMessageKey = totp == null ? 'logging_in' : 'verifying_2fa';
      _statusMessageExtra = null;
    });

    try {
      final session = await OdooApi.authenticate(
        baseUrl: baseUrl,
        db: db,
        login: _loginController.text.trim(),
        password: _passwordController.text,
        totp: totp,
        onRawResponse: (url, body, headers) async {
          if (!mounted) {
            return;
          }
          try {
            final decoded = jsonDecode(body);
            if (decoded is Map<String, dynamic>) {
              _stopAfterAuthResponse = true;
              final error = decoded['error'];
              final result = decoded['result'];
              final uidValue = result is Map ? result['uid'] : null;
              final uidString = uidValue?.toString();

              if (error is Map) {
                final errorMessage = _extractOdooErrorMessage(
                  error.cast<String, dynamic>(),
                );
                if (errorMessage != null) {
                  setState(() {
                    _statusMessageKey = 'login_failed_raw';
                    _statusMessageExtra = errorMessage;
                  });
                  return;
                }
              }
              if (result is Map && (uidString == null || uidString == 'null')) {
                setState(() {
                  _showTwoFactor = true;
                  _statusMessageKey = '2fa_required';
                  _statusMessageExtra = null;
                });
                final sessionId = OdooApi.extractSessionIdFromHeaders(headers);
                if (sessionId != null) {
                  await WebViewCookieManager().setCookie(
                    WebViewCookie(
                      name: 'session_id',
                      value: sessionId,
                      domain: Uri.parse(baseUrl).host,
                      path: '/',
                    ),
                  );
                }
                _handledTotpNavigation = true;
                if (mounted) {
                  Navigator.of(context).pushReplacement(
                    MaterialPageRoute(
                      builder: (_) => OdooWebViewPage(
                        baseUrl: baseUrl,
                        initialUrl: '$baseUrl/web/login/totp',
                      ),
                    ),
                  );
                }
                return;
              }
              if (result is Map && uidString != null) {
                setState(() {
                  _statusMessageKey = 'login_success';
                  _statusMessageExtra = null;
                });
                return;
              }
              setState(() {
                _statusMessageKey = 'login_failed';
                _statusMessageExtra = 'error code 139';
              });
              return;
            }
          } catch (_) {
            setState(() {
              _statusMessageKey = 'login_failed';
              _statusMessageExtra = 'error 179';
            });
            return;
          }
        },
      );

      if (_stopAfterAuthResponse) {
        if (_statusMessageKey == 'login_success') {
          await Future.delayed(const Duration(seconds: 1));
          _stopAfterAuthResponse = false;
        } else {
          await Future.delayed(const Duration(seconds: 1));
          _stopAfterAuthResponse = false;
          return;
        }
      }

      if (_handledTotpNavigation) {
        _handledTotpNavigation = false;
        return;
      }

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
            _statusMessageKey = 'push_reg_failed';
            _statusMessageExtra = error.toString();
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
            initialUrl:
                LinkResolver.resolve(baseUrl, _pendingLink) ??
                LinkResolver.webClientUrl(baseUrl, forceReload: true),
          ),
        ),
      );
    } on OdooTwoFactorRequiredException {
      setState(() {
        _isLoggingIn = false;
        _showTwoFactor = true;
        _statusMessageKey = '2fa_required';
        _statusMessageExtra = null;
      });
      return;
    } catch (error) {
      // Extract the actual error message from Odoo
      String errorMessage = error.toString();

      // Remove "Exception: " prefix if present (can be multiple)
      while (errorMessage.startsWith('Exception: ')) {
        errorMessage = errorMessage.substring(11);
      }

      // Remove "Odoo Server Error: " prefix if present
      if (errorMessage.startsWith('Odoo Server Error: ')) {
        errorMessage = errorMessage.substring(20);
      }

      // Trim any extra whitespace
      errorMessage = errorMessage.trim();

      setState(() {
        _statusMessageKey = 'login_failed';
        _statusMessageExtra = errorMessage.isEmpty
            ? 'Authentication failed'
            : errorMessage;
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
    final hasMultipleDatabases = _databases.length > 1;

    return Scaffold(
      backgroundColor: Colors.white,
      resizeToAvoidBottomInset: false,
      body: Directionality(
        textDirection: _isArabic ? TextDirection.rtl : TextDirection.ltr,
        child: Column(
          children: [
            Container(
              width: double.infinity,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFFdc2626), Color(0xFF991b1b)],
                ),
              ),
              padding: const EdgeInsets.fromLTRB(0, 30, 0, 20),
              child: Stack(
                children: [
                  Positioned(
                    top: 0,
                    right: _isArabic ? null : 0,
                    left: _isArabic ? 0 : null,
                    child: IconButton(
                      onPressed: _toggleLanguage,
                      icon: const Icon(
                        Icons.language,
                        color: Colors.white,
                        size: 24,
                      ),
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.white.withOpacity(0.2),
                        padding: const EdgeInsets.all(12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.only(
                            bottomLeft: Radius.circular(20),
                            bottomRight: Radius.circular(20),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Column(
                      children: [
                        const SizedBox(height: 8),
                        Center(
                          child: Container(
                            width: 150,
                            height: 150,
                            decoration: BoxDecoration(
                              color: Colors.transparent,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Image.asset(
                              logoImageAsset,
                              fit: BoxFit.contain,
                              width: 150,
                              height: 150,
                              errorBuilder: (context, error, stackTrace) {
                                debugPrint('Error loading logo: $error');
                                return Container(
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: const Icon(
                                    Icons.directions_car,
                                    size: 60,
                                    color: Color(0xFFdc2626),
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          _text('Welcome Back', 'مرحباً بعودتك'),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _text(
                            'Login to access your account',
                            'قم بتسجيل الدخول للوصول إلى حسابك',
                          ),
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.9),
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                child: Container(
                  width: double.infinity,
                  color: Colors.white,
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (hasMultipleDatabases)
                          DropdownButtonFormField<String>(
                            value: _selectedDb,
                            isExpanded: true,
                            items: _databases
                                .map(
                                  (db) => DropdownMenuItem(
                                    value: db,
                                    child: Text(
                                      db,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                )
                                .toList(),
                            onChanged: (value) {
                              setState(() {
                                _selectedDb = value;
                              });
                            },
                            decoration: _inputDecoration(
                              label: _text('Database', 'قاعدة البيانات'),
                              placeholder: _text(
                                'Select database',
                                'اختر قاعدة البيانات',
                              ),
                              icon: Icons.storage,
                            ),
                            validator: (value) {
                              if (value == null || value.isEmpty) {
                                return _text(
                                  'Select a database',
                                  'اختر قاعدة البيانات',
                                );
                              }
                              return null;
                            },
                          ),
                        if (hasMultipleDatabases) const SizedBox(height: 10),
                        TextFormField(
                          controller: _loginController,
                          decoration: _inputDecoration(
                            label: _text('Email', 'البريد الإلكتروني'),
                            placeholder: _text(
                              'Enter your email',
                              'أدخل بريدك الإلكتروني',
                            ),
                            icon: Icons.email,
                          ),
                          textInputAction: TextInputAction.next,
                          validator: (value) {
                            if (value == null || value.trim().isEmpty) {
                              return _text(
                                'Enter login',
                                'أدخل البريد الإلكتروني',
                              );
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 10),
                        TextFormField(
                          controller: _passwordController,
                          decoration: _inputDecoration(
                            label: _text('Password', 'كلمة المرور'),
                            placeholder: _text(
                              'Enter your password',
                              'أدخل كلمة المرور',
                            ),
                            icon: Icons.lock,
                            suffix: IconButton(
                              onPressed: () {
                                setState(() {
                                  _obscurePassword = !_obscurePassword;
                                });
                              },
                              icon: Icon(
                                _obscurePassword
                                    ? Icons.visibility
                                    : Icons.visibility_off,
                              ),
                            ),
                          ),
                          obscureText: _obscurePassword,
                          validator: (value) {
                            if (value == null || value.isEmpty) {
                              return _text(
                                'Enter password',
                                'أدخل كلمة المرور',
                              );
                            }
                            return null;
                          },
                        ),
                        Align(
                          alignment: _isArabic
                              ? Alignment.centerLeft
                              : Alignment.centerRight,
                          child: TextButton(
                            onPressed: _openResetPassword,
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                            ),
                            child: Text(
                              _text('Forgot password?', 'نسيت كلمة المرور؟'),
                              style: const TextStyle(
                                color: Color(0xFFDC2626),
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Container(
                          height: 48,
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [Color(0xFFdc2626), Color(0xFF991b1b)],
                            ),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: ElevatedButton(
                            onPressed: _isLoggingIn ? null : _login,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.transparent,
                              shadowColor: Colors.transparent,
                              minimumSize: const Size.fromHeight(48),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: Text(
                              _text('Log in', 'تسجيل الدخول'),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                        if (_getStatusMessage() != null) ...[
                          const SizedBox(height: 16),
                          Text(
                            _getStatusMessage()!,
                            style: const TextStyle(color: Color(0xFFDC2626)),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Container(
              width: double.infinity,
              color: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      TextButton(
                        onPressed: () {},
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                        ),
                        child: Text(
                          _text('Need Help?', 'تحتاج مساعدة؟'),
                          style: const TextStyle(
                            color: Color(0xFF6B7280),
                            fontSize: 12,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: () {},
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                        ),
                        child: Text(
                          _text('Terms & Conditions', 'الشروط والأحكام'),
                          style: const TextStyle(
                            color: Color(0xFF6B7280),
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _text(
                      '© 2026 AlKhoder Autocar. All rights reserved.',
                      '© 2026 الخضر للسيارات. جميع الحقوق محفوظة.',
                    ),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xFF9CA3AF),
                      fontSize: 11,
                    ),
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

class TwoFactorPage extends StatefulWidget {
  final bool isArabic;
  const TwoFactorPage({super.key, required this.isArabic});

  @override
  State<TwoFactorPage> createState() => _TwoFactorPageState();
}

class _TwoFactorPageState extends State<TwoFactorPage> {
  final _controller = TextEditingController();

  String _text(String en, String ar) => widget.isArabic ? ar : en;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_text('Two-Factor Authentication', 'المصادقة الثنائية')),
      ),
      body: Directionality(
        textDirection: widget.isArabic ? TextDirection.rtl : TextDirection.ltr,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _text(
                  'Enter the authentication code from your app.',
                  'أدخل رمز المصادقة من تطبيقك.',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _controller,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: _text('Authentication code', 'رمز المصادقة'),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () =>
                    Navigator.of(context).pop(_controller.text.trim()),
                child: Text(_text('Verify', 'تحقق')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class OdooApi {
  static String? _extractOdooErrorMessage(Map<String, dynamic> errorData) {
    final data = errorData['data'];
    if (data is Map && data['message'] != null) {
      return data['message'].toString();
    }
    if (errorData['message'] != null) {
      return errorData['message'].toString();
    }
    return null;
  }

  static Future<List<String>> fetchDatabases(String baseUrl) async {
    // API fetchDatabases temporarily disabled.
    // final uri = Uri.parse('$baseUrl/web/database/list');
    // http.Response response;
    // try {
    //   response = await http.post(
    //     uri,
    //     headers: const {'Content-Type': 'application/json'},
    //     body: jsonEncode({
    //       'jsonrpc': '2.0',
    //       'method': 'call',
    //       'params': {},
    //     }),
    //   ).timeout(const Duration(seconds: 10));
    // } on SocketException {
    //   rethrow;
    // } on HttpException {
    //   rethrow;
    // } on TimeoutException {
    //   throw HttpException('Connection timeout');
    // } catch (e) {
    //   throw HttpException('Failed to connect: $e');
    // }
    //
    // if (response.statusCode == 404) {
    //   throw HttpException('Server endpoint not found');
    // }
    //
    // if (response.statusCode != 200) {
    //   throw HttpException('Server returned error: ${response.statusCode}');
    // }
    //
    // try {
    //   final data = jsonDecode(response.body) as Map<String, dynamic>;
    //   if (data['error'] != null) {
    //     throw Exception((data['error'] as Map)['message'] ?? 'Unknown error');
    //   }
    //
    //   final result = (data['result'] as List).cast<String>();
    //   return result;
    // } catch (e) {
    //   if (e is HttpException || e is SocketException) {
    //     rethrow;
    //   }
    //   throw Exception('Invalid server response: $e');
    // }
    return [fixedDatabaseName];
  }

  static Future<OdooSession> authenticate({
    required String baseUrl,
    required String db,
    required String login,
    required String password,
    String? totp,
    Future<void> Function(String url, String body, Map<String, String> headers)?
    onRawResponse,
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
      body: jsonEncode({'jsonrpc': '2.0', 'method': 'call', 'params': params}),
    );

    if (onRawResponse != null) {
      await onRawResponse(uri.toString(), response.body, response.headers);
    }

    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (data['error'] != null) {
      if (_isTwoFactorError(data['error'] as Map<String, dynamic>)) {
        throw OdooTwoFactorRequiredException();
      }

      // Extract Odoo error message (1) error.data.message, (2) error.message
      final errorData = data['error'] as Map<String, dynamic>;
      final errorMessage = _extractOdooErrorMessage(errorData);
      if (errorMessage != null && errorMessage.isNotEmpty) {
        throw Exception(errorMessage);
      }
      throw Exception('Odoo Exception Error: ${errorData.toString()}');
    }

    final result = data['result'];
    if (result is Map) {
      final uid = result['uid'];
      final uidString = uid;
      if (uidString == null) {
        throw OdooTwoFactorRequiredException();
      }

      // Check if result contains error information
      if (result['error'] != null) {
        final resultError = result['error'];
        if (resultError is Map) {
          final errorMsg =
              resultError['message'] ??
              resultError['data']?.toString() ??
              'Authentication failed';
          throw Exception(errorMsg.toString());
        } else if (resultError is String) {
          throw Exception(resultError);
        }
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

  /// Asks the server to remove any FCM token associated with the given session.
  /// Sends an empty token name which signals the Odoo backend to deregister
  /// the device for this session.
  static Future<void> unregisterPushToken({
    required String baseUrl,
    required String sessionId,
  }) async {
    final uri = Uri.parse('$baseUrl/push_notification');
    final response = await http.post(
      uri,
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'Cookie': 'session_id=$sessionId',
      },
      body: {'name': ''},
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Push unregister failed: HTTP ${response.statusCode}');
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

  static String? extractSessionIdFromHeaders(Map<String, String> headers) {
    return _extractSessionId(headers['set-cookie']);
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

  static String webClientUrl(String baseUrl, {bool forceReload = false}) {
    if (forceReload) {
      return '$baseUrl/web?${DateTime.now().millisecondsSinceEpoch}=0';
    }
    return '$baseUrl/web';
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
    try {
      final initialMessage = await FirebaseMessaging.instance
          .getInitialMessage()
          .timeout(const Duration(seconds: 3));
      if (initialMessage != null) {
        await _handleMessage(initialMessage, navigatorKey);
      }
    } catch (e) {
      debugPrint('getInitialMessage timed out or failed: $e');
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
    final resolvedUrl = url == session.baseUrl
        ? LinkResolver.webClientUrl(session.baseUrl)
        : url;
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
        builder: (_) =>
            OdooWebViewPage(baseUrl: session.baseUrl, initialUrl: resolvedUrl),
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
      final initialUri = await _appLinks.getInitialLink().timeout(
        const Duration(seconds: 3),
      );
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
        builder: (_) =>
            OdooWebViewPage(baseUrl: session.baseUrl, initialUrl: url),
      ),
      (route) => false,
    );
  }
}

class FcmRegistration {
  static StreamSubscription<String>? _tokenSubscription;
  static String? _registeredBaseUrl;
  static String? _registeredSessionId;

  static Future<void> registerDevice({
    required String baseUrl,
    required String sessionId,
  }) async {
    final messaging = FirebaseMessaging.instance;
    await messaging.requestPermission();

    // On iOS, Firebase needs the APNs token before it can provide an FCM token.
    // Poll briefly to give the system time to deliver the APNs token.
    String? token;
    if (Platform.isIOS) {
      for (var i = 0; i < 5; i++) {
        token = await messaging.getToken();
        if (token != null && token.isNotEmpty) break;
        await Future.delayed(const Duration(seconds: 2));
      }
    } else {
      token = await messaging.getToken();
    }

    if (token == null || token.isEmpty) {
      throw Exception('FCM token unavailable');
    }

    _registeredBaseUrl = baseUrl;
    _registeredSessionId = sessionId;

    await OdooApi.registerPushToken(
      baseUrl: baseUrl,
      sessionId: sessionId,
      token: token,
    );

    // Cancel any previous subscription before creating a new one so a
    // re-login does not keep a stale closure pointing to the old session.
    await _tokenSubscription?.cancel();
    _tokenSubscription = messaging.onTokenRefresh.listen((newToken) async {
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
    });
  }

  /// Unlinks the FCM token from the current user on the server, cancels the
  /// token-refresh listener, and deletes the local FCM token so that a fresh
  /// token is issued on the next login (ensuring it gets associated with the
  /// new user only).
  static Future<void> unregisterDevice() async {
    // Cancel the token-refresh listener immediately so it can no longer send
    // the old session to the server.
    await _tokenSubscription?.cancel();
    _tokenSubscription = null;

    final baseUrl = _registeredBaseUrl;
    final sessionId = _registeredSessionId;
    _registeredBaseUrl = null;
    _registeredSessionId = null;

    // Tell the server to remove the token for the current session.
    if (baseUrl != null && sessionId != null) {
      try {
        await OdooApi.unregisterPushToken(
          baseUrl: baseUrl,
          sessionId: sessionId,
        );
      } catch (error) {
        debugPrint('FCM token unregister failed: $error');
      }
    }

    // Delete the local FCM token so Firebase issues a brand-new token on the
    // next registerDevice() call, preventing any cross-account token reuse.
    try {
      await FirebaseMessaging.instance.deleteToken();
    } catch (error) {
      debugPrint('FCM deleteToken failed: $error');
    }
  }
}

class OdooWebViewPage extends StatefulWidget {
  const OdooWebViewPage({super.key, required this.baseUrl, this.initialUrl});

  final String baseUrl;
  final String? initialUrl;

  @override
  State<OdooWebViewPage> createState() => _OdooWebViewPageState();
}

class _OdooWebViewPageState extends State<OdooWebViewPage> {
  late final WebViewController _controller;
  final ValueNotifier<int> _progressNotifier = ValueNotifier(0);
  final ValueNotifier<AttachmentDownload?> _downloadNotifier = ValueNotifier(
    null,
  );
  final OdooAttachmentDownloader _attachmentDownloader =
      OdooAttachmentDownloader();
  bool _logoutHandled = false;
  bool _loginHandled = false;

  @override
  void initState() {
    super.initState();
    final startUrl = widget.initialUrl ?? widget.baseUrl;
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'KhdrDownload',
        onMessageReceived: (message) {
          final url = message.message.trim();
          if (url.isNotEmpty) {
            _downloadAttachment(url);
          }
        },
      )
      ..setOnConsoleMessage((_) {})
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            if (_isLoginUrl(request.url)) {
              _handleLoginRedirect();
              return NavigationDecision.prevent;
            }
            if (_isLogoutUrl(request.url)) {
              _handleLogout();
              return NavigationDecision.prevent;
            }
            if (_shouldDownloadInApp(request.url)) {
              _downloadAttachment(request.url);
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
          onProgress: (progress) {
            _progressNotifier.value = progress;
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
          onPageFinished: (url) {
            _injectDownloadBridge();
            if (Platform.isAndroid) {
              _injectKeyboardScrollFix();
            }
          },
        ),
      )
      ..loadRequest(Uri.parse(startUrl));
  }

  void _injectDownloadBridge() {
    _controller.runJavaScript(r'''
      (function() {
        if (window._khdrDownloadBridge) return;
        window._khdrDownloadBridge = true;

        function isDownloadUrl(value) {
          if (!value || typeof value !== 'string') return false;
          try {
            var url = new URL(value, window.location.href);
            var path = url.pathname.toLowerCase();
            if (path === "/web/content" || path.indexOf("/web/content/") === 0 ||
                path === "/web/image" || path.indexOf("/web/image/") === 0) {
              return true;
            }
            // Also catch any same-origin URL with an explicit download flag.
            if (url.hostname === window.location.hostname) {
              var dl = new URLSearchParams(url.search).get('download');
              if (dl === 'true' || dl === '1') return true;
            }
            return false;
          } catch (e) {
            return false;
          }
        }

        function sendDownload(value) {
          if (!isDownloadUrl(value)) return false;
          try {
            KhdrDownload.postMessage(new URL(value, window.location.href).href);
          } catch(e) {
            KhdrDownload.postMessage(value);
          }
          return true;
        }

        // Intercept anchor clicks (capture phase so we run before Odoo's JS)
        document.addEventListener("click", function(event) {
          var el = event.target;
          var anchor = el && el.closest ? el.closest("a[href]") : null;
          if (anchor && (anchor.hasAttribute("download") || isDownloadUrl(anchor.href))) {
            if (sendDownload(anchor.href)) {
              event.preventDefault();
              event.stopPropagation();
              event.stopImmediatePropagation();
            }
          }
        }, true);

        // Intercept programmatic anchor.click() calls (Odoo creates a temp <a> and clicks it)
        var originalClick = HTMLAnchorElement.prototype.click;
        HTMLAnchorElement.prototype.click = function() {
          var href = this.href || this.getAttribute("href");
          if ((this.hasAttribute("download") || isDownloadUrl(href)) && sendDownload(href)) {
            return;
          }
          return originalClick.apply(this, arguments);
        };

        // Intercept window.open() used by some Odoo viewers for downloads
        var originalOpen = window.open;
        window.open = function(url, target, features) {
          if (typeof url === 'string' && sendDownload(url)) {
            return null;
          }
          return originalOpen.apply(this, arguments);
        };
      })();
    ''');
  }

  // Injected once per page load on Android.
  // Fixes two issues in Odoo discuss:
  //   1. Brief flash on first input tap (keyboard appears before Odoo's JS scrolls).
  //   2. Input hidden after sending a message (Odoo's resize handler doesn't re-fire
  //      because the input was never blurred, so visualViewport.height didn't change).
  // Strategy: on both viewport resize AND focusin on any editable element,
  // dispatch a synthetic 'resize' so Odoo's own handler re-runs, then also
  // call scrollIntoView as a fallback.
  void _injectKeyboardScrollFix() {
    _controller.runJavaScript(r'''
      (function() {
        if (window._khdrScrollFix) return;
        window._khdrScrollFix = true;

        function fixLayout() {
          window.dispatchEvent(new Event('resize'));
          var el = document.activeElement;
          if (el && el !== document.body && el !== document.documentElement) {
            setTimeout(function() {
              el.scrollIntoView({ behavior: 'instant', block: 'nearest' });
            }, 50);
          }
        }

        if (window.visualViewport) {
          window.visualViewport.addEventListener('resize', function() {
            setTimeout(fixLayout, 100);
          });
        }

        document.addEventListener('focusin', function(e) {
          var t = e.target;
          if (!t) return;
          var tag = t.tagName;
          var ce = t.getAttribute('contenteditable');
          if (tag === 'INPUT' || tag === 'TEXTAREA' || ce === 'true' || ce === '') {
            setTimeout(fixLayout, 300);
          }
        }, true);
      })();
    ''');
  }

  @override
  void dispose() {
    _progressNotifier.dispose();
    _downloadNotifier.dispose();
    super.dispose();
  }

  bool _shouldDownloadInApp(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final path = uri.path.toLowerCase();
    if (path == '/web/content' || path.startsWith('/web/content/')) return true;
    if (path == '/web/image' || path.startsWith('/web/image/')) return true;
    // Catch any same-server URL with an explicit download flag (Odoo always adds this).
    final download = uri.queryParameters['download'];
    if (download == 'true' || download == '1') return true;
    return false;
  }

  static const _downloaderChannel = MethodChannel('com.khdr/downloader');

  // Ensures the URL has download=true so Odoo returns the file as an attachment.
  static String _withDownloadParam(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    final q = uri.queryParameters;
    if (q['download'] == 'true' || q['download'] == '1') return url;
    return uri.replace(queryParameters: {...q, 'download': 'true'}).toString();
  }

  Future<void> _downloadAttachment(String url) async {
    final session = await SessionStore.loadSession();
    if (session == null) {
      await _handleLoginRedirect();
      return;
    }
    final resolvedUrl = _withDownloadParam(
      LinkResolver.resolve(widget.baseUrl, url) ?? url,
    );

    if (_downloadNotifier.value?.active == true) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('A download is already in progress.')),
        );
      }
      return;
    }

    // On Android, use the live WebView cookie (always current) instead of the
    // stored session_id, which can be stale if Odoo refreshed the session.
    String? liveCookie;
    if (Platform.isAndroid) {
      try {
        liveCookie = await _downloaderChannel.invokeMethod<String>(
          'getCookies',
          {'url': resolvedUrl},
        );
      } catch (_) {}
    }

    _downloadNotifier.value = const AttachmentDownload(
      fileName: 'Preparing download…',
      progress: null,
      active: true,
    );
    try {
      final fileName = await _attachmentDownloader.download(
        url: resolvedUrl,
        baseUrl: session.baseUrl,
        sessionId: session.sessionId,
        cookieOverride: liveCookie,
        onProgress: (status) {
          _downloadNotifier.value = status;
        },
      );
      _downloadNotifier.value = null;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Downloaded: $fileName'),
          duration: const Duration(seconds: 5),
        ),
      );
    } catch (error) {
      try {
        await _attachmentDownloader.cancelActiveDownload();
      } catch (_) {}
      _downloadNotifier.value = null;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Download failed: $error')),
      );
    }
  }

  bool _isLogoutUrl(String url) {
    if (_logoutHandled) {
      return false;
    }
    final uri = Uri.tryParse(url);
    if (uri == null) {
      return false;
    }
    final path = uri.path.toLowerCase();
    return path.contains('/web/session/logout');
  }

  bool _isLoginUrl(String url) {
    if (_loginHandled) {
      return false;
    }
    final uri = Uri.tryParse(url);
    if (uri == null) {
      return false;
    }
    final path = uri.path.toLowerCase();
    return path.contains('/web/login');
  }

  Future<void> _handleLogout() async {
    if (_logoutHandled) {
      return;
    }
    _logoutHandled = true;
    // Unlink the FCM token from this user on the server and delete the local
    // token before clearing the session, so the server call is still
    // authenticated and a fresh token is issued on the next login.
    await FcmRegistration.unregisterDevice();
    await SessionStore.clearSession();
    await WebViewCookieManager().clearCookies();
    if (!mounted) {
      return;
    }
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const OdooSetupPage()),
      (route) => false,
    );
  }

  Future<void> _handleLoginRedirect() async {
    if (_loginHandled) {
      return;
    }
    _loginHandled = true;
    // Same cleanup as logout: unlink the FCM token from the current user
    // before the session is wiped.
    await FcmRegistration.unregisterDevice();
    await SessionStore.clearSession();
    await WebViewCookieManager().clearCookies();
    if (!mounted) {
      return;
    }
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const OdooSetupPage()),
      (route) => false,
    );
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
        // On Android: prevent Flutter from adding a bottom inset on top of the
        // OS-level adjustResize. The double-resize causes the WebView to lose
        // input focus and dismiss the keyboard. iOS handles this natively via
        // WKWebView, so we keep the default (true) there.
        resizeToAvoidBottomInset: !Platform.isAndroid,
        body: SafeArea(
          top: true,
          child: Stack(
            children: [
              WebViewWidget(controller: _controller),
              ValueListenableBuilder<int>(
                valueListenable: _progressNotifier,
                builder: (context, progress, _) {
                  if (progress >= 100) return const SizedBox.shrink();
                  return LinearProgressIndicator(value: progress / 100);
                },
              ),
              ValueListenableBuilder<AttachmentDownload?>(
                valueListenable: _downloadNotifier,
                builder: (context, download, _) {
                  if (download == null || !download.active) {
                    return const SizedBox.shrink();
                  }
                  return Positioned(
                    left: 12,
                    right: 12,
                    bottom: 12,
                    child: SafeArea(
                      top: false,
                      child: Material(
                        elevation: 6,
                        borderRadius: BorderRadius.circular(8),
                        color: Colors.black87,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                download.fileName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: Colors.white),
                              ),
                              const SizedBox(height: 8),
                              LinearProgressIndicator(
                                value: download.progress == null
                                    ? null
                                    : download.progress! / 100,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class AttachmentDownload {
  const AttachmentDownload({
    required this.fileName,
    required this.progress,
    required this.active,
  });

  final String fileName;
  final int? progress;
  final bool active;
}

class OdooAttachmentDownloader {
  OdooAttachmentDownloader({
    http.Client? client,
    FlutterLocalNotificationsPlugin? notifications,
  }) : _client = client ?? http.Client(),
       _notifications = notifications ?? FlutterLocalNotificationsPlugin();

  static int _nextNotificationId = 17001;
  int? _activeNotificationId;
  final http.Client _client;
  final FlutterLocalNotificationsPlugin _notifications;

  Future<String> download({
    required String url,
    required String baseUrl,
    required String sessionId,
    required void Function(AttachmentDownload status) onProgress,
    String? cookieOverride,
  }) async {
    final notificationId = _nextNotificationId++;
    _activeNotificationId = notificationId;
    final request = http.Request('GET', Uri.parse(_forceDownload(url)));
    request.headers.addAll({
      // Prefer the live WebView cookie (passed as cookieOverride on Android);
      // fall back to the stored session_id for iOS.
      HttpHeaders.cookieHeader: (cookieOverride != null && cookieOverride.isNotEmpty)
          ? cookieOverride
          : 'session_id=$sessionId',
      HttpHeaders.acceptHeader: '*/*',
      HttpHeaders.userAgentHeader: 'Alkhudor Flutter App',
      HttpHeaders.refererHeader: LinkResolver.webClientUrl(baseUrl),
    });

    await _showNotification(
      notificationId: notificationId,
      title: 'Downloading attachment',
      body: 'Starting...',
      progress: null,
      ongoing: true,
    );

    final response = await _client
        .send(request)
        .timeout(const Duration(seconds: 60));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Server returned ${response.statusCode}');
    }

    final contentType = response.headers[HttpHeaders.contentTypeHeader] ?? '';
    if (contentType.toLowerCase().contains('text/html')) {
      throw Exception(
        'Session may have expired — the server returned a web page instead of a file.',
      );
    }

    final fileName = _sanitizeFileName(
      _fileNameFromDisposition(response.headers['content-disposition']) ??
          _fileNameFromUrl(response.request?.url ?? Uri.parse(url)) ??
          _fallbackFileName(contentType),
    );
    final downloadsDir = await _downloadsDirectory();
    final destinationFile = await _availableFile(downloadsDir, fileName);
    final sink = destinationFile.openWrite();
    final expectedBytes = response.contentLength ?? -1;
    var receivedBytes = 0;
    var lastProgress = -1;

    try {
      // Per-chunk timeout: if no data arrives for 30 s, give up.
      await for (final chunk
          in response.stream.timeout(const Duration(seconds: 30))) {
        receivedBytes += chunk.length;
        sink.add(chunk);
        final int? progress = expectedBytes > 0
            ? (receivedBytes * 100 / expectedBytes).floor().clamp(0, 99)
            : null;
        if (progress == null || progress != lastProgress) {
          if (progress != null) {
            lastProgress = progress;
          }
          onProgress(
            AttachmentDownload(
              fileName: fileName,
              progress: progress,
              active: true,
            ),
          );
          await _showNotification(
            notificationId: notificationId,
            title: 'Downloading',
            body: fileName,
            progress: progress,
            ongoing: true,
          );
        }
      }
    } finally {
      await sink.close();
    }

    // On iOS, all files stay in the app Documents folder. Image files are
    // additionally added to the user's Photos library.
    if (Platform.isIOS && _isImageDownload(fileName, contentType)) {
      await _saveIosDownload(
        destinationFile,
        isImage: true,
      );
    }

    await _showNotification(
      notificationId: notificationId,
      title: 'Download complete',
      body: fileName,
      progress: 100,
      ongoing: false,
    );
    _activeNotificationId = null;
    return fileName;
  }

  Future<void> cancelActiveDownload() async {
    final notificationId = _activeNotificationId;
    _activeNotificationId = null;
    if (notificationId != null) {
      await _notifications.cancel(notificationId);
    }
  }

  Future<Directory> _downloadsDirectory() async {
    if (Platform.isAndroid) {
      // Ask the native side for the public Downloads path
      // (Environment.getExternalStoragePublicDirectory(DIRECTORY_DOWNLOADS)).
      // This bypasses DownloadManager and writes directly to the folder that
      // appears in the user's Downloads app.
      try {
        const channel = MethodChannel('com.khdr/downloader');
        final path = await channel.invokeMethod<String>('getPublicDownloadsPath');
        if (path != null && path.isNotEmpty) {
          final dir = Directory(path);
          if (!await dir.exists()) await dir.create(recursive: true);
          return dir;
        }
      } catch (_) {}
      // Fallback: app-specific external storage.
      final ext = await getExternalStorageDirectory();
      if (ext != null) return ext;
    }

    // UIFileSharingEnabled exposes this directory in Files as
    // On My iPhone > Alkhudor App.
    return getApplicationDocumentsDirectory();
  }

  Future<void> _saveIosDownload(File file, {required bool isImage}) async {
    const channel = MethodChannel('com.khdr/downloader');
    await channel.invokeMethod<void>('saveDownloadedFile', {
      'path': file.path,
      'isImage': isImage,
    });
  }

  bool _isImageDownload(String fileName, String contentType) {
    if (contentType.split(';').first.trim().toLowerCase().startsWith('image/')) {
      return true;
    }
    final extension = fileName.split('.').last.toLowerCase();
    return const {
      'avif', 'bmp', 'gif', 'heic', 'heif', 'jpeg', 'jpg', 'png', 'tif',
      'tiff', 'webp',
    }.contains(extension);
  }

  Future<File> _availableFile(Directory directory, String fileName) async {
    final dotIndex = fileName.lastIndexOf('.');
    final baseName = dotIndex > 0 ? fileName.substring(0, dotIndex) : fileName;
    final extension = dotIndex > 0 ? fileName.substring(dotIndex) : '';
    var candidate = File('${directory.path}${Platform.pathSeparator}$fileName');
    var counter = 1;
    while (await candidate.exists()) {
      candidate = File(
        '${directory.path}${Platform.pathSeparator}$baseName ($counter)$extension',
      );
      counter += 1;
    }
    return candidate;
  }

  Future<void> _showNotification({
    required int notificationId,
    required String title,
    required String body,
    required int? progress,
    required bool ongoing,
  }) async {
    // The app already has an in-app progress indicator. Suppress iOS local
    // notifications to avoid a banner for every download-progress update.
    if (Platform.isIOS) {
      return;
    }
    final androidDetails = Platform.isAndroid
        ? AndroidNotificationDetails(
            'Downloads',
            'Downloads',
            channelDescription: 'File download progress',
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
            ongoing: ongoing,
            onlyAlertOnce: true,
            showProgress: true,
            maxProgress: 100,
            progress: progress ?? 0,
            indeterminate: progress == null,
          )
        : null;
    if (androidDetails == null) {
      return;
    }
    await _notifications.show(
      notificationId,
      title,
      (progress == null || !ongoing) ? body : '$body ($progress%)',
      NotificationDetails(android: androidDetails),
    );
  }

  String _forceDownload(String url) {
    final uri = Uri.parse(url);
    if (uri.queryParameters['download'] == 'true' ||
        uri.queryParameters['download'] == '1') {
      return url;
    }
    final params = Map<String, String>.from(uri.queryParameters);
    params['download'] = 'true';
    return uri.replace(queryParameters: params).toString();
  }

  String? _fileNameFromDisposition(String? contentDisposition) {
    if (contentDisposition == null || contentDisposition.isEmpty) {
      return null;
    }
    final encodedMatch = RegExp(
      "filename\\*=UTF-8''([^;]+)",
      caseSensitive: false,
    ).firstMatch(contentDisposition);
    if (encodedMatch != null) {
      return Uri.decodeFull(encodedMatch.group(1)!.trim());
    }
    final quotedMatch = RegExp(
      'filename="([^"]+)"',
      caseSensitive: false,
    ).firstMatch(contentDisposition);
    if (quotedMatch != null) {
      return quotedMatch.group(1)?.trim();
    }
    final plainMatch = RegExp(
      'filename=([^;]+)',
      caseSensitive: false,
    ).firstMatch(contentDisposition);
    return plainMatch?.group(1)?.trim();
  }

  String? _fileNameFromUrl(Uri uri) {
    final filename =
        uri.queryParameters['filename'] ??
        uri.queryParameters['filename_field'] ??
        (uri.pathSegments.isNotEmpty ? uri.pathSegments.last : null);
    if (filename == null || filename.isEmpty || filename == 'content') {
      return null;
    }
    return filename;
  }

  String _fallbackFileName(String contentType) {
    final extension = _extensionFromMime(contentType) ?? 'bin';
    return 'odoo_attachment_${DateTime.now().millisecondsSinceEpoch}.$extension';
  }

  String _sanitizeFileName(String fileName) {
    final cleaned = fileName
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') {
      return _fallbackFileName('');
    }
    return cleaned;
  }

  String? _extensionFromMime(String contentType) {
    final mimeType = contentType.split(';').first.trim().toLowerCase();
    switch (mimeType) {
      case 'image/jpeg':
        return 'jpg';
      case 'image/png':
        return 'png';
      case 'image/gif':
        return 'gif';
      case 'application/pdf':
        return 'pdf';
      case 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet':
        return 'xlsx';
      case 'application/vnd.ms-excel':
        return 'xls';
      default:
        return null;
    }
  }
}
