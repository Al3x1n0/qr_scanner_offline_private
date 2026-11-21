import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';

Future<void> main(List<String> args) => build(args, addBundledDecoder);

Future<void> addBundledDecoder(
  BuildInput input,
  BuildOutputBuilder output,
) async {
  if (!input.config.buildCodeAssets) return;
  final config = input.config.code;
  final architecture = config.targetArchitecture.name;
  String? path;
  if (config.targetOS == OS.android) {
    if (config.android.targetNdkApi < 24) {
      throw UnsupportedError(
        'The bundled Android decoder requires minSdk 24 or higher.',
      );
    }
    if (['arm', 'arm64', 'x64'].contains(architecture)) {
      path = 'native/android/$architecture/libqr_decoder.so';
    }
  } else if (config.targetOS == OS.iOS) {
    final sdk = config.iOS.targetSdk == IOSSdk.iPhoneOS
        ? 'device'
        : 'simulator';
    if ((sdk == 'device' && architecture == 'arm64') ||
        (sdk == 'simulator' && ['arm64', 'x64'].contains(architecture))) {
      path = 'native/ios/$sdk/$architecture/libqr_decoder.dylib';
    }
  } else {
    // Desktop hosts can run Flutter tests without loading the mobile decoder.
    return;
  }
  if (path == null) {
    throw UnsupportedError(
      'Unsupported native target: ${config.targetOS} / $architecture',
    );
  }

  final binary = File.fromUri(input.packageRoot.resolve(path));
  if (!await binary.exists()) {
    throw BuildError(message: 'Native decoder is missing: $path');
  }
  final manifest = File.fromUri(input.packageRoot.resolve('native/SHA256SUMS'));
  if (!await manifest.exists()) {
    throw BuildError(message: 'Native decoder checksum manifest is missing.');
  }
  final entries = (await manifest.readAsLines())
      .where((line) => line.endsWith('  $path'))
      .toList();
  final digest = await sha256.bind(binary.openRead()).first;
  if (entries.length != 1 || entries.single != '$digest  $path') {
    throw BuildError(message: 'Native decoder checksum mismatch for $path.');
  }

  output.dependencies.add(binary.uri);
  output.dependencies.add(manifest.uri);
  output.assets.code.add(
    CodeAsset(
      package: input.packageName,
      name: 'src/qr_decoder.g.dart',
      linkMode: DynamicLoadingBundled(),
      file: binary.uri,
    ),
  );
}
