import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks/hooks.dart';

import '../hook/build.dart';

const _androidArm64 = 'native/android/arm64/libqr_decoder.so';
const _manifest = 'native/SHA256SUMS';

void main() {
  late Directory scratch;

  setUp(() async {
    scratch = await Directory.systemTemp.createTemp('decoder_hook_test');
  });

  tearDown(() async {
    await scratch.delete(recursive: true);
  });

  test('registers the verified decoder and both cache dependencies', () async {
    final root = Directory.current.uri;
    final output = BuildOutputBuilder();

    await addBundledDecoder(_androidInput(root, scratch.uri), output);

    final result = BuildOutput(output.json);
    expect(result.assets.code.single.file, root.resolve(_androidArm64));
    expect(
      result.dependencies,
      unorderedEquals([root.resolve(_androidArm64), root.resolve(_manifest)]),
    );
  });

  test('rejects a decoder whose bytes differ from the manifest', () async {
    final binary = File.fromUri(scratch.uri.resolve(_androidArm64));
    await binary.create(recursive: true);
    await binary.writeAsBytes([1, 2, 3]);
    await File(_manifest).copy(scratch.uri.resolve(_manifest).toFilePath());
    final output = BuildOutputBuilder();

    await expectLater(
      addBundledDecoder(_androidInput(scratch.uri, scratch.uri), output),
      throwsA(
        isA<BuildError>().having(
          (error) => error.message,
          'message',
          'Native decoder checksum mismatch for $_androidArm64.',
        ),
      ),
    );
    expect(BuildOutput(output.json).assets.code, isEmpty);
  });
}

BuildInput _androidInput(Uri root, Uri scratch) {
  final builder = BuildInputBuilder()
    ..setupShared(
      packageRoot: root,
      packageName: 'qr_scanner_offline_private',
      outputDirectoryShared: scratch,
      outputFile: scratch.resolve('output.json'),
    );
  builder.config.setupBuild(linkingEnabled: false);
  builder.addExtension(
    CodeAssetExtension(
      targetArchitecture: Architecture.arm64,
      targetOS: OS.android,
      linkModePreference: LinkModePreference.dynamic,
      android: AndroidCodeConfig(targetNdkApi: 24),
    ),
  );
  return builder.build();
}
