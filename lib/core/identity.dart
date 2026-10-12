import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:basic_utils/basic_utils.dart';
import 'package:pointycastle/export.dart';

import 'models.dart';

Map<String, String> generateIdentity() {
  final keys = CryptoUtils.generateRSAKeyPair();
  final private = keys.privateKey as RSAPrivateKey;
  final public = keys.publicKey as RSAPublicKey;
  final id = randomToken(16);
  final csr = X509Utils.generateRsaCsrPem({'CN': 'nearbridge-$id'}, private, public);
  return {'id': id, 'key': CryptoUtils.encodeRSAPrivateKeyToPem(private),
    'certificate': X509Utils.generateSelfSignedCertificate(private, csr, 3650,
      sans: ['nearbridge.local'], cA: false)};
}

class Identity {
  Identity(this.id, this.key, this.certificate);
  final String id;
  final String key;
  final String certificate;
  String get fingerprint => certificateFingerprint(certificate);

  SecurityContext get context => SecurityContext()
    ..useCertificateChainBytes(utf8.encode(certificate))
    ..usePrivateKeyBytes(utf8.encode(key));

  static Future<Identity> load(Directory directory) async {
    await directory.create(recursive: true);
    if (!Platform.isWindows && !Platform.isAndroid) {
      final result = await Process.run('chmod', ['700', directory.path]);
      if (result.exitCode != 0) throw StateError('Cannot protect device keys');
    }
    final file = File('${directory.path}/identity.json');
    Map<String, dynamic> data;
    if (await file.exists()) {
      data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    } else {
      data = await Isolate.run(generateIdentity);
      await file.writeAsString(jsonEncode(data), flush: true);
    }
    return Identity(data['id'] as String, data['key'] as String,
      data['certificate'] as String);
  }
}
