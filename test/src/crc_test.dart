import 'package:test/test.dart';
import 'package:zmodem/src/crc.dart';

void main() {
  group('CRC16', () {
    test('case 1', () {
      final crc = CRC16()
        ..update(0x00)
        ..update(0x00)
        ..update(0x00)
        ..update(0x00)
        ..update(0x00)
        ..finalize();

      expect(crc.value.toRadixString(16), '0');
    });

    test('case 2', () {
      final crc = CRC16()
        ..update(0x01)
        ..update(0x00)
        ..update(0x00)
        ..update(0x00)
        ..update(0x23)
        ..finalize();

      expect(crc.value.toRadixString(16), 'be50');
    });
  });
}
