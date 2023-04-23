import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zmodem/zmodem.dart';

void main() {
  group('ZModemCore', () {
    test('can act as both client and server', () {
      final server = ZModemCore();
      final client = ZModemCore();

      server.initiateSend();
      client.receive(server.dataToSend()).drain();
      expect(server.receive(client.dataToSend()), [isA<ZReadyToSendEvent>()]);

      server.offerFile(ZModemFileInfo(pathname: 'foo', length: 123));
      final events = client.receive(server.dataToSend()).toList();
      expect(events, [isA<ZFileOfferedEvent>()]);

      final fileInfo = (events.single as ZFileOfferedEvent).fileInfo;
      expect(fileInfo.pathname, 'foo');
      expect(fileInfo.length, 123);

      client.acceptFile();
      expect(server.receive(client.dataToSend()), [isA<ZFileAcceptedEvent>()]);

      server.sendFileData(Uint8List.fromList([1, 2, 3]));
      expect(client.receive(server.dataToSend()), [isA<ZFileDataEvent>()]);

      server.finishSending(3);
      expect(
        client.receive(server.dataToSend()),
        [
          isA<ZFileDataEvent>(), // ZCRCE
          isA<ZFileReceivedEvent>(), // ZEOF
        ],
      );

      expect(server.receive(client.dataToSend()), [isA<ZReadyToSendEvent>()]);

      server.finishSession();
      // expect(
      //   client.receive(server.dataToSend()),
      //   [isA<ZSessionFinishedEvent>()],
      // );
    });
  });
}

extension on Iterable {
  void drain() {
    for (final _ in this) {}
  }
}
