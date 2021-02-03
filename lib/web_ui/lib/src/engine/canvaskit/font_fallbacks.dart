// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// @dart = 2.12
part of engine;

/// Whether or not "Noto Sans Symbols" and "Noto Color Emoji" fonts have been
/// downloaded. We download these as fallbacks when no other font covers the
/// given code units.
bool _registeredSymbolsAndEmoji = false;

final Set<int> codeUnitsWithNoKnownFont = <int>{};

Future<void> _findFontsForMissingCodeunits(List<int> codeunits) async {
  _ensureNotoFontTreeCreated();

  // If all of the code units are known to have no Noto Font which covers them,
  // then just give up. We have already logged a warning.
  if (codeunits.every((u) => codeUnitsWithNoKnownFont.contains(u))) {
    return;
  }
  Set<_NotoFont> fonts = <_NotoFont>{};
  Set<int> coveredCodeUnits = <int>{};
  Set<int> missingCodeUnits = <int>{};
  for (int codeunit in codeunits) {
    List<_NotoFont> fontsForUnit = _notoTree!.intersections(codeunit);
    fonts.addAll(fontsForUnit);
    if (fontsForUnit.isNotEmpty) {
      coveredCodeUnits.add(codeunit);
    } else {
      missingCodeUnits.add(codeunit);
    }
  }

  fonts = _findMinimumFontsForCodeunits(coveredCodeUnits, fonts);

  for (_NotoFont font in fonts) {
    await font.ensureResolved();
  }

  Set<_ResolvedNotoSubset> resolvedFonts = <_ResolvedNotoSubset>{};
  for (int codeunit in coveredCodeUnits) {
    for (_NotoFont font in fonts) {
      if (font.resolvedFont == null) {
        // We failed to resolve the font earlier.
        continue;
      }
      resolvedFonts.addAll(font.resolvedFont!.tree.intersections(codeunit));
    }
  }

  for (_ResolvedNotoSubset resolvedFont in resolvedFonts) {
    notoDownloadQueue.add(resolvedFont);
  }

  if (missingCodeUnits.isNotEmpty && !notoDownloadQueue.isPending) {
    if (!_registeredSymbolsAndEmoji) {
      _registerSymbolsAndEmoji();
    } else {
      if (!notoDownloadQueue.isPending) {
        html.window.console.log(
            'Could not find a set of Noto fonts to display all missing '
            'characters. Please add a font asset for the missing characters.'
            ' See: https://flutter.dev/docs/cookbook/design/fonts');
        codeUnitsWithNoKnownFont.addAll(missingCodeUnits);
      }
    }
  }
}

