import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';

import 'package:zmodem/src/util/string.dart';
import 'package:zmodem/src/zmodem_event.dart';
import 'package:zmodem/src/zmodem_fileinfo.dart';
import 'package:zmodem/src/zmodem_parser.dart';
import 'package:zmodem/src/zmodem_frame.dart';
import 'package:zmodem/src/consts.dart' as consts;

typedef ZModemTraceHandler = void Function(String message);

/// Contains the state of a ZModem session.
class ZModemCore {
  ZModemCore({required this.isSending, this.onTrace}) {
    if (isSending) {
      _enqueue(ZModemHeader.rqinit());
      _state = _ZRqinitState(this);
    } else {
      _enqueue(ZModemHeader.rinit());
      _state = _ZInitState(this);
    }
  }

  final bool isSending;

  final _parser = ZModemParser();

  final _sendQueue = Queue<ZModemPacket>();

  Uint8List? _attnSequence;

  late _ZModemState _state;

  bool get isFinished => _state is _ZFinState;

  final maxDataSubpacketSize = 1024;

  final ZModemTraceHandler? onTrace;

  Iterable<ZModemEvent> receive(Uint8List data) sync* {
    _parser.addData(data);
    // print('data: ${data.map((e) => e.toRadixString(16)).toList()}');

    while (_parser.moveNext()) {
      final packet = _parser.current;
      onTrace?.call('<- $packet');

      if (packet is ZModemHeader) {
        final event = _state.handleHeader(packet);
        if (event != null) {
          yield event;
        }
      } else if (packet is ZModemDataPacket) {
        final event = _state.handleDataSubpacket(packet);
        if (event != null) {
          yield event;
        }
      }
    }
  }

  void _enqueue(ZModemPacket packet) {
    _sendQueue.add(packet);
  }

  void _requireState<T extends _ZModemState>() {
    if (_state is! T) {
      throw ZModemException(
        'Invalid state: ${_state.runtimeType}, expected: $T',
      );
    }
  }

  bool get hasDataToSend => _sendQueue.isNotEmpty;

  Uint8List dataToSend() {
    final builder = BytesBuilder();

    while (_sendQueue.isNotEmpty) {
      onTrace?.call('-> ${_sendQueue.first}');
      builder.add(_sendQueue.removeFirst().encode());
    }

    return builder.toBytes();
  }

  void acceptFile([int offset = 0]) {
    _requireState<_ZReceivedFileProposalState>();
    _enqueue(ZModemHeader.rpos(offset));
    _state = _ZWaitingContentState(this);
  }

  void offerFile(ZModemFileInfo fileInfo) {
    _requireState<_ZReadyToSendState>();
    _enqueue(ZModemHeader.file());
    _enqueue(ZModemDataPacket.fileInfo(fileInfo));
    _state = ZSentFileProposalState(this);
  }

  void sendFileData(Uint8List data) {
    _requireState<_ZSendingContentState>();

    for (var i = 0; i < data.length; i += maxDataSubpacketSize) {
      final end = min(i + maxDataSubpacketSize, data.length);
      _enqueue(ZModemDataPacket.fileData(Uint8List.sublistView(data, i, end)));
    }
  }

  void finishFile(int offset) {
    _requireState<_ZSendingContentState>();
    _enqueue(ZModemDataPacket.fileData(Uint8List(0), eof: true));
    _enqueue(ZModemHeader.eof(offset));
    _state = _ZRqinitState(this);
  }

  void finishSession() {
    // _requireState<ZReadyToSendState>();
    // _enqueue(ZModemHeader.fin());
    _state = _ZFinState(this);
  }
}

class ZModemException implements Exception {
  ZModemException(this.message);

  final String message;

  @override
  String toString() => message;
}

abstract class _ZModemState {
  _ZModemState(this.core);

  final ZModemCore core;

  ZModemEvent? handleHeader(ZModemHeader header) {
    throw ZModemException('Unexpected header: $header (state: $this)');
  }

  ZModemEvent? handleDataSubpacket(ZModemDataPacket packet) {
    throw ZModemException('Unexpected data subpacket: $packet (state: $this)');
  }
}

