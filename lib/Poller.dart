import 'dart:async';
import 'dart:convert';

import 'package:poller/poller_status.dart';
import 'package:rxdart/rxdart.dart';
import 'package:web_socket_channel/io.dart';

class Poller<T> {
  final _normalClosure = 1000;

  final String url;
  IOWebSocketChannel? _channel;

  // ignore: cancel_subscriptions
  StreamSubscription? _subscription;

  Timer? _pauseTimer;

  Timer? _pingTimer;
  bool connecting = false;

  final Duration pauseTime;
  final Duration pingTime;
  final Duration pingInterval;

  final T Function(Map<String, dynamic>) parser;
  final Future<bool> Function() sessionExtender;
  final Future<Map<String, dynamic>> Function() headers;
  final BehaviorSubject<T?> subject = BehaviorSubject();
  final BehaviorSubject<PollerStatus> stateSubject = BehaviorSubject.seeded(PollerStatus.stopped);

  Poller({
    required this.url,
    required this.parser,
    required this.sessionExtender,
    this.pauseTime: const Duration(seconds: 5),
    this.pingTime: const Duration(minutes: 5),
    this.pingInterval: const Duration(seconds: 30),
    required this.headers,
  }) : super();

  void add(dynamic data) {
    var channel = _channel;
    if (channel != null) {
      channel.sink.add(data);
    }
  }

  void addError(Object data, [StackTrace? stackTrace]) {
    var channel = _channel;
    if (channel != null) {
      channel.sink.addError(data, stackTrace);
    } else {
      throw "Websocket is not connected yet";
    }
  }

  Future<dynamic> addStream(Stream<dynamic> data) {
    var channel = _channel;
    if (channel != null) {
      return channel.sink.addStream(data);
    }
    throw "Websocket is not connected yet";
  }

  bool get connected => _channel != null;

  start() async {
    sessionExtender().then(
      (value) {
        if (value) {
          connect();
        } else {
          stop();
        }
      },
      onError: (error) => pause(),
    );
  }

  connect() async {
    if (connecting) {
      print("Already connecting");
      return;
    }
    connecting = true;
    try {
      if (_channel != null) {
        return;
      }
      print("Connecting $url");
      stateSubject.add(PollerStatus.connecting);

      var _headers = await headers();

      _channel = IOWebSocketChannel.connect(
        url,
        headers: _headers,
        pingInterval: pingInterval,
      );
      print("DONE connecting!");
      var channel = _channel!;

      stateSubject.add(PollerStatus.polling);

      startPinger();
      _subscription = channel.stream.listen((message) {
        handle(message as String);
      }, onDone: () {
        if (_channel != null) {
          int? closeCode = _channel!.closeCode;
          _channel = null;
          handleClosure(closeCode);
        }
      }, onError: (error) {
        if (_channel != null) {
          int? closeCode = _channel!.closeCode;
          _channel = null;
          handleClosure(closeCode);
        }
      });
    } finally {
      connecting = false;
    }
  }

  stop() {
    if (_channel != null) {
      _channel!.sink.close();
      _channel = null;
    }
    if (_subscription != null) {
      _subscription!.cancel();
      _subscription = null;
    }

    if (_pauseTimer != null) {
      _pauseTimer!.cancel();
      _pauseTimer = null;
    }
    if (_pingTimer != null) {
      _pingTimer!.cancel();
      _pingTimer = null;
    }

    handleClosure(1000);
  }

  handleClosure(int? closeCode) {
    stateSubject.add(PollerStatus.stopped);
    if (closeCode != _normalClosure) {
      pause();
    } else {
      print("Normal closure detected. nothing to be done.");
    }
  }

  void close() {
    subject.close();
    stateSubject.close();
  }

  handle(String message) {
    try {
      Map<String, dynamic> map = json.decode(message);
      T response = parser(map);
      subject.add(response);
    } catch (error) {
      print("caught an error while decoding $message ERROR = $error");
    }
  }

  void pause() {
    if (_pauseTimer == null || !_pauseTimer!.isActive) {
      stateSubject.add(PollerStatus.paused);
      _pauseTimer = Timer(
        Duration(seconds: 15),
        () => start(),
      );
    }
  }

  void startPinger() {
    if (_pingTimer == null || !_pingTimer!.isActive) {
      _pingTimer = Timer(Duration(minutes: 5), () => start());
    }
  }
}