/// Parse the CSS file for a font and make a list of resolved subsets.
///
/// A CSS file from Google Fonts looks like this:
///
///     /* [0] */
///     @font-face {
///       font-family: 'Noto Sans KR';
///       font-style: normal;
///       font-weight: 400;
///       src: url(https://fonts.gstatic.com/s/notosanskr/v13/PbykFmXiEBPT4ITbgNA5Cgm20xz64px_1hVWr0wuPNGmlQNMEfD4.0.woff2) format('woff2');
///       unicode-range: U+f9ca-fa0b, U+ff03-ff05, U+ff07, U+ff0a-ff0b, U+ff0d-ff19, U+ff1b, U+ff1d, U+ff20-ff5b, U+ff5d, U+ffe0-ffe3, U+ffe5-ffe6;
///     }
///     /* [1] */
///     @font-face {
///       font-family: 'Noto Sans KR';
///       font-style: normal;
///       font-weight: 400;
///       src: url(https://fonts.gstatic.com/s/notosanskr/v13/PbykFmXiEBPT4ITbgNA5Cgm20xz64px_1hVWr0wuPNGmlQNMEfD4.1.woff2) format('woff2');
///       unicode-range: U+f92f-f980, U+f982-f9c9;
///     }
///     /* [2] */
///     @font-face {
///       font-family: 'Noto Sans KR';
///       font-style: normal;
///       font-weight: 400;
///       src: url(https://fonts.gstatic.com/s/notosanskr/v13/PbykFmXiEBPT4ITbgNA5Cgm20xz64px_1hVWr0wuPNGmlQNMEfD4.2.woff2) format('woff2');
///       unicode-range: U+d723-d728, U+d72a-d733, U+d735-d748, U+d74a-d74f, U+d752-d753, U+d755-d757, U+d75a-d75f, U+d762-d764, U+d766-d768, U+d76a-d76b, U+d76d-d76f, U+d771-d787, U+d789-d78b, U+d78d-d78f, U+d791-d797, U+d79a, U+d79c, U+d79e-d7a3, U+f900-f909, U+f90b-f92e;
///     }
_ResolvedNotoFont? _makeResolvedNotoFontFromCss(String css, String name) {
  List<_ResolvedNotoSubset> subsets = <_ResolvedNotoSubset>[];
  bool resolvingFontFace = false;
  String? fontFaceUrl;
  List<CodeunitRange>? fontFaceUnicodeRanges;
  for (final String line in LineSplitter.split(css)) {
    // Search for the beginning of a @font-face.
    if (!resolvingFontFace) {
      if (line == '@font-face {') {
        resolvingFontFace = true;
      } else {
        continue;
      }
    } else {
      // We are resolving a @font-face, read out the url and ranges.
      if (line.startsWith('  src:')) {
        int urlStart = line.indexOf('url(');
        if (urlStart == -1) {
          html.window.console.warn('Unable to resolve Noto font URL: $line');
          return null;
        }
        int urlEnd = line.indexOf(')');
        fontFaceUrl = line.substring(urlStart + 4, urlEnd);
      } else if (line.startsWith('  unicode-range:')) {
        fontFaceUnicodeRanges = <CodeunitRange>[];
        String rangeString = line.substring(17, line.length - 1);
        List<String> rawRanges = rangeString.split(', ');
        for (final String rawRange in rawRanges) {
          List<String> startEnd = rawRange.split('-');
          if (startEnd.length == 1) {
            String singleRange = startEnd.single;
            assert(singleRange.startsWith('U+'));
            int rangeValue = int.parse(singleRange.substring(2), radix: 16);
            fontFaceUnicodeRanges.add(CodeunitRange(rangeValue, rangeValue));
          } else {
            assert(startEnd.length == 2);
            String startRange = startEnd[0];
            String endRange = startEnd[1];
            assert(startRange.startsWith('U+'));
            int startValue = int.parse(startRange.substring(2), radix: 16);
            int endValue = int.parse(endRange, radix: 16);
            fontFaceUnicodeRanges.add(CodeunitRange(startValue, endValue));
          }
        }
      } else if (line == '}') {
        if (fontFaceUrl == null || fontFaceUnicodeRanges == null) {
          html.window.console.warn('Unable to parse Google Fonts CSS: $css');
          return null;
        }
        subsets
            .add(_ResolvedNotoSubset(fontFaceUrl, name, fontFaceUnicodeRanges));
        resolvingFontFace = false;
      } else {
        continue;
      }
    }
  }

  if (resolvingFontFace) {
    html.window.console.warn('Unable to parse Google Fonts CSS: $css');
    return null;
  }

  Map<_ResolvedNotoSubset, List<CodeunitRange>> rangesMap =
      <_ResolvedNotoSubset, List<CodeunitRange>>{};
  for (_ResolvedNotoSubset subset in subsets) {
    for (CodeunitRange range in subset.ranges) {
      rangesMap.putIfAbsent(subset, () => <CodeunitRange>[]).add(range);
    }
  }

  IntervalTree<_ResolvedNotoSubset> tree =
      IntervalTree<_ResolvedNotoSubset>.createFromRanges(rangesMap);

  return _ResolvedNotoFont(name, subsets, tree);
}

