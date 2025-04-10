import "dart:developer";

import 'package:flutter/material.dart';
import "package:logging/logging.dart";
import "package:odin_dart/odin_lib.dart";
import 'package:photos/core/configuration.dart';
import "package:photos/core/errors.dart";
import "package:photos/core/network/network.dart";
import "package:photos/generated/l10n.dart";
import "package:photos/l10n/l10n.dart";
import "package:photos/models/api/user/srp.dart";
import 'package:photos/services/account/user_service.dart';
import "package:photos/theme/ente_theme.dart";
import "package:photos/ui/account/login_pwd_verification_page.dart";
import 'package:photos/ui/common/dynamic_fab.dart';
import 'package:photos/ui/common/web_page.dart';
import "package:photos/utils/standalone/debouncer.dart";
import "package:styled_text/styled_text.dart";

class HomebaseLoginPage extends StatefulWidget {
  const HomebaseLoginPage({super.key});

  @override
  State<HomebaseLoginPage> createState() => _HomebaseLoginPageState();
}

class _HomebaseLoginPageState extends State<HomebaseLoginPage> {
  // final _config = Configuration.instance;
  bool _identityIsValid = false;
  String? _identity;
  Color? _identityInputFieldColor;
  final Logger _logger = Logger('_LoginPageState');
  final Debouncer _debouncer = Debouncer(const Duration(milliseconds: 500));

  void _onChanged(String value) {
    _debouncer.cancelDebounceTimer();
    _debouncer.run(() async {
      await updateIdentity(value);
      setState(() {});
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // if ((_config.getEmail() ?? '').isNotEmpty) {
    //   updateIdentity(_config.getEmail()!);
    // } else if (kDebugMode) {
    //   updateIdentity(const String.fromEnvironment("email"));
    // }
  }

  @override
  Widget build(BuildContext context) {
    final isKeypadOpen = MediaQuery.viewInsetsOf(context).bottom > 100;

    FloatingActionButtonLocation? fabLocation() {
      if (isKeypadOpen) {
        return null;
      } else {
        return FloatingActionButtonLocation.centerFloat;
      }
    }

    return Scaffold(
      resizeToAvoidBottomInset: isKeypadOpen,
      appBar: AppBar(
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          color: Theme.of(context).iconTheme.color,
          onPressed: () {
            Navigator.of(context).pop();
          },
        ),
      ),
      body: _getBody(),
      floatingActionButton: DynamicFAB(
        key: const ValueKey("logInButton"),
        isKeypadOpen: isKeypadOpen,
        isFormValid: _identityIsValid,
        buttonText: S.of(context).logInLabel,
        onPressedFunction: () async {
          await UserService.instance.setEmail(_identity!);
          Configuration.instance.resetVolatilePassword();
          SrpAttributes? attr;
          bool isEmailVerificationEnabled = true;
          try {
            attr = await UserService.instance.getSrpAttributes(_identity!);
            isEmailVerificationEnabled = attr.isEmailMFAEnabled;
          } catch (e) {
            if (e is! SrpSetupNotCompleteError) {
              _logger.severe('Error getting SRP attributes', e);
            }
          }
          if (attr != null && !isEmailVerificationEnabled) {
            // ignore: unawaited_futures
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (BuildContext context) {
                  return LoginPasswordVerificationPage(
                    srpAttributes: attr!,
                  );
                },
              ),
            );
          } else {
            await UserService.instance.sendOtt(
              context,
              _identity!,
              isCreateAccountScreen: false,
              purpose: "login",
            );
          }
          FocusScope.of(context).unfocus();
        },
      ),
      floatingActionButtonLocation: fabLocation(),
      floatingActionButtonAnimator: NoScalingAnimation(),
    );
  }

  Widget _getBody() {
    final l10n = context.l10n;
    return Column(
      children: [
        Expanded(
          child: AutofillGroup(
            child: ListView(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 30, horizontal: 20),
                  child: Text(
                    l10n.startWithHomebase,
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
                  child: TextFormField(
                    key: const ValueKey("homebaseIdentityField"),
                    decoration: InputDecoration(
                      fillColor: _identityInputFieldColor,
                      filled: true,
                      hintText: l10n.homebaseId,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 15,
                        vertical: 15,
                      ),
                      border: UnderlineInputBorder(
                        borderSide: BorderSide.none,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      suffixIcon: _identityIsValid
                          ? Icon(
                              Icons.check,
                              size: 20,
                              color: Theme.of(context).inputDecorationTheme.focusedBorder!.borderSide.color,
                            )
                          : null,
                    ),
                    onChanged: _onChanged,
                    autocorrect: false,
                    keyboardType: TextInputType.emailAddress,
                    initialValue: _identity,
                    autofocus: true,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  child: Divider(
                    thickness: 1,
                    color: getEnteColorScheme(context).strokeFaint,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Row(
                    children: [
                      Expanded(
                        flex: 5,
                        child: StyledText(
                          text: S.of(context).loginTerms,
                          style: Theme.of(context).textTheme.titleMedium!.copyWith(fontSize: 12),
                          tags: {
                            'u-terms': StyledTextActionTag(
                              (String? text, Map<String?, String?> attrs) => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (BuildContext context) {
                                    return WebPage(
                                      S.of(context).termsOfServicesTitle,
                                      "https://ente.io/terms",
                                    );
                                  },
                                ),
                              ),
                              style: const TextStyle(
                                decoration: TextDecoration.underline,
                              ),
                            ),
                            'u-policy': StyledTextActionTag(
                              (String? text, Map<String?, String?> attrs) => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (BuildContext context) {
                                    return WebPage(
                                      S.of(context).privacyPolicyTitle,
                                      "https://ente.io/privacy",
                                    );
                                  },
                                ),
                              ),
                              style: const TextStyle(
                                decoration: TextDecoration.underline,
                              ),
                            ),
                          },
                        ),
                      ),
                      const Expanded(
                        flex: 1,
                        child: SizedBox.shrink(),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const Padding(padding: EdgeInsets.all(8)),
      ],
    );
  }

  Future<void> updateIdentity(String value) async {
    _identityIsValid = await doCheckIdentity(value);
    if (_identityIsValid) {
      _identityInputFieldColor = const Color.fromRGBO(45, 194, 98, 0.2);
    } else {
      _identityInputFieldColor = getEnteColorScheme(context).fillFaint;
    }
  }
}

Future<bool> doCheckIdentity(String? odinId) async {
  if (odinId == null || odinId.isEmpty) return false;
  final dio = NetworkClient.instance.enteDio;
  final strippedIdentity = getDomainFromUrl(odinId);
  final domainRegex =
      RegExp(r'^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]{2,25}(?::\d{1,5})?$', caseSensitive: false);
  final isValid = domainRegex.hasMatch(strippedIdentity ?? '');

  if (!isValid) return false;

  try {
    final url = 'https://$strippedIdentity/api/guest/v1/auth/ident';
    final response = await dio.get(url);
    final validation = response.data as Map<String, dynamic>;
    return validation['odinId'].toLowerCase() == strippedIdentity;
  } catch (error) {
    log('Error checking identity', error: error);
    return false;
  }
}
