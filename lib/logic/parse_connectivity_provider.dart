import 'package:parse_server_sdk_flutter/parse_server_sdk_flutter.dart';

class CustomParseConnectivityProvider extends ParseConnectivityProvider {
  @override
  Future<ParseConnectivityResult> checkConnectivity() =>
      Future.value(ParseConnectivityResult.wifi);

  @override
  Stream<ParseConnectivityResult> get connectivityStream =>
      const Stream<ParseConnectivityResult>.empty();
}
