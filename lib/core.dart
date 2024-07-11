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

typedef ZModemTextHandler = void Function(int char);

/// Contains the state of a ZModem session.
class ZModemCore {
  ZModemCore({this.onTrace, this.onPlainText});

  late final _parser = ZModemParser()..onPlainText = onPlainText;

  final _sendQueue = Queue<ZModemPacket>();

  // ignore: unused_field
  Uint8List? _attnSequence;

  late _ZModemState _state = _ZInitState(this);

  bool get isFinished => _state is _ZFinState;

  final maxDataSubpacketSize = 8192;

  final ZModemTraceHandler? onTrace;

  final ZModemTextHandler? onPlainText;

  bool _findSubSeq(Uint8List origin, Uint8List subSeq) {
    // 如果 b 是空数组，直接返回 true
    if (subSeq.isEmpty) return true;

    // 如果 a 的长度小于 b 的长度，直接返回 false
    if (origin.length < subSeq.length) return false;

    // 遍历 a 数组，检查是否存在连续的子序列与 b 相等
    for (int i = 0; i <= origin.length - subSeq.length; i++) {
      bool match = true;
      for (int j = 0; j < subSeq.length; j++) {
        if (origin[i + j] != subSeq[j]) {
          match = false;
          break;
        }
      }
      if (match) return true;
    }

    return false;
  }

