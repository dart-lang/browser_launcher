// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:async/async.dart';
import 'package:path/path.dart' as p;
import 'package:webkit_inspection_protocol/webkit_inspection_protocol.dart';

const _chromeEnvironment = 'CHROME_EXECUTABLE';
const _linuxExecutable = 'google-chrome';
const _macOSExecutable =
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const _windowsExecutable = r'Google\Chrome\Application\chrome.exe';

String get _executable {
  if (Platform.environment.containsKey(_chromeEnvironment)) {
    return Platform.environment[_chromeEnvironment];
  }
  if (Platform.isLinux) return _linuxExecutable;
  if (Platform.isMacOS) return _macOSExecutable;
  if (Platform.isWindows) {
    final windowsPrefixes = [
      Platform.environment['LOCALAPPDATA'],
      Platform.environment['PROGRAMFILES'],
      Platform.environment['PROGRAMFILES(X86)']
    ];
    return p.join(
      windowsPrefixes.firstWhere((prefix) {
        if (prefix == null) return false;
        final path = p.join(prefix, _windowsExecutable);
        return File(path).existsSync();
      }, orElse: () => '.'),
      _windowsExecutable,
    );
  }
  throw StateError('Unexpected platform type.');
}

var _currentCompleter = Completer<Chrome>();

/// Manager for an instance of Chrome.
class Chrome {
  Chrome._(
    this.debugPort,
    this.chromeConnection, {
    Process process,
    Directory dataDir,
  })  : _process = process,
        _dataDir = dataDir;

  final int debugPort;
  final ChromeConnection chromeConnection;
  final Process _process;
  final Directory _dataDir;

  /// Connects to an instance of Chrome with an open debug port.
  static Future<Chrome> fromExisting(int port) async =>
      _connect(Chrome._(port, ChromeConnection('localhost', port)));

  static Future<Chrome> get connectedInstance => _currentCompleter.future;

  /// Starts Chrome with the given arguments and a specific port.
  ///
  /// Only one instance of Chrome can run at a time. Each url in [urls] will be
  /// loaded in a separate tab.
  static Future<Chrome> startWithDebugPort(
    List<String> urls, {
    int debugPort,
    bool headless = false,
    List<String> chromeArgs = const [],
  }) async {
    final dataDir = Directory.systemTemp.createTempSync();
    final port = debugPort == null || debugPort == 0
        ? await findUnusedPort()
        : debugPort;
    final args = chromeArgs
      ..addAll([
        // Using a tmp directory ensures that a new instance of chrome launches
        // allowing for the remote debug port to be enabled.
        '--user-data-dir=${dataDir.path}',
        '--remote-debugging-port=$port',
      ]);
    if (headless) {
      args.add('--headless');
    }

    final process = await _startProcess(urls, args: args);

    // Wait until the DevTools are listening before trying to connect.
    await process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .firstWhere((line) => line.startsWith('DevTools listening'))
        .timeout(Duration(seconds: 60),
            onTimeout: () =>
                throw Exception('Unable to connect to Chrome DevTools.'));

    return _connect(Chrome._(
      port,
      ChromeConnection('localhost', port),
      process: process,
      dataDir: dataDir,
    ));
  }

  /// Starts Chrome with the given arguments.
  ///
  /// Each url in [urls] will be loaded in a separate tab.
  static Future<void> start(
    List<String> urls, {
    List<String> chromeArgs = const [],
  }) async {
    await _startProcess(urls, args: chromeArgs);
  }

  static Future<Process> _startProcess(
    List<String> urls, {
    List<String> args = const [],
  }) async {
    final processArgs = args.toList()..addAll(urls);
    return await Process.start(_executable, processArgs);
  }

  static Future<Chrome> _connect(Chrome chrome) async {
    if (_currentCompleter.isCompleted) {
      throw ChromeError('Only one instance of chrome can be started.');
    }
    // The connection is lazy. Try a simple call to make sure the provided
    // connection is valid.
    try {
      await chrome.chromeConnection.getTabs();
    } catch (e) {
      await chrome.close();
      throw ChromeError(
          'Unable to connect to Chrome debug port: ${chrome.debugPort}\n $e');
    }
    _currentCompleter.complete(chrome);
    return chrome;
  }

  Future<void> close() async {
    if (_currentCompleter.isCompleted) _currentCompleter = Completer<Chrome>();
    chromeConnection.close();
    _process?.kill(ProcessSignal.sigkill);
    await _process?.exitCode;
    await _dataDir?.delete(recursive: true);
  }
}

class ChromeError extends Error {
  final String details;
  ChromeError(this.details);

  @override
  String toString() => 'ChromeError: $details';
}

/// Returns a port that is probably, but not definitely, not in use.
///
/// This has a built-in race condition: another process may bind this port at
/// any time after this call has returned.
Future<int> findUnusedPort() async {
  int port;
  ServerSocket socket;
  try {
    socket =
        await ServerSocket.bind(InternetAddress.loopbackIPv6, 0, v6Only: true);
  } on SocketException {
    socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  }
  port = socket.port;
  await socket.close();
  return port;
}
