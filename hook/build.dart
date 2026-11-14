import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

Future<void> main(List<String> args) async {
  await build(args, (input, output) async {
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
      return;
    }
    if (path == null) {
      throw UnsupportedError(
        'Unsupported native target: '
        '${config.targetOS} / $architecture',
      );
    }
    final binary = input.packageRoot.resolve(path);
    if (!File.fromUri(binary).existsSync()) {
      throw StateError('Native decoder is missing: $path');
    }
    output.dependencies.add(binary);
    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: 'src/qr_decoder.g.dart',
        linkMode: DynamicLoadingBundled(),
        file: binary,
      ),
    );
  });
}