  Iterable<ZModemEvent> receive(Uint8List data) sync* {
    if (_findSubSeq(data, ZModemAbortSequence.abortSequence)) {
      yield ZSessionAbortedEvent();
    }
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

  void _expectDataSubpacket() {
    _parser.expectDataSubpacket();
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

  void initiateSend() {
    _requireState<_ZInitState>();
    _enqueue(ZModemHeader.rqinit());
    _state = _ZRqinitState(this);
  }

  void initiateReceive() {
    _requireState<_ZInitState>();
    _enqueue(ZModemHeader.rinit());
    _state = _ZRinitState(this);
  }

  void acceptFile([int offset = 0]) {
    _requireState<_ZReceivedFileProposalState>();
    _enqueue(ZModemHeader.rpos(offset));
    _state = _ZWaitingContentState(this);
  }

  void skipFile() {
    _requireState<_ZReceivedFileProposalState>();
    _enqueue(ZModemHeader.skip());
    _state = _ZRinitState(this);
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

  void finishSending(int offset) {
    _requireState<_ZSendingContentState>();
    _enqueue(ZModemDataPacket.fileData(Uint8List(0), eof: true));
    _enqueue(ZModemHeader.eof(offset));
    _state = _ZRqinitState(this);
  }

  void finishSession() {
    if (_state is _ZClosedState || _state is _ZFinState) {
      return;
    }

    _enqueue(ZModemHeader.fin());
    _state = _ZClosedState(this);
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

/// A state where no messages have been sent or received yet. Waiting for
/// our or the other side to initiate the session.
class _ZInitState extends _ZModemState {
  _ZInitState(super.core);

  @override
  ZModemEvent? handleHeader(ZModemHeader header) {
    switch (header.type) {
      case consts.ZRINIT:
        core._state = _ZReadyToSendState(core);
        return ZReadyToSendEvent();
      case consts.ZRQINIT:
        core._enqueue(ZModemHeader.rinit());
        core._state = _ZRinitState(core);
        return null;
      default:
        return super.handleHeader(header);
    }
  }
}

/// A state where we have requested a file transfer and waiting a file proposal.
class _ZRinitState extends _ZModemState {
  _ZRinitState(super.core);

  @override
  ZModemEvent? handleHeader(ZModemHeader header) {
    switch (header.type) {
      case consts.ZSINIT:
        core._enqueue(ZModemHeader.ack());
        core._state = _ZSinitState(core);
        core._expectDataSubpacket();
        break;
      case consts.ZFILE:
        core._state = _ZReceivedFileProposalState(core);
        core._expectDataSubpacket();
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

/// A state where the other side is going to send us the attn sequence.
class _ZSinitState extends _ZModemState {
  _ZSinitState(super.core);

  @override
  ZModemEvent? handleDataSubpacket(ZModemDataPacket packet) {
    if (packet.data.length <= 1) {
      core._attnSequence = null;
    } else {
      core._attnSequence = packet.data.sublist(1);
    }
    core._state = _ZRinitState(core);
    return null;
  }
}

/// A state where we've got a file proposal, but haven't decided whether to
/// accept it or not.
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

/// A state where we've accepted a file proposal, but haven't received the ZDATA
/// header yet.
class _ZWaitingContentState extends _ZModemState {
  _ZWaitingContentState(super.core);

  @override
  ZModemEvent? handleHeader(ZModemHeader header) {
    switch (header.type) {
      case consts.ZDATA:
        core._state = _ZReceivingContentState(core);
        core._expectDataSubpacket();
        return null;
      default:
        return super.handleHeader(header);
    }
  }
}

/// A state where we've received the ZDATA header, and are receiving the file
/// contents.
class _ZReceivingContentState extends _ZModemState {
  _ZReceivingContentState(super.core);

  @override
  ZModemEvent? handleHeader(ZModemHeader header) {
    switch (header.type) {
      case consts.ZEOF:
        core._enqueue(ZModemHeader.rinit());
        core._state = _ZRinitState(core);
        return ZFileEndEvent();
      default:
        return super.handleHeader(header);
    }
  }

  @override
  ZModemEvent? handleDataSubpacket(ZModemDataPacket packet) {
    if (packet.type == consts.ZCRCG || packet.type == consts.ZCRCQ) {
      core._expectDataSubpacket();
    }
    return ZFileDataEvent(packet.data);
  }
}

/// A state where we've requested the other side to receive a file from us, but
/// haven't been notified that it's ready yet.
class _ZRqinitState extends _ZModemState {
  _ZRqinitState(super.core);

  @override
  ZModemEvent? handleHeader(ZModemHeader header) {
    switch (header.type) {
      case consts.ZRINIT:
        core._state = _ZReadyToSendState(core);
        return ZReadyToSendEvent();
      default:
        return super.handleHeader(header);
    }
  }
}

/// A state where the other side has notified us that it's ready to receive a
/// file from us.
class _ZReadyToSendState extends _ZModemState {
  _ZReadyToSendState(super.core);

  @override
  ZModemEvent? handleHeader(ZModemHeader header) {
    switch (header.type) {
      case consts.ZRINIT:
        // Ignore delayed ZRINIT retry.
        return null;
      default:
        return super.handleHeader(header);
    }
  }
}

/// A state where we've sent a file proposal, but haven't received a response
/// from the other side yet.
class ZSentFileProposalState extends _ZModemState {
  ZSentFileProposalState(super.core);

  @override
  ZModemEvent? handleHeader(ZModemHeader header) {
    switch (header.type) {
      case consts.ZRINIT:
        // Ignore delayed ZRINIT retry.
        return null;
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

/// A state where we've sent the ZDATA header, and are sending chunks of file
/// contents.
class _ZSendingContentState extends _ZModemState {
  _ZSendingContentState(super.core);
}

/// A state where we as the sender have sent the ZFIN header, and are waiting
/// for the other side to acknowledge it.
class _ZClosedState extends _ZModemState {
  _ZClosedState(super.core);

  @override
  ZModemEvent? handleHeader(ZModemHeader header) {
    switch (header.type) {
      case consts.ZFIN:
        core._enqueue(ZModemOverAndOut());
        core._state = _ZFinState(core);
        return ZSessionFinishedEvent();
    }
    return null;
  }
}

/// A state where the session is fully closed.
class _ZFinState extends _ZModemState {
  _ZFinState(super.core);
}
