import 'package:zmodem/src/util/debug.dart';
import 'package:zmodem/src/zmodem_fileinfo.dart';

abstract class ZModemEvent {}

/// The other side has offered a file for transfer.
class ZFileOfferedEvent implements ZModemEvent {
  final ZModemFileInfo fileInfo;

  ZFileOfferedEvent(this.fileInfo);

  @override
  String toString() {
    return DebugStringBuilder('ZFileOfferedEvent')
        .withField('fileInfo', fileInfo)
        .toString();
  }
}

/// A chunk of data of the file currently being received.
class ZFileDataEvent implements ZModemEvent {
  final List<int> data;

  ZFileDataEvent(this.data);

  @override
  String toString() {
    return DebugStringBuilder('ZFileDataEvent')
        .withField('data', data.length)
        .toString();
  }
}

/// The file we're currently receiving has been completely transferred.
class ZFileEndEvent implements ZModemEvent {
  @override
  String toString() {
    return 'ZFileEndEvent()';
  }
}

/// The event fired when the ZModem session is fully closed.
class ZSessionFinishedEvent implements ZModemEvent {
  @override
  String toString() {
    return 'ZSessionFinishedEvent()';
  }
}
/// The event fired when the ZModem aborted
class ZSessionAbortedEvent implements ZModemEvent {
  @override
  String toString() {
    return 'ZSessionAbortedEvent()';
  }
}

/// The other side is ready to receive a file.
class ZReadyToSendEvent implements ZModemEvent {
  @override
  String toString() {
    return 'ZReadyToSendEvent()';
  }
}

/// The other side has accepted a file we just offered.
class ZFileAcceptedEvent implements ZModemEvent {
  const ZFileAcceptedEvent(this.offset);

  final int offset;

  @override
  String toString() {
    return 'ZFileAcceptedEvent(offset: $offset)';
  }
}

/// The other side has rejected a file we just offered.
class ZFileSkippedEvent implements ZModemEvent {
  @override
  String toString() {
    return 'ZFileSkippedEvent()';
  }
}
