// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

@OnPlatform({'windows': Skip('appveyor is not setup to install Chrome')})
import 'dart:async';
import 'dart:io';

import 'package:browser_launcher/src/chrome.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:webkit_inspection_protocol/webkit_inspection_protocol.dart';

void main() {
  Chrome chrome;

  Future<void> launchChromeWithDebugPort({int port}) async {
    final dataDir = Directory(p.joinAll(
        [Directory.current.path, '.dart_tool', 'webdev', 'chrome_profile']))
      ..createSync(recursive: true);
    chrome = await Chrome.startWithDebugPort([_googleUrl],
        debugPort: port,
        chromeArgs: [
          // When the DevTools has focus we don't want to slow down the application.
          '--disable-background-timer-throttling',
          // Since we are using a temp profile, disable features that slow the
          // Chrome launch.
          '--disable-extensions',
          '--disable-popup-blocking',
          '--bwsi',
          '--no-first-run',
          '--no-default-browser-check',
          '--disable-default-apps',
          '--disable-translate',
        ]);
  }

  Future<void> launchChrome() async {
    await Chrome.start([_googleUrl]);
  }

  tearDown(() async {
    await chrome?.close();
    chrome = null;
  });

  test('can launch chrome', () async {
    await launchChrome();
    expect(chrome, isNull);
  });

  test('can launch chrome with debug port', () async {
    await launchChromeWithDebugPort();
    expect(chrome, isNotNull);
  });

  test('debugger is working', () async {
    await launchChromeWithDebugPort();
    var tabs = await chrome.chromeConnection.getTabs();
    expect(
        tabs,
        contains(const TypeMatcher<ChromeTab>()
            .having((t) => t.url, 'url', _googleUrl)));
  });

  test('uses open debug port if provided port is 0', () async {
    await launchChromeWithDebugPort(port: 0);
    expect(chrome.debugPort, isNot(equals(0)));
  });

  test('can provide a specific debug port', () async {
    var port = await findUnusedPort();
    await launchChromeWithDebugPort(port: port);
    expect(chrome.debugPort, port);
  });
}

const _googleUrl = 'https://www.google.com/';

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