/// In the case where none of the known Noto Fonts cover a set of code units,
/// try the Symbols and Emoji fonts. We don't know the exact range of code units
/// that are covered by these fonts, so we download them and hope for the best.
Future<void> _registerSymbolsAndEmoji() async {
  if (_registeredSymbolsAndEmoji) {
    return;
  }
  _registeredSymbolsAndEmoji = true;
  const String symbolsUrl =
      'https://fonts.googleapis.com/css2?family=Noto+Sans+Symbols';
  const String emojiUrl =
      'https://fonts.googleapis.com/css2?family=Noto+Color+Emoji+Compat';

  String symbolsCss =
      await notoDownloadQueue.downloader.downloadAsString(symbolsUrl);
  String emojiCss =
      await notoDownloadQueue.downloader.downloadAsString(emojiUrl);

  String? extractUrlFromCss(String css) {
    for (final String line in LineSplitter.split(css)) {
      if (line.startsWith('  src:')) {
        int urlStart = line.indexOf('url(');
        if (urlStart == -1) {
          html.window.console.warn('Unable to resolve Noto font URL: $line');
          return null;
        }
        int urlEnd = line.indexOf(')');
        return line.substring(urlStart + 4, urlEnd);
      }
    }
    html.window.console.warn('Unable to determine URL for Noto font');
    return null;
  }

  String? symbolsFontUrl = extractUrlFromCss(symbolsCss);
  String? emojiFontUrl = extractUrlFromCss(emojiCss);

  if (symbolsFontUrl != null) {
    notoDownloadQueue.add(_ResolvedNotoSubset(
        symbolsFontUrl, 'Noto Sans Symbols', const <CodeunitRange>[]));
  } else {
    html.window.console.warn('Error parsing CSS for Noto Symbols font.');
  }

  if (emojiFontUrl != null) {
    notoDownloadQueue.add(_ResolvedNotoSubset(
        emojiFontUrl, 'Noto Color Emoji Compat', const <CodeunitRange>[]));
  } else {
    html.window.console.warn('Error parsing CSS for Noto Emoji font.');
  }
}

/// Finds the minimum set of fonts which covers all of the [codeunits].
///
/// Since set cover is NP-complete, we approximate using a greedy algorithm
/// which finds the font which covers the most codeunits. If multiple CJK
/// fonts match the same number of codeunits, we choose one based on the user's
/// locale.
Set<_NotoFont> _findMinimumFontsForCodeunits(
    Iterable<int> codeunits, Set<_NotoFont> fonts) {
  List<int> unmatchedCodeunits = List<int>.from(codeunits);
  Set<_NotoFont> minimumFonts = <_NotoFont>{};
  List<_NotoFont> bestFonts = <_NotoFont>[];
  int maxCodeunitsCovered = 0;

  String language = html.window.navigator.language;

  // This is guaranteed to terminate because [codeunits] is a list of fonts
  // which we've already determined are covered by [fonts].
  while (unmatchedCodeunits.isNotEmpty) {
    for (var font in fonts) {
      int codeunitsCovered = 0;
      for (int codeunit in unmatchedCodeunits) {
        if (font.matchesCodeunit(codeunit)) {
          codeunitsCovered++;
        }
      }
      if (codeunitsCovered > maxCodeunitsCovered) {
        bestFonts.clear();
        bestFonts.add(font);
        maxCodeunitsCovered = codeunitsCovered;
      } else if (codeunitsCovered == maxCodeunitsCovered) {
        bestFonts.add(font);
      }
    }
    assert(bestFonts.isNotEmpty);
    // If the list of best fonts are all CJK fonts, choose the best one based
    // on locale. Otherwise just choose the first font.
    _NotoFont bestFont = bestFonts.first;
    if (bestFonts.length > 1) {
      if (bestFonts.every((font) => _cjkFonts.contains(font))) {
        if (language == 'zh-Hans' ||
            language == 'zh-CN' ||
            language == 'zh-SG' ||
            language == 'zh-MY') {
          if (bestFonts.contains(_notoSansSC)) {
            bestFont = _notoSansSC;
          }
        } else if (language == 'zh-Hant' ||
            language == 'zh-TW' ||
            language == 'zh-MO') {
          if (bestFonts.contains(_notoSansTC)) {
            bestFont = _notoSansTC;
          }
        } else if (language == 'zh-HK') {
          if (bestFonts.contains(_notoSansHK)) {
            bestFont = _notoSansHK;
          }
        } else if (language == 'ja') {
          if (bestFonts.contains(_notoSansJP)) {
            bestFont = _notoSansJP;
          }
        }
      }
    }
    unmatchedCodeunits
        .removeWhere((codeunit) => bestFont.matchesCodeunit(codeunit));
    minimumFonts.add(bestFont);
  }
  return minimumFonts;
}

