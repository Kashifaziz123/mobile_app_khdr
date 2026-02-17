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
    await Firebase.initializeApp();
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
      await NotificationCoordinator.init(appNavigatorKey)
          .timeout(const Duration(seconds: 5));
    } catch (e) {
      debugPrint('NotificationCoordinator init timed out or failed: $e');
    }
    try {
      await LinkCoordinator.init(appNavigatorKey)
          .timeout(const Duration(seconds: 5));
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
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (_session == null) {
      return OdooSetupPage(initialLink: _pendingLink);
    }
    return OdooWebViewPage(
      baseUrl: _session!.baseUrl,
      initialUrl: LinkResolver.resolve(_session!.baseUrl, _pendingLink) ??
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
  String? _statusMessageExtra; // For error messages that include dynamic content
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
    if (lowerError.contains('access denied') || lowerError.contains('wrong login/password')) {
      return _text('Wrong email or password. Please try again.', 'البريد الإلكتروني أو كلمة المرور خاطئة. يرجى المحاولة مرة أخرى.');
    }
    if (lowerError.contains('invalid credentials') || lowerError.contains('invalid login')) {
      return _text('Invalid email or password.', 'البريد الإلكتروني أو كلمة المرور غير صحيح.');
    }
    if (lowerError.contains('user not found') || lowerError.contains('unknown user')) {
      return _text('User not found. Please check your email.', 'المستخدم غير موجود. يرجى التحقق من بريدك الإلكتروني.');
    }
    if (lowerError.contains('password') && lowerError.contains('incorrect')) {
      return _text('Incorrect password. Please try again.', 'كلمة المرور غير صحيحة. يرجى المحاولة مرة أخرى.');
    }
    if (lowerError.contains('account') && (lowerError.contains('locked') || lowerError.contains('disabled'))) {
      return _text('Your account is locked. Please contact administrator.', 'حسابك مقفل. يرجى الاتصال بالمسؤول.');
    }
    if (lowerError.contains('database') && lowerError.contains('not found')) {
      return _text('Database not found. Please check the database name.', 'قاعدة البيانات غير موجودة. يرجى التحقق من اسم قاعدة البيانات.');
    }
    if (lowerError.contains('connection') || lowerError.contains('timeout')) {
      return _text('Connection error. Please check your internet connection.', 'خطأ في الاتصال. يرجى التحقق من اتصال الإنترنت.');
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
        return _text('Checking server and loading databases...', 'جارٍ التحقق من الخادم وتحميل قواعد البيانات...');
      case 'db_listing_disabled':
        return _text('Database listing is disabled. Enter DB manually.', 'قائمة قواعد البيانات معطلة. أدخل قاعدة البيانات يدوياً.');
      case 'server_ok_single':
        return _text('Server OK. Ready to login.', 'الخادم جاهز. جاهز لتسجيل الدخول.');
      case 'server_ok_multiple':
        return _text('Server OK. Select a database and login.', 'الخادم جاهز. اختر قاعدة البيانات وقم بتسجيل الدخول.');
      case 'failed_fetch_db':
        return _text('$_statusMessageExtra', '$_statusMessageExtra');
      case 'logging_in':
        return _text('Logging in...', 'جارٍ تسجيل الدخول...');
      case 'verifying_2fa':
        return _text('Verifying two-factor code...', 'جارٍ التحقق من رمز المصادقة الثنائية...');
      case 'push_reg_failed':
        return _text('Logged in, but push registration failed: $_statusMessageExtra', 'تم تسجيل الدخول، لكن فشل تسجيل الإشعارات: $_statusMessageExtra');
      case '2fa_required':
        return _text('Two-factor code is required.', 'رمز المصادقة الثنائية مطلوب.');
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
        return _text('Server is not accessible. Please try again in a few minutes.', 'الخادم غير متاح. يرجى المحاولة مرة أخرى بعد بضع دقائق.');
      case 'db_not_selected':
        return _text('Please select a database.', 'يرجى اختيار قاعدة البيانات.');
      case 'db_not_found':
        return _text('Database not found. Please check the database name.', 'قاعدة البيانات غير موجودة. يرجى التحقق من اسم قاعدة البيانات.');
      case 'db_required':
        return _text('Database name is required.', 'اسم قاعدة البيانات مطلوب.');
      case 'checking_before_login':
        return _text('Verifying server and database...', 'جارٍ التحقق من الخادم وقاعدة البيانات...');
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
              if (result is Map &&
                  (uidString == null || uidString == 'null')) {
                setState(() {
                  _showTwoFactor = true;
                  _statusMessageKey = '2fa_required';
                  _statusMessageExtra = null;
                });
                final sessionId =
                    OdooApi.extractSessionIdFromHeaders(headers);
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
            initialUrl: LinkResolver.resolve(baseUrl, _pendingLink) ??
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
        _statusMessageExtra = errorMessage.isEmpty ? 'Authentication failed' : errorMessage;
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
                                if (hasMultipleDatabases)
                                  const SizedBox(height: 10),
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
                                      _text(
                                        'Forgot password?',
                                        'نسيت كلمة المرور؟',
                                      ),
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
                                    style: const TextStyle(
                                      color: Color(0xFFDC2626),
                                    ),
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
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        ),
                        child: Text(
                          _text(
                            'Terms & Conditions',
                            'الشروط والأحكام',
                          ),
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
              Text(_text(
                'Enter the authentication code from your app.',
                'أدخل رمز المصادقة من تطبيقك.',
              )),
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
      body: jsonEncode({
        'jsonrpc': '2.0',
        'method': 'call',
        'params': params,
      }),
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
          final errorMsg = resultError['message'] ?? resultError['data']?.toString() ?? 'Authentication failed';
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

  static String? extractSessionIdFromHeaders(
    Map<String, String> headers,
  ) {
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
    final resolvedUrl =
        url == session.baseUrl ? LinkResolver.webClientUrl(session.baseUrl) : url;
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
          initialUrl: resolvedUrl,
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
      final initialUri = await _appLinks.getInitialLink()
          .timeout(const Duration(seconds: 3));
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
  bool _logoutHandled = false;
  bool _loginHandled = false;

  @override
  void initState() {
    super.initState();
    final startUrl = widget.initialUrl ?? widget.baseUrl;
    _controller =
        WebViewController()
          ..setJavaScriptMode(JavaScriptMode.unrestricted)
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
                return NavigationDecision.navigate;
              },
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
        body: SafeArea(
          top: true,
          child: Stack(
            children: [
              WebViewWidget(controller: _controller),
              if (_loadingProgress < 100)
                LinearProgressIndicator(value: _loadingProgress / 100),
            ],
          ),
        ),
      ),
    );
  }
}