class _ZInitState extends _ZModemState {
  _ZInitState(super.core);

  @override
  ZModemEvent? handleHeader(ZModemHeader header) {
    switch (header.type) {
      case consts.ZSINIT:
        core._enqueue(ZModemHeader.ack());
        core._state = _ZSinitState(core);
        break;
      case consts.ZFILE:
        core._state = _ZReceivedFileProposalState(core);
        break;
      case consts.ZFIN:
        core._enqueue(ZModemHeader.fin());
        core._state = _ZFinState(core);
        return ZSessionFinishedEvent();
      default:
        return super.handleHeader(header);
    }
    return null;
  }
}

class _ZSinitState extends _ZModemState {
  _ZSinitState(super.core);

  @override
  ZModemEvent? handleDataSubpacket(ZModemDataPacket packet) {
    if (packet.data.length <= 1) {
      core._attnSequence = null;
    } else {
      core._attnSequence = packet.data.sublist(1);
    }
    core._state = _ZInitState(core);
    return null;
  }
}

class _ZReceivedFileProposalState extends _ZModemState {
  _ZReceivedFileProposalState(super.core);

  @override
  ZModemEvent? handleDataSubpacket(ZModemDataPacket packet) {
    final pathname = readCString(packet.data, 0);
    final propertyString = readCString(packet.data, pathname.length + 1);
    final properties = propertyString.split(' ');

    final fileInfo = ZModemFileInfo(
      pathname: pathname,
      length: properties.isNotEmpty ? int.parse(properties[0]) : null,
      modificationTime: properties.length > 1 ? int.parse(properties[1]) : null,
      mode: properties.length > 2 ? properties[2] : null,
      filesRemaining: properties.length > 4 ? int.parse(properties[4]) : null,
      bytesRemaining: properties.length > 5 ? int.parse(properties[5]) : null,
    );

    return ZFileOfferedEvent(fileInfo);
  }
}

class _ZWaitingContentState extends _ZModemState {
  _ZWaitingContentState(super.core);

  @override
  ZModemEvent? handleHeader(ZModemHeader header) {
    switch (header.type) {
      case consts.ZDATA:
        core._state = _ZReceivingContentState(core);
        return null;
      default:
        return super.handleHeader(header);
    }
  }
}

class _ZReceivingContentState extends _ZModemState {
  _ZReceivingContentState(super.core);

  @override
  ZModemEvent? handleHeader(ZModemHeader header) {
    switch (header.type) {
      case consts.ZEOF:
        core._enqueue(ZModemHeader.rinit());
        core._state = _ZInitState(core);
        return ZFileReceivedEvent();
      default:
        return super.handleHeader(header);
    }
  }

  @override
  ZModemEvent? handleDataSubpacket(ZModemDataPacket packet) {
    return ZFileDataEvent(packet.data);
  }
}

class _ZRqinitState extends _ZModemState {
  _ZRqinitState(super.core);

  @override
  ZModemEvent? handleHeader(ZModemHeader header) {
    switch (header.type) {
      case consts.ZRINIT:
        core._state = _ZReadyToSendState(core);
        return ZReceiverReadyEvent();
      default:
        return super.handleHeader(header);
    }
  }
}

class _ZReadyToSendState extends _ZModemState {
  _ZReadyToSendState(super.core);
}

class ZSentFileProposalState extends _ZModemState {
  ZSentFileProposalState(super.core);

  @override
  ZModemEvent? handleHeader(ZModemHeader header) {
    switch (header.type) {
      case consts.ZRPOS:
        core._enqueue(ZModemHeader.data(0)); // TODO: parse p0 ~ p3
        core._state = _ZSendingContentState(core);
        return ZFileAcceptedEvent(header.p0); // TODO: parse p0 ~ p3
      case consts.ZSKIP:
        core._state = _ZReadyToSendState(core);
        return ZFileSkippedEvent();
      default:
        return super.handleHeader(header);
    }
  }
}

class _ZSendingContentState extends _ZModemState {
  _ZSendingContentState(super.core);
}

class _ZFinState extends _ZModemState {
  _ZFinState(super.core);
}