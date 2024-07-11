// ignore_for_file: curly_braces_in_flow_control_structures

import 'dart:typed_data';

import 'package:zmodem/src/buffer.dart';
import 'package:zmodem/src/consts.dart' as consts;
import 'package:zmodem/src/zmodem_frame.dart';

class ZModemParser implements Iterator<ZModemPacket> {
  final _buffer = ChunkBuffer();

  late final Iterator<ZModemPacket?> _parser = _createParser().iterator;

  void Function(int)? onPlainText;

  ZModemPacket? _current;

  /// The last parsed packet.
  @override
  ZModemPacket get current {
    if (_current == null) {
      throw StateError('No event has been parsed yet');
    }
    return _current!;
  }

  /// Adds more data to the buffer for the parser to consume. Call [moveNext]
  /// after this to parse the next packet.
  void addData(Uint8List data) {
    _buffer.add(data);
  }

  /// Let the parser parse the next packet. Returns true if a packet is parsed.
  /// After returning true, the [current] property will be set to the parsed
  /// packet.
  @override
  bool moveNext() {
    _parser.moveNext();

    final packet = _parser.current;

    if (packet == null) {
      return false;
    }

    _current = packet;
    return true;
  }

  var _expectDataSubpacket = false;

  /// Tells the parser to expect the next packet to be a data subpacket.
  ///
  /// This is necessary because lrzsz produces plain text beween ZMODEM frames
  /// and it's impossible to distinguish between plain text and a data subpacket
  /// without this prompt....
  void expectDataSubpacket() {
    _expectDataSubpacket = true;
  }

  /// Creates an instance of zmodem parser.
  ///
  /// This uses the sync* generator syntax to be able to yield when no enough
  /// data is available and resume the context later when more data is added.
  ///
  /// The returned iterator yields null when no enough data is available and
  /// yields a [ZModemPacket] when a packet is parsed.
  Iterable<ZModemPacket?> _createParser() sync* {
    while (true) {
      if (_expectDataSubpacket) {
        _expectDataSubpacket = false;
        yield* _parseDataSubpacket();
        continue;
      }

      while (_buffer.length < 4) {
        yield null;
      }

      if (_buffer.peek() == consts.ZPAD) {
        if (_buffer.peek(1) == consts.ZPAD &&
            _buffer.peek(2) == consts.ZDLE &&
            _buffer.peek(3) == consts.ZHEX) {
          _buffer.expect(consts.ZPAD);
          _buffer.expect(consts.ZPAD);
          _buffer.expect(consts.ZDLE);
          _buffer.expect(consts.ZHEX);
          yield* _parseHexHeader();
          continue;
        }

        if (_buffer.peek(1) == consts.ZDLE && _buffer.peek(2) == consts.ZBIN) {
          _buffer.expect(consts.ZPAD);
          _buffer.expect(consts.ZDLE);
          _buffer.expect(consts.ZBIN);
          yield* _parseBinaryPacket();
          continue;
        }
      }

      _handleDirtyChar(_buffer.readByte());
    }
  }

  void _handleDirtyChar(int byte) {
    if (byte == consts.XON) {
      return;
    }
    onPlainText?.call(byte);
  }

  Iterable<ZModemPacket?> _parseHexHeader() sync* {
    const asciiFields = 1 + 4 + 2;
    const headerLength = asciiFields * 2;

    // Hex header has fixed length, so we can check the length before reading.
    while (_buffer.length < headerLength) {
      yield null;
    }

    final frameType = _buffer.readAsciiByte();
    final p0 = _buffer.readAsciiByte();
    final p1 = _buffer.readAsciiByte();
    final p2 = _buffer.readAsciiByte();
    final p3 = _buffer.readAsciiByte();
    final crc0 = _buffer.readAsciiByte();
    final crc1 = _buffer.readAsciiByte();

    while (_buffer.isEmpty) {
      yield null;
    }

    // Consume the optional CR before the LF.
    if (_buffer.peek() == consts.CR) {
      _buffer.readByte();

      while (_buffer.isEmpty) {
        yield null;
      }
    }

    // _buffer.expect(consts.LF);
    _buffer.expect(0x8a);

    yield ZModemHeader(frameType, p0, p1, p2, p3);
  }