void _ensureNotoFontTreeCreated() {
  if (_notoTree != null) {
    return;
  }

  Map<_NotoFont, List<CodeunitRange>> ranges =
      <_NotoFont, List<CodeunitRange>>{};

  for (_NotoFont font in _notoFonts) {
    for (CodeunitRange range in font.unicodeRanges) {
      ranges.putIfAbsent(font, () => <CodeunitRange>[]).add(range);
    }
  }

  _notoTree = IntervalTree<_NotoFont>.createFromRanges(ranges);
}

class _NotoFont {
  final String name;
  final List<CodeunitRange> unicodeRanges;

  Completer<void>? _decodingCompleter;

  _ResolvedNotoFont? resolvedFont;

  _NotoFont(this.name, this.unicodeRanges);

  bool matchesCodeunit(int codeunit) {
    for (CodeunitRange range in unicodeRanges) {
      if (range.contains(codeunit)) {
        return true;
      }
    }
    return false;
  }

  String get googleFontsCssUrl =>
      'https://fonts.googleapis.com/css2?family=${name.replaceAll(' ', '+')}';

  Future<void> ensureResolved() async {
    if (resolvedFont == null) {
      if (_decodingCompleter == null) {
        _decodingCompleter = Completer<void>();
        String googleFontCss = await notoDownloadQueue.downloader
            .downloadAsString(googleFontsCssUrl);
        final _ResolvedNotoFont? googleFont =
            _makeResolvedNotoFontFromCss(googleFontCss, name);
        resolvedFont = googleFont;
        _decodingCompleter!.complete();
      } else {
        await _decodingCompleter!.future;
      }
    }
  }
}

class CodeunitRange {
  final int start;
  final int end;

  const CodeunitRange(this.start, this.end);

  bool contains(int codeUnit) {
    return start <= codeUnit && codeUnit <= end;
  }

  @override
  bool operator ==(dynamic other) {
    if (other is! CodeunitRange) {
      return false;
    }
    CodeunitRange range = other;
    return range.start == start && range.end == end;
  }

  @override
  int get hashCode => ui.hashValues(start, end);

  @override
  String toString() => '[$start, $end]';
}

class _ResolvedNotoFont {
  final String name;
  final List<_ResolvedNotoSubset> subsets;
  final IntervalTree<_ResolvedNotoSubset> tree;

  const _ResolvedNotoFont(this.name, this.subsets, this.tree);
}

class _ResolvedNotoSubset {
  final String url;
  final String family;
  final List<CodeunitRange> ranges;

  _ResolvedNotoSubset(this.url, this.family, this.ranges);

  @override
  String toString() => '_ResolvedNotoSubset($family, $url)';
}

_NotoFont _notoSansSC = _NotoFont('Noto Sans SC', <CodeunitRange>[
  CodeunitRange(12288, 12591),
  CodeunitRange(12800, 13311),
  CodeunitRange(19968, 40959),
  CodeunitRange(65072, 65135),
  CodeunitRange(65280, 65519),
]);

_NotoFont _notoSansTC = _NotoFont('Noto Sans TC', <CodeunitRange>[
  CodeunitRange(12288, 12351),
  CodeunitRange(12549, 12585),
  CodeunitRange(19968, 40959),
]);

_NotoFont _notoSansHK = _NotoFont('Noto Sans HK', <CodeunitRange>[
  CodeunitRange(12288, 12351),
  CodeunitRange(12549, 12585),
  CodeunitRange(19968, 40959),
]);

