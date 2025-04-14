import 'dart:async';
import 'dart:developer';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import "package:flutter_web_auth_2/flutter_web_auth_2.dart";
import "package:odin_dart/odin_lib.dart";

/// Secure Storage Constants
const String _appAuthToken = 'APP_AUTH_TOKEN';
const String _appSharedSecret = 'APP_SHARED_SECRET';
const String _appIdentity = 'IDENTITY';

final DotYouClient dotYouClient = DotYouClient.create(
  const ProviderOptions(
    hostIdentity: '',
  ),
);

const _appPermissions = [
  AppPermissionType.readConnections,
  AppPermissionType.readConnectionRequests,
  AppPermissionType.readCircleMembers,
  AppPermissionType.sendPushNotifications,
];

/// Target Drive for requesting StandardprofileInfo
const TargetDrive standardProfileInfoDrive = TargetDrive(
  alias: '8f12d8c4933813d378488d91ed23b64c',
  type: '597241530e3ef24b28b9a75ec3a5c45c',
);

/// Standard Profile Info to fetch information of your own user
const String standardProfileInfo = '5ae0c1c8a5260bc7b6648f6fbd115c35';
const int profileDataType = 77;
const appId = '4ef49282-a1d3-47ad-9128-f6c4cc86373a';

const TargetDrive photoDrive = TargetDrive(
  alias: '6483b7b1f71bd43eb6896c86148668cc',
  type: '2af68fe72fb84896f39f97c59d60813a',
);

final AuthenticationProvider authenticationProvider = AuthenticationProvider(dotYouClient);

class AuthenticationNotifier {
  final AuthenticationProvider _authenticationProvider;
  final FlutterSecureStorage _storage;

  AuthenticationNotifier({
    AuthenticationProvider? authProvider,
    FlutterSecureStorage? storage,
  })  : _storage = const FlutterSecureStorage(), // _storage = storage ?? const FlutterSecureStorage(),
        _authenticationProvider = authenticationProvider;

  /// Contains the list of drives we need access too
  final List<TargetDriveAccessRequest> _drives = [
    TargetDriveAccessRequest(
      alias: photoDrive.alias,
      type: photoDrive.type,
      name: 'Photo Library',
      description: 'Place for your memories',
      permissions: [DrivePermissionType.read, DrivePermissionType.write, DrivePermissionType.react],
    ),
    TargetDriveAccessRequest(
      alias: standardProfileInfoDrive.alias,
      type: standardProfileInfoDrive.type,
      name: '',
      description: '',
      permissions: [DrivePermissionType.read, DrivePermissionType.write],
    ),
  ];

  String returnUrl() {
    if (kIsWeb) {
      final currentUri = Uri.base;
      final redirectUri = Uri(
        host: currentUri.host,
        scheme: currentUri.scheme,
        port: currentUri.port,
        path: '/chat/auth.html',
        queryParameters: {},
      );

      return redirectUri.toString();
    } else {
      return 'homebase://?';
    }
  }

  String _regUrl(String domain, YouAuthorizationParams params) {
    final uri = Uri(
      scheme: 'https',
      host: domain,
      path: 'api/owner/v1/youauth/authorize',
      queryParameters: params.toMap(),
    );
    return uri.toString();
  }

  Future<bool> youAuthRegistration(String domain) async {
    final deviceInfoPlugin = DeviceInfoPlugin();
    late final BaseDeviceInfo deviceInfo;

    final eccKey = await createEccPair();

    if (kIsWeb) {
      deviceInfo = await deviceInfoPlugin.webBrowserInfo;
    } else {
      deviceInfo = switch (Platform.operatingSystem) {
        ('android') => await deviceInfoPlugin.androidInfo,
        ('ios') => await deviceInfoPlugin.iosInfo,
        ('windows') => await deviceInfoPlugin.windowsInfo,
        ('linux') => await deviceInfoPlugin.linuxInfo,
        ('macos') => await deviceInfoPlugin.macOsInfo,
        String() => throw UnsupportedError('${Platform.operatingSystem} not supported'),
      };
    }

    final String deviceName = deviceInfo.data['device'] ?? deviceInfo.data['name'] ?? deviceInfo.data['userAgent'];

    final authorizationParams = await _authenticationProvider.getRegistrationParams(
      returnUrl: returnUrl(),
      appName: 'Ente Photos - Powered by Homebase',
      appId: appId,
      publicKey: eccKey.publicKey,
      drives: _drives,
      circleDrives: [],
      host: kIsWeb ? domain : null,
      clientFriendlyName: deviceName,
      permissionKeys: _appPermissions.map((e) => e.value).toList(),
      userAgent: deviceName,
    );
    log("${authorizationParams.toMap()}");
    log("url ${_regUrl(domain, authorizationParams)}");

    final result = await FlutterWebAuth2.authenticate(
      url: _regUrl(domain, authorizationParams),
      callbackUrlScheme: 'ente',
      options: const FlutterWebAuth2Options(
        preferEphemeral: true,
      ),
    );
    final Map<String, dynamic> queryParams = Uri.parse(result).queryParameters;
    final identity = queryParams['identity'];
    final publicKey = queryParams['public_key'];
    final salt = queryParams['salt'];
    // final state = queryParams['state'];

    final (String clientAuthToken, String sharedSecret) = await _authenticationProvider.finalizeAuthentication(
      identity: identity,
      privateKey: eccKey.privateKey,
      publicKey: publicKey,
      salt: salt,
    );

    await _storage.write(key: _appIdentity, value: identity);
    await _storage.write(key: _appSharedSecret, value: sharedSecret);
    await _storage.write(key: _appAuthToken, value: clientAuthToken);
    await _storage.write(key: _appIdentity, value: identity);
    await _storage.write(key: _appSharedSecret, value: sharedSecret);
    await _storage.write(key: _appAuthToken, value: clientAuthToken);

    // ref.read(tokensProvider.notifier).update((state) => appData);

    return true;
  }

  Future<void> unRegisterClient() async {
    await _authenticationProvider.logOut();

    await Future.wait([
      _storage.delete(key: _appIdentity),
      _storage.delete(key: _appAuthToken),
      _storage.delete(key: _appSharedSecret),
      _storage.delete(key: _appIdentity),
      _storage.delete(key: _appAuthToken),
      _storage.delete(key: _appSharedSecret),
    ]);
  }

  /// Whether it has a valid Token or not
  Future<bool> verifyToken() async {
    return await _authenticationProvider.hasValidToken().onError((error, stackTrace) {
      log('Error while verifying token', error: error, stackTrace: stackTrace);
      if (error is DioException) {
        if (error.error is SocketException) {
          return true;
        }
      }
      return false;
    });
  }
}
