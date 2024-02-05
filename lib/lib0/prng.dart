import 'dart:math';
import 'package:flutter_crdt/lib0/decoding.dart' show rightShift;

Random create(int seed) => Random(seed);

int int32(Random gen, int min, int max) =>
    max == min ? max : gen.nextInt(max - min) + min;

int uint32(Random gen, int min, int max) => rightShift(int32(gen, min, max), 0);

String letter(Random gen) => String.fromCharCode(int32(gen, 97, 122));

String word(Random gen, [int minLen = 0, int maxLen = 20]) {
  final len = int32(gen, minLen, maxLen);
  var str = "";
  for (var i = 0; i < len; i++) {
    str += letter(gen);
  }
  return str;
}

String utf16Rune(Random gen) {
  final codepoint = int32(gen, 0, 256);
  return String.fromCharCode(codepoint);
}

String utf16String(Random gen, [int maxlen = 20]) {
  final len = int32(gen, 0, maxlen);
  var str = "";
  for (var i = 0; i < len; i++) {
    str += utf16Rune(gen);
  }
  return str;
}

T oneOf<T>(Random gen, List<T> array) => array[int32(gen, 0, array.length - 1)];