_NotoFont _notoSansJP = _NotoFont('Noto Sans JP', <CodeunitRange>[
  CodeunitRange(12288, 12543),
  CodeunitRange(19968, 40959),
  CodeunitRange(65280, 65519),
]);

List<_NotoFont> _cjkFonts = <_NotoFont>[
  _notoSansSC,
  _notoSansTC,
  _notoSansHK,
  _notoSansJP,
];

List<_NotoFont> _notoFonts = <_NotoFont>[
  _notoSansSC,
  _notoSansTC,
  _notoSansHK,
  _notoSansJP,
  _NotoFont('Noto Naskh Arabic UI', <CodeunitRange>[
    CodeunitRange(1536, 1791),
    CodeunitRange(8204, 8206),
    CodeunitRange(8208, 8209),
    CodeunitRange(8271, 8271),
    CodeunitRange(11841, 11841),
    CodeunitRange(64336, 65023),
    CodeunitRange(65132, 65276),
  ]),
  _NotoFont('Noto Sans Armenian', <CodeunitRange>[
    CodeunitRange(1328, 1424),
    CodeunitRange(64275, 64279),
  ]),
  _NotoFont('Noto Sans Bengali UI', <CodeunitRange>[
    CodeunitRange(2404, 2405),
    CodeunitRange(2433, 2555),
    CodeunitRange(8204, 8205),
    CodeunitRange(8377, 8377),
    CodeunitRange(9676, 9676),
  ]),
  _NotoFont('Noto Sans Myanmar UI', <CodeunitRange>[
    CodeunitRange(4096, 4255),
    CodeunitRange(8204, 8205),
    CodeunitRange(9676, 9676),
  ]),
  _NotoFont('Noto Sans Egyptian Hieroglyphs', <CodeunitRange>[
    CodeunitRange(77824, 78894),
  ]),
  _NotoFont('Noto Sans Ethiopic', <CodeunitRange>[
    CodeunitRange(4608, 5017),
    CodeunitRange(11648, 11742),
    CodeunitRange(43777, 43822),
  ]),
  _NotoFont('Noto Sans Georgian', <CodeunitRange>[
    CodeunitRange(1417, 1417),
    CodeunitRange(4256, 4351),
    CodeunitRange(11520, 11567),
  ]),
  _NotoFont('Noto Sans Gujarati UI', <CodeunitRange>[
    CodeunitRange(2404, 2405),
    CodeunitRange(2688, 2815),
    CodeunitRange(8204, 8205),
    CodeunitRange(8377, 8377),
    CodeunitRange(9676, 9676),
    CodeunitRange(43056, 43065),
  ]),
  _NotoFont('Noto Sans Gurmukhi UI', <CodeunitRange>[
    CodeunitRange(2404, 2405),
    CodeunitRange(2561, 2677),
    CodeunitRange(8204, 8205),
    CodeunitRange(8377, 8377),
    CodeunitRange(9676, 9676),
    CodeunitRange(9772, 9772),
    CodeunitRange(43056, 43065),
  ]),
  _NotoFont('Noto Sans Hebrew', <CodeunitRange>[
    CodeunitRange(1424, 1535),
    CodeunitRange(8362, 8362),
    CodeunitRange(9676, 9676),
    CodeunitRange(64285, 64335),
  ]),
  _NotoFont('Noto Sans Devanagari UI', <CodeunitRange>[
    CodeunitRange(2304, 2431),
    CodeunitRange(7376, 7414),
    CodeunitRange(7416, 7417),
    CodeunitRange(8204, 9205),
    CodeunitRange(8360, 8360),
    CodeunitRange(8377, 8377),
    CodeunitRange(9676, 9676),
    CodeunitRange(43056, 43065),
    CodeunitRange(43232, 43259),
  ]),
  _NotoFont('Noto Sans Kannada UI', <CodeunitRange>[
    CodeunitRange(2404, 2405),
    CodeunitRange(3202, 3314),
    CodeunitRange(8204, 8205),
    CodeunitRange(8377, 8377),
    CodeunitRange(9676, 9676),
  ]),
  _NotoFont('Noto Sans Khmer UI', <CodeunitRange>[
    CodeunitRange(6016, 6143),
    CodeunitRange(8204, 8204),
    CodeunitRange(9676, 9676),
  ]),
  _NotoFont('Noto Sans KR', <CodeunitRange>[
    CodeunitRange(12593, 12686),
    CodeunitRange(12800, 12828),
    CodeunitRange(12896, 12923),
    CodeunitRange(44032, 55215),
  ]),
  _NotoFont('Noto Sans Lao UI', <CodeunitRange>[
    CodeunitRange(3713, 3807),
    CodeunitRange(9676, 9676),
  ]),
  _NotoFont('Noto Sans Malayalam UI', <CodeunitRange>[
    CodeunitRange(775, 775),
    CodeunitRange(803, 803),
    CodeunitRange(2404, 2405),
    CodeunitRange(3330, 3455),
    CodeunitRange(8204, 8205),
    CodeunitRange(8377, 8377),
    CodeunitRange(9676, 9676),
  ]),
  _NotoFont('Noto Sans Sinhala', <CodeunitRange>[
    CodeunitRange(2404, 2405),
    CodeunitRange(3458, 3572),
    CodeunitRange(8204, 8205),
    CodeunitRange(9676, 9676),
  ]),
  _NotoFont('Noto Sans Tamil UI', <CodeunitRange>[
    CodeunitRange(2404, 2405),
    CodeunitRange(2946, 3066),
    CodeunitRange(8204, 8205),
    CodeunitRange(8377, 8377),
    CodeunitRange(9676, 9676),
  ]),
  _NotoFont('Noto Sans Telugu UI', <CodeunitRange>[
    CodeunitRange(2385, 2386),
    CodeunitRange(2404, 2405),
    CodeunitRange(3072, 3199),
    CodeunitRange(7386, 7386),
    CodeunitRange(8204, 8205),
    CodeunitRange(9676, 9676),
  ]),
  _NotoFont('Noto Sans Thai UI', <CodeunitRange>[
    CodeunitRange(3585, 3675),
    CodeunitRange(8204, 8205),
    CodeunitRange(9676, 9676),
  ]),
  _NotoFont('Noto Sans', <CodeunitRange>[
    CodeunitRange(0, 255),
    CodeunitRange(305, 305),
    CodeunitRange(338, 339),
    CodeunitRange(699, 700),
    CodeunitRange(710, 710),
    CodeunitRange(730, 730),
    CodeunitRange(732, 732),
    CodeunitRange(8192, 8303),
    CodeunitRange(8308, 8308),
    CodeunitRange(8364, 8364),
    CodeunitRange(8482, 8482),
    CodeunitRange(8593, 8593),
    CodeunitRange(8595, 8595),
    CodeunitRange(8722, 8722),
    CodeunitRange(8725, 8725),
    CodeunitRange(65279, 65279),
    CodeunitRange(65533, 65533),
    CodeunitRange(1024, 1119),
    CodeunitRange(1168, 1169),
    CodeunitRange(1200, 1201),
    CodeunitRange(8470, 8470),
    CodeunitRange(1120, 1327),
    CodeunitRange(7296, 7304),
    CodeunitRange(8372, 8372),
    CodeunitRange(11744, 11775),
    CodeunitRange(42560, 42655),
    CodeunitRange(65070, 65071),
    CodeunitRange(880, 1023),
    CodeunitRange(7936, 8191),
    CodeunitRange(256, 591),
    CodeunitRange(601, 601),
    CodeunitRange(7680, 7935),
    CodeunitRange(8224, 8224),
    CodeunitRange(8352, 8363),
    CodeunitRange(8365, 8399),
    CodeunitRange(8467, 8467),
    CodeunitRange(11360, 11391),
    CodeunitRange(42784, 43007),
    CodeunitRange(258, 259),
    CodeunitRange(272, 273),
    CodeunitRange(296, 297),
    CodeunitRange(360, 361),
    CodeunitRange(416, 417),
    CodeunitRange(431, 432),
    CodeunitRange(7840, 7929),
    CodeunitRange(8363, 8363),
  ]),
];

