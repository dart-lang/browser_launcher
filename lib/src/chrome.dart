// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:webkit_inspection_protocol/webkit_inspection_protocol.dart';

const _chromeEnvironment = 'CHROME_EXECUTABLE';
const _linuxExecutable = 'google-chrome';
const _macOSExecutable =
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const _windowsExecutable = r'Google\Chrome\Application\chrome.exe';
var _windowsPrefixes = [
  Platform.environment['LOCALAPPDATA'],
  Platform.environment['PROGRAMFILES'],
  Platform.environment['PROGRAMFILES(X86)']
];

String get _executable {
  if (Platform.environment.containsKey(_chromeEnvironment)) {
    return Platform.environment[_chromeEnvironment];
  }
  if (Platform.isLinux) return _linuxExecutable;
  if (Platform.isMacOS) return _macOSExecutable;
  if (Platform.isWindows) {
    return p.join(
        _windowsPrefixes.firstWhere((prefix) {
          if (prefix == null) return false;
          final path = p.join(prefix, _windowsExecutable);
          return File(path).existsSync();
        }, orElse: () => '.'),
        _windowsExecutable);
  }
  throw StateError('Unexpected platform type.');
}

var _currentCompleter = Completer<Chrome>();

/// A class for managing an instance of Chrome.
class Chrome {
  Chrome._(
    this.debugPort,
    this.chromeConnection, {
    Process process,
  }) : _process = process;

  final int debugPort;
  final Process _process;
  final ChromeConnection chromeConnection;

  /// Connects to an instance of Chrome with an open debug port.
  static Future<Chrome> fromExisting(int port) async =>
      _connect(Chrome._(port, ChromeConnection('localhost', port)));

  static Future<Chrome> get connectedInstance => _currentCompleter.future;

  /// Starts Chrome with the given arguments and a specific port.
  ///
  /// Each url in [urls] will be loaded in a separate tab.
  static Future<Chrome> startWithPort(
    List<String> urls, {
    String userDataDir,
    int remoteDebuggingPort,
    bool disableBackgroundTimerThrottling,
    bool disableExtensions,
    bool disablePopupBlocking,
    bool bwsi,
    bool noFirstRun,
    bool noDefaultBrowserCheck,
    bool disableDefaultApps,
    bool disableTranslate,
  }) async {
    final port = remoteDebuggingPort == null || remoteDebuggingPort == 0
        ? await findUnusedPort()
        : remoteDebuggingPort;

    final process = await _startProcess(
      urls,
      userDataDir: userDataDir,
      remoteDebuggingPort: port,
      disableBackgroundTimerThrottling: disableBackgroundTimerThrottling,
      disableExtensions: disableExtensions,
      disablePopupBlocking: disablePopupBlocking,
      bwsi: bwsi,
      noFirstRun: noFirstRun,
      noDefaultBrowserCheck: noDefaultBrowserCheck,
      disableDefaultApps: disableDefaultApps,
      disableTranslate: disableTranslate,
    );

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
    ));
  }

  /// Starts Chrome with the given arguments.
  ///
  /// Each url in [urls] will be loaded in a separate tab.
  static Future<void> start(
    List<String> urls, {
    String userDataDir,
    int remoteDebuggingPort,
    bool disableBackgroundTimerThrottling,
    bool disableExtensions,
    bool disablePopupBlocking,
    bool bwsi,
    bool noFirstRun,
    bool noDefaultBrowserCheck,
    bool disableDefaultApps,
    bool disableTranslate,
  }) async {
    await _startProcess(
      urls,
      userDataDir: userDataDir,
      remoteDebuggingPort: remoteDebuggingPort,
      disableBackgroundTimerThrottling: disableBackgroundTimerThrottling,
      disableExtensions: disableExtensions,
      disablePopupBlocking: disablePopupBlocking,
      bwsi: bwsi,
      noFirstRun: noFirstRun,
      noDefaultBrowserCheck: noDefaultBrowserCheck,
      disableDefaultApps: disableDefaultApps,
      disableTranslate: disableTranslate,
    );
  }

  static Future<Process> _startProcess(
    List<String> urls, {
    String userDataDir,
    int remoteDebuggingPort,
    bool disableBackgroundTimerThrottling = false,
    bool disableExtensions = false,
    bool disablePopupBlocking = false,
    bool bwsi = false,
    bool noFirstRun = false,
    bool noDefaultBrowserCheck = false,
    bool disableDefaultApps = false,
    bool disableTranslate = false,
  }) async {
    final List<String> args = [];
    if (userDataDir != null) {
      args.add('--user-data-dir=$userDataDir');
    }
    if (remoteDebuggingPort != null) {
      args.add('--remote-debugging-port=$remoteDebuggingPort');
    }
    if (disableBackgroundTimerThrottling) {
      args.add('--disable-background-timer-throttling');
    }
    if (disableExtensions) {
      args.add('--disable-extensions');
    }
    if (disablePopupBlocking) {
      args.add('--disable-popup-blocking');
    }
    if (bwsi) {
      args.add('--bwsi');
    }
    if (noFirstRun) {
      args.add('--no-first-run');
    }
    if (noDefaultBrowserCheck) {
      args.add('--no-default-browser-check');
    }
    if (disableDefaultApps) {
      args.add('--disable-default-apps');
    }
    if (disableTranslate) {
      args.add('--disable-translate');
    }
    args..addAll(urls);

    final process = await Process.start(_executable, args);

    return process;
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
    _process?.kill();
    await _process?.exitCode;
  }
}

class ChromeError extends Error {
  final String details;
  ChromeError(this.details);

  @override
  String toString() {
    return 'ChromeError: $details';
  }
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
