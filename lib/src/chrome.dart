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
const _windowsPrefixes = {'LOCALAPPDATA', 'PROGRAMFILES', 'PROGRAMFILES(X86)'};

String get _executable {
  if (Platform.environment.containsKey(_chromeEnvironment)) {
    return Platform.environment[_chromeEnvironment];
  }
  if (Platform.isLinux) return _linuxExecutable;
  if (Platform.isMacOS) return _macOSExecutable;
  if (Platform.isWindows) {
    final windowsPrefixes =
        _windowsPrefixes.map((name) => Platform.environment[name]).toList();
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
  /// Only one instance of Chrome can run at a time. Each url in [urls] will be
  /// loaded in a separate tab.
  static Future<Chrome> startWithDebugPort(
    List<String> urls, {
    int debugPort,
    List<String> chromeArgs = const [],
  }) async {
    final dataDir = Directory(p.joinAll(
        [Directory.current.path, '.dart_tool', 'webdev', 'chrome_profile']));
    final activePortFile = File(p.join(dataDir.path, 'DevToolsActivePort'));
    // If we are reusing the Chrome profile we'll need to be able to read the
    // DevToolsActivePort to connect the debugger. When a non-zero debugging
    // port is provided Chrome will not write the DevToolsActivePort file and
    // therefore we can not reuse the profile.
    if (dataDir.existsSync() && !activePortFile.existsSync()) {
      dataDir.deleteSync(recursive: true);
    }
    dataDir.createSync(recursive: true);

    int port = debugPort == null ? 0 : debugPort;
    final args = chromeArgs
      ..addAll([
        // Using a tmp directory ensures that a new instance of chrome launches
        // allowing for the remote debug port to be enabled.
        '--user-data-dir=${dataDir.path}',
        '--remote-debugging-port=$port',
      ]);

    final process = await _startProcess(urls, args: args);
    final output = StreamGroup.merge([
      process.stderr.transform(utf8.decoder).transform(const LineSplitter()),
      process.stdout.transform(utf8.decoder).transform(const LineSplitter())
    ]);

    // Wait until the DevTools are listening before trying to connect.
    await output
        .firstWhere((line) =>
            line.startsWith('DevTools listening') ||
            line.startsWith('Opening in existing'))
        .timeout(Duration(seconds: 60),
            onTimeout: () =>
                throw Exception('Unable to connect to Chrome DevTools.'));

    // The DevToolsActivePort file is only written if 0 is provided.
    if (port == 0) {
      if (!activePortFile.existsSync()) {
        throw ChromeError("Can't read DevToolsActivePort file.");
      }
      port = int.parse(activePortFile.readAsLinesSync().first);
    }

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
    _process?.kill();
    await _process?.exitCode;
  }
}

class ChromeError extends Error {
  final String details;
  ChromeError(this.details);

  @override
  String toString() => 'ChromeError: $details';
}