class FallbackFontDownloadQueue {
  NotoDownloader downloader = NotoDownloader();

  final Set<_ResolvedNotoSubset> downloadedSubsets = <_ResolvedNotoSubset>{};
  final Set<_ResolvedNotoSubset> pendingSubsets = <_ResolvedNotoSubset>{};

  bool get isPending => pendingSubsets.isNotEmpty;

  void add(_ResolvedNotoSubset subset) {
    if (downloadedSubsets.contains(subset) || pendingSubsets.contains(subset)) {
      return;
    }
    bool firstInBatch = pendingSubsets.isEmpty;
    pendingSubsets.add(subset);
    if (firstInBatch) {
      Timer.run(startDownloads);
    }
  }

  Future<void> startDownloads() async {
    List<Future<void>> downloads = <Future>[];
    for (_ResolvedNotoSubset subset in pendingSubsets) {
      downloads.add(Future<void>(() async {
        ByteBuffer buffer;
        try {
          buffer = await downloader.downloadAsBytes(subset.url);
        } catch (e) {
          html.window.console
              .warn('Failed to load font ${subset.family} at ${subset.url}');
          html.window.console.warn(e);
          return;
        }

        final Uint8List bytes = buffer.asUint8List();
        skiaFontCollection.registerFallbackFont(subset.family, bytes);

        pendingSubsets.remove(subset);
        downloadedSubsets.add(subset);
        if (pendingSubsets.isEmpty) {
          await skiaFontCollection.ensureFontsLoaded();
          sendFontChangeMessage();
        }
      }));
    }

    await Future.wait<void>(downloads);
    if (pendingSubsets.isNotEmpty) {
      await startDownloads();
    }
  }
}

