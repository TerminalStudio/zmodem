import 'package:zmodem/src/util/debug.dart';
import 'package:zmodem/src/zmodem_fileinfo.dart';

abstract class ZModemEvent {}

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

class ZFileReceivedEvent implements ZModemEvent {
  @override
  String toString() {
    return 'ZFileReceivedEvent()';
  }
}

class ZSessionFinishedEvent implements ZModemEvent {
  @override
  String toString() {
    return 'ZSessionFinishedEvent()';
  }
}

class ZReceiverReadyEvent implements ZModemEvent {
  @override
  String toString() {
    return 'ZReceiverReadyEvent()';
  }
}

class ZFileAcceptedEvent implements ZModemEvent {
  const ZFileAcceptedEvent(this.offset);

  final int offset;

  @override
  String toString() {
    return 'ZFileAcceptedEvent(offset: $offset)';
  }
}

class ZFileSkippedEvent implements ZModemEvent {
  @override
  String toString() {
    return 'ZFileSkippedEvent()';
  }
}
