import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';

import 'package:zmodem/src/util/string.dart';
import 'package:zmodem/src/zmodem_event.dart';
import 'package:zmodem/src/zmodem_fileinfo.dart';
import 'package:zmodem/src/zmodem_parser.dart';
import 'package:zmodem/src/zmodem_frame.dart';
import 'package:zmodem/src/consts.dart' as consts;

/// Contains the state of a ZModem session.
class ZModemCore {
  ZModemCore({required this.isSending}) {
    if (isSending) {
      _enqueue(ZModemHeader.rqinit());
      _state = ZRqinitState(this);
    } else {
      _enqueue(ZModemHeader.rinit());
      _state = ZInitState(this);
    }
  }

  final bool isSending;

  final _parser = ZModemParser();

  final _sendQueue = Queue<ZModemPacket>();

  Uint8List? _attnSequence;

  late ZModemState _state;

  bool get isFinished => _state is ZFinState;

  final maxDataSubpacketSize = 1024;

  Iterable<ZModemEvent> receive(Uint8List data) sync* {
    _parser.addData(data);
    // print('data: ${data.map((e) => e.toRadixString(16)).toList()}');

    while (_parser.moveNext()) {
      final packet = _parser.current;
      // print('packet: $packet');

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
    print('enqueue: $packet');
    _sendQueue.add(packet);
  }

  void _requireState<T extends ZModemState>() {
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
      // print('sending: ${_sendQueue.first}');
      builder.add(_sendQueue.removeFirst().encode());
    }

    return builder.toBytes();
  }

  void acceptFile([int offset = 0]) {
    _requireState<ZReceivedFileProposalState>();
    _enqueue(ZModemHeader.rpos(offset));
    _state = ZWaitingContentState(this);
  }

  void offerFile(ZModemFileInfo fileInfo) {
    _requireState<ZReadyToSendState>();
    _enqueue(ZModemHeader.file());
    _enqueue(ZModemDataPacket.fileInfo(fileInfo));
    _state = ZSentFileProposalState(this);
  }

  void sendFileData(Uint8List data) {
    _requireState<ZSendingContentState>();
    for (var i = 0; i < data.length; i += maxDataSubpacketSize) {
      final end = min(i + maxDataSubpacketSize, data.length);
      _enqueue(ZModemDataPacket.fileData(Uint8List.sublistView(data, i, end)));
    }
  }

  void finishFile(int offset) {
    _requireState<ZSendingContentState>();
    _enqueue(ZModemHeader.eof(offset));
    _state = ZRqinitState(this);
  }

  void finishSession() {
    // _requireState<ZReadyToSendState>();
    _enqueue(ZModemHeader.fin());
    _state = ZFinState(this);
  }
}

class ZModemException implements Exception {
  ZModemException(this.message);

  final String message;

  @override
  String toString() => message;
}

abstract class ZModemState {
  ZModemState(this.core);

  final ZModemCore core;

  ZModemEvent? handleHeader(ZModemHeader header) {
    throw ZModemException('Unexpected header: $header (state: $this)');
  }

  ZModemEvent? handleDataSubpacket(ZModemDataPacket packet) {
    throw ZModemException('Unexpected data subpacket: $packet (state: $this)');
  }
}

class ZInitState extends ZModemState {
  ZInitState(super.core);

  @override
  ZModemEvent? handleHeader(ZModemHeader header) {
    switch (header.type) {
      case consts.ZSINIT:
        core._enqueue(ZModemHeader.ack());
        core._state = ZSinitState(core);
        break;
      case consts.ZFILE:
        core._state = ZReceivedFileProposalState(core);
        break;
      case consts.ZFIN:
        core._enqueue(ZModemHeader.fin());
        core._state = ZFinState(core);
        return ZSessionFinishedEvent();
      default:
        return super.handleHeader(header);
    }
    return null;
  }
}

class ZSinitState extends ZModemState {
  ZSinitState(super.core);

  @override
  ZModemEvent? handleDataSubpacket(ZModemDataPacket packet) {
    if (packet.data.length <= 1) {
      core._attnSequence = null;
    } else {
      core._attnSequence = packet.data.sublist(1);
    }
    core._state = ZInitState(core);
    return null;
  }
}

class ZReceivedFileProposalState extends ZModemState {
  ZReceivedFileProposalState(super.core);

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

class ZWaitingContentState extends ZModemState {
  ZWaitingContentState(super.core);

  @override
  ZModemEvent? handleHeader(ZModemHeader header) {
    switch (header.type) {
      case consts.ZDATA:
        core._state = ZReceivingContentState(core);
        return null;
      default:
        return super.handleHeader(header);
    }
  }
}

class ZReceivingContentState extends ZModemState {
  ZReceivingContentState(super.core);

  @override
  ZModemEvent? handleHeader(ZModemHeader header) {
    switch (header.type) {
      case consts.ZEOF:
        core._enqueue(ZModemHeader.rinit());
        core._state = ZInitState(core);
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

class ZRqinitState extends ZModemState {
  ZRqinitState(super.core);

  @override
  ZModemEvent? handleHeader(ZModemHeader header) {
    switch (header.type) {
      case consts.ZRINIT:
        core._state = ZReadyToSendState(core);
        return ZReceiverReadyEvent();
      default:
        return super.handleHeader(header);
    }
  }
}

class ZReadyToSendState extends ZModemState {
  ZReadyToSendState(super.core);
}

class ZSentFileProposalState extends ZModemState {
  ZSentFileProposalState(super.core);

  @override
  ZModemEvent? handleHeader(ZModemHeader header) {
    switch (header.type) {
      case consts.ZRPOS:
        core._enqueue(ZModemHeader.data(0)); // TODO: parse p0 ~ p3
        core._state = ZSendingContentState(core);
        return ZFileAcceptedEvent(header.p0); // TODO: parse p0 ~ p3
      case consts.ZSKIP:
        core._state = ZReadyToSendState(core);
        return ZFileSkippedEvent();
      default:
        return super.handleHeader(header);
    }
  }
}

class ZSendingContentState extends ZModemState {
  ZSendingContentState(super.core);
}

class ZFinState extends ZModemState {
  ZFinState(super.core);
}