class NotoDownloader {
  int _debugActiveDownloadCount = 0;

  /// Returns a future that resolves when there are no pending downloads.
  ///
  /// Useful in tests to make sure that fonts are loaded before working with
  /// text.
  Future<void> debugWhenIdle() async {
    if (assertionsEnabled) {
      // Some downloads begin asynchronously in a microtask or in a Timer.run.
      // Let those run before waiting for downloads to finish.
      await Future<void>.delayed(Duration.zero);
      while (_debugActiveDownloadCount > 0) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        // If we started with a non-zero count and hit zero while waiting, wait a
        // little more to make sure another download doesn't get chained after
        // the last one (e.g. font file download after font CSS download).
        if (_debugActiveDownloadCount == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
    } else {
      throw UnimplementedError();
    }
  }

  /// Downloads the [url] and returns it as a [ByteBuffer].
  ///
  /// Override this for testing.
  Future<ByteBuffer> downloadAsBytes(String url) {
    if (assertionsEnabled) {
      _debugActiveDownloadCount += 1;
    }
    final Future<ByteBuffer> result = html.window.fetch(url).then((dynamic fetchResult) => fetchResult
        .arrayBuffer()
        .then<ByteBuffer>((dynamic x) => x as ByteBuffer));
    if (assertionsEnabled) {
      result.whenComplete(() {
        _debugActiveDownloadCount -= 1;
      });
    }
    return result;
  }

  /// Downloads the [url] and returns is as a [String].
  ///
  /// Override this for testing.
  Future<String> downloadAsString(String url) {
    if (assertionsEnabled) {
      _debugActiveDownloadCount += 1;
    }
    final Future<String> result = html.window.fetch(url).then((dynamic response) =>
        response.text().then<String>((dynamic x) => x as String));
    if (assertionsEnabled) {
      result.whenComplete(() {
        _debugActiveDownloadCount -= 1;
      });
    }
    return result;
  }
}

/// The Noto font interval tree.
IntervalTree<_NotoFont>? _notoTree;

FallbackFontDownloadQueue notoDownloadQueue = FallbackFontDownloadQueue();