  Iterable<ZModemPacket?> _parseBinaryPacket() sync* {
    // Binary header has variable length, though it always has at least 7 bytes.
    while (_buffer.length < 7) {
      yield null;
    }

    while (!_buffer.hasEscaped) yield null;
    final frameType = _buffer.readEscaped()!;

    while (!_buffer.hasEscaped) yield null;
    final p0 = _buffer.readEscaped()!;

    while (!_buffer.hasEscaped) yield null;
    final p1 = _buffer.readEscaped()!;

    while (!_buffer.hasEscaped) yield null;
    final p2 = _buffer.readEscaped()!;

    while (!_buffer.hasEscaped) yield null;
    final p3 = _buffer.readEscaped()!;

    while (!_buffer.hasEscaped) yield null;
    final crc0 = _buffer.readEscaped()!;

    while (!_buffer.hasEscaped) yield null;
    final crc1 = _buffer.readEscaped()!;

    yield ZModemHeader(frameType, p0, p1, p2, p3);
  }

  Iterable<ZModemPacket?> _parseDataSubpacket() sync* {
    final buffer = BytesBuilder();

    while (true) {
      final char = _buffer.readEscaped();

      if (char == null) {
        yield null;
        continue;
      }

      switch (char) {
        case consts.ZCRCE | consts.ZDLEESC:
        case consts.ZCRCG | consts.ZDLEESC:
        case consts.ZCRCQ | consts.ZDLEESC:
        case consts.ZCRCW | consts.ZDLEESC:
          while (!_buffer.hasEscaped) yield null;
          final crc0 = _buffer.readEscaped();

          while (!_buffer.hasEscaped) yield null;
          final crc1 = _buffer.readEscaped();

          final type = char ^ consts.ZDLEESC;
          yield ZModemDataPacket(type, buffer.takeBytes());
          return;
        default:
          buffer.addByte(char);
          continue;
      }
    }
  }
}

extension _ChunkBufferExtensions on ChunkBuffer {
  static int _toHex(int char) {
    if (char >= 0x30 && char <= 0x39) {
      return char - 0x30;
    } else if (char >= 0x41 && char <= 0x46) {
      return char - 0x41 + 10;
    } else if (char >= 0x61 && char <= 0x66) {
      return char - 0x61 + 10;
    } else {
      throw ArgumentError.value(char, 'char', 'Not a hex character');
    }
  }

  int readAsciiByte() {
    final high = _toHex(readByte());
    final low = _toHex(readByte());
    return high * 16 + low;
  }

  /// Reads a byte from the buffer, escaping it if necessary. This operation
  /// may consume more than one byte from the buffer if the byte is escaped.
  /// Returns `null` if the buffer is empty or if the buffer contains only
  /// the escape character.
  int? readEscaped() {
    if (isEmpty) {
      return null;
    }

    if (peek() != consts.ZDLE) {
      return readByte();
    }

    if (length < 2) {
      return null;
    }

    expect(consts.ZDLE);
    final byte = readByte();

    switch (byte) {
      case consts.ZCRCE:
      case consts.ZCRCG:
      case consts.ZCRCQ:
      case consts.ZCRCW:
        return byte | consts.ZDLEESC;
      case consts.ZRUB0:
        return 0x7f;
      case consts.ZRUB1:
        return 0xff;
      default:
        return byte ^ 0x40;
    }
  }

  bool get hasEscaped {
    final next = peek();

    if (next == consts.ZDLE) {
      return length >= 2;
    } else {
      return length >= 1;
    }
  }
}
