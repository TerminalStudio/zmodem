import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zmodem/src/zmodem_frame.dart';
import 'package:zmodem/src/zmodem_parser.dart';
import 'package:zmodem/src/consts.dart' as consts;

void main() async {
  final session1Data = await File('test/fixture/session1.bin').readAsBytes();

  final session1Packets = [
    ZModemHeader(consts.ZSINIT, 0, 0, 0, 64),
    ZModemDataPacket(consts.ZCRCW, Uint8List(1)),
    ZModemHeader(consts.ZFILE, 0, 0, 0, 0),
    ZModemDataPacket(consts.ZCRCW, Uint8List(26)),
    ZModemHeader(consts.ZDATA, 0, 0, 0, 0),
    ZModemDataPacket(consts.ZCRCG, Uint8List(107)),
    ZModemDataPacket(consts.ZCRCE, Uint8List(0)),
    ZModemHeader(consts.ZEOF, 107, 0, 0, 0),
    ZModemHeader(consts.ZFIN, 0, 0, 0, 0),
  ];

  group('ZModemParser', () {
    test('works', () async {
      final parser = ZModemParser();
      parser.addData(session1Data);

      for (final expectedPacket in session1Packets) {
        expect(parser.moveNext(), isTrue);
        expectPacket(parser.current, expectedPacket);
      }
    });

    test('works byte by byte', () {
      final parser = ZModemParser();

      for (final byte in session1Data) {
        parser.addData(Uint8List.fromList([byte]));
      }

      for (final expectedPacket in session1Packets) {
        expect(parser.moveNext(), isTrue);
        expectPacket(parser.current, expectedPacket);
      }
    });
  });
}

/// Compares two [ZModemPacket]s. For convenience, [ZModemDataPacket]s are
/// compared by their [ZModemDataPacket.data] length instead of content.
void expectPacket(ZModemPacket actual, ZModemPacket expected) {
  if (actual is ZModemHeader) {
    final header = expected as ZModemHeader;
    expect(actual.type, header.type);
    expect(actual.p0, header.p0);
    expect(actual.p1, header.p1);
    expect(actual.p2, header.p2);
    expect(actual.p3, header.p3);
  } else if (actual is ZModemDataPacket) {
    final dataPacket = expected as ZModemDataPacket;
    expect(actual.type, dataPacket.type);
    expect(actual.data.length, dataPacket.data.length);
  } else {
    throw StateError('Unknown packet type');
  }
}
