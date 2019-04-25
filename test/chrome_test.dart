// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

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
    chrome = await Chrome.startWithPort(
      [_googleUrl],
      userDataDir: dataDir.path,
      remoteDebuggingPort: port,
      disableBackgroundTimerThrottling: true,
      disableExtensions: true,
      disablePopupBlocking: true,
      bwsi: true,
      noFirstRun: true,
      noDefaultBrowserCheck: true,
      disableDefaultApps: true,
      disableTranslate: true,
    );
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
  }, skip: Platform.isWindows);

  test('can launch chrome with debug port', () async {
    await launchChromeWithDebugPort();
    expect(chrome, isNotNull);
  }, skip: Platform.isWindows);

  test('debugger is working', () async {
    await launchChromeWithDebugPort();
    var tabs = await chrome.chromeConnection.getTabs();
    expect(
        tabs,
        contains(const TypeMatcher<ChromeTab>()
            .having((t) => t.url, 'url', _googleUrl)));
  }, skip: Platform.isWindows);

  test('uses open debug port if provided port is 0', () async {
    await launchChromeWithDebugPort(port: 0);
    expect(chrome.debugPort, isNot(equals(0)));
  }, skip: Platform.isWindows);
}

const _googleUrl = 'http://www.google.com/';
