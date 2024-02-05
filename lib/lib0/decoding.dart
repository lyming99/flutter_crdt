import 'dart:typed_data';

import 'package:fixnum/fixnum.dart' show Int64;
import 'package:flutter_crdt/lib0/binary.dart' as binary;

bool isNegativeZero(num n) => n != 0 ? n < 0 : 1 / n < 0;

int rightShift(int n, int shift) => Int64(n).shiftRightUnsigned(shift).toInt();

class Decoder {
  
  Decoder(this.arr);
  
  final Uint8List arr;
  
  int pos = 0;
}

Decoder createDecoder(Uint8List arr) => Decoder(arr);

bool hasContent(Decoder decoder) => decoder.pos != decoder.arr.length;

Decoder clone(Decoder decoder, [int? newPos]) {
  final _decoder = createDecoder(decoder.arr);
  if (newPos != null) {
    _decoder.pos = newPos;
  }
  return _decoder;
}

Uint8List readUint8Array(Decoder decoder, int len) {
  final view = Uint8List.view(
      decoder.arr.buffer, decoder.pos + decoder.arr.offsetInBytes, len);
  decoder.pos += len;
  return view;
}

Uint8List readVarUint8Array(Decoder decoder) =>
    readUint8Array(decoder, readVarUint(decoder));

Uint8List readTailAsUint8Array(Decoder decoder) =>
    readUint8Array(decoder, decoder.arr.length - decoder.pos);

int skip8(Decoder decoder) => decoder.pos++;

int readUint8(Decoder decoder) => decoder.arr[decoder.pos++];

int readUint16(Decoder decoder) {
  final uint = decoder.arr[decoder.pos] + (decoder.arr[decoder.pos + 1] << 8);
  decoder.pos += 2;
  return uint;
}

int readUint32(Decoder decoder) {
  final uint = rightShift(
      decoder.arr[decoder.pos] +
          (decoder.arr[decoder.pos + 1] << 8) +
          (decoder.arr[decoder.pos + 2] << 16) +
          (decoder.arr[decoder.pos + 3] << 24),
      0);
  decoder.pos += 4;
  return uint;
}

int readUint32BigEndian(Decoder decoder) {
  final uint = rightShift(
      decoder.arr[decoder.pos + 3] +
          (decoder.arr[decoder.pos + 2] << 8) +
          (decoder.arr[decoder.pos + 1] << 16) +
          (decoder.arr[decoder.pos] << 24),
      0);
  decoder.pos += 4;
  return uint;
}

int peekUint8(Decoder decoder) => decoder.arr[decoder.pos];

int peekUint16(Decoder decoder) =>
    decoder.arr[decoder.pos] + (decoder.arr[decoder.pos + 1] << 8);

int peekUint32(Decoder decoder) => rightShift(
    decoder.arr[decoder.pos] +
        (decoder.arr[decoder.pos + 1] << 8) +
        (decoder.arr[decoder.pos + 2] << 16) +
        (decoder.arr[decoder.pos + 3] << 24),
    0);

int readVarUint(Decoder decoder) {
  var number = 0;
  var len = 0;
  while (true) {
    final r = decoder.arr[decoder.pos++];
    number = number | ((r & binary.BITS7) << len);
    len += 7;
    if (r < binary.BIT8) {
      return rightShift(number, 0);
    }
    if (len > 35) {
      throw Exception('Integer out of range!');
    }
  }
}

int readVarInt(Decoder decoder) {
  var r = decoder.arr[decoder.pos++];
  var number = r & binary.BITS6;
  var len = 6;
  final sign = (r & binary.BIT7) > 0 ? -1 : 1;
  if ((r & binary.BIT8) == 0) {
    return sign * number;
  }
  while (true) {
    r = decoder.arr[decoder.pos++];
    number = number | ((r & binary.BITS7) << len);
    len += 7;
    if (r < binary.BIT8) {
      return sign * rightShift(number, 0);
    }
    if (len > 41) {
      throw Exception('Integer out of range!');
    }
  }
}

int peekVarUint(Decoder decoder) {
  final pos = decoder.pos;
  final s = readVarUint(decoder);
  decoder.pos = pos;
  return s;
}

int peekVarInt(Decoder decoder) {
  final pos = decoder.pos;
  final s = readVarInt(decoder);
  decoder.pos = pos;
  return s;
}

String readVarString(Decoder decoder) {
  var remainingLen = readVarUint(decoder);
  if (remainingLen == 0) {
    return '';
  } else {
    var encodedString = String.fromCharCode(
        readUint8(decoder)); // remember to decrease remainingLen
    if (--remainingLen < 100) {
      while (remainingLen-- != 0) {
        encodedString += String.fromCharCode(readUint8(decoder));
      }
    } else {
      while (remainingLen > 0) {
        final nextLen = remainingLen < 10000 ? remainingLen : 10000;
        final bytes = decoder.arr.sublist(decoder.pos, decoder.pos + nextLen);
        decoder.pos += nextLen;
        encodedString += String.fromCharCodes( bytes);
        remainingLen -= nextLen;
      }
    }
    return Uri.decodeComponent(encodedString);
  }
}

String peekVarString(Decoder decoder) {
  final pos = decoder.pos;
  final s = readVarString(decoder);
  decoder.pos = pos;
  return s;
}

ByteData readFromDataView(Decoder decoder, int len) {
  final dv = ByteData.view(
      decoder.arr.buffer, decoder.arr.offsetInBytes + decoder.pos, len);
  decoder.pos += len;
  return dv;
}


double readFloat32(Decoder decoder) =>
    readFromDataView(decoder, 4).getFloat32(0);


double readFloat64(Decoder decoder) =>
    readFromDataView(decoder, 8).getFloat64(0);


int readBigInt64(Decoder decoder) =>
     (readFromDataView(decoder, 8)).getInt64(0);


int readBigUint64(Decoder decoder) =>
     (readFromDataView(decoder, 8)).getUint64(0);


final readAnyLookupTable = [
  // TODO: undefined as null
  (decoder) => null, // CASE 127: undefined
  (decoder) => null, // CASE 126: null
  readVarInt, // CASE 125: integer
  readFloat32, // CASE 124: float32
  readFloat64, // CASE 123: float64
  readBigInt64, // CASE 122: bigint
  (decoder) => false, // CASE 121: boolean (false)
  (decoder) => true, // CASE 120: boolean (true)
  readVarString, // CASE 119: string
  (decoder) {
    // CASE 118: object<string,any>
    final len = readVarUint(decoder);
    
    final obj = {};
    for (var i = 0; i < len; i++) {
      final key = readVarString(decoder);
      obj[key] = readAny(decoder);
    }
    return obj;
  },
  (decoder) {
    // CASE 117: array<any>
    final len = readVarUint(decoder);
    final arr = [];
    for (var i = 0; i < len; i++) {
      arr.add(readAny(decoder));
    }
    return arr;
  },
  readVarUint8Array // CASE 116: Uint8List
];


dynamic readAny(Decoder decoder) =>
    readAnyLookupTable[127 - readUint8(decoder)](decoder);


class RleDecoder<T extends Object> extends Decoder {
  
  RleDecoder(Uint8List arr, this.reader) : super(arr);

  
  final T Function(Decoder) reader;
  
  T? s;
  int count = 0;

  T? read() {
    if (this.count == 0) {
      this.s = this.reader(this);
      if (hasContent(this)) {
        this.count = readVarUint(this) +
            1; // see encoder implementation for the reason why this is incremented
      } else {
        this.count = -1; // read the current value forever
      }
    }
    this.count--;
    return  this.s;
  }
}

class IntDiffDecoder extends Decoder {
  
  IntDiffDecoder(Uint8List arr, this.s) : super(arr);
  
  int s;

  
  int read() {
    this.s += readVarInt(this);
    return this.s;
  }
}

class RleIntDiffDecoder extends Decoder {
  
  RleIntDiffDecoder(Uint8List arr, this.s) : super(arr);
  
  int s;
  int count = 0;

  
  int read() {
    if (this.count == 0) {
      this.s += readVarInt(this);
      if (hasContent(this)) {
        this.count = readVarUint(this) +
            1; // see encoder implementation for the reason why this is incremented
      } else {
        this.count = -1; // read the current value forever
      }
    }
    this.count--;
    return  this.s;
  }
}

class UintOptRleDecoder extends Decoder {
  
  UintOptRleDecoder(Uint8List arr) : super(arr);
  
  int s = 0;
  int count = 0;

  int read() {
    if (this.count == 0) {
      this.s = readVarInt(this);
      // if the sign is negative, we read the count too, otherwise count is 1
      final isNegative = isNegativeZero(this.s);
      this.count = 1;
      if (isNegative) {
        this.s = -this.s;
        this.count = readVarUint(this) + 2;
      }
    }
    this.count--;
    return  this.s;
  }
}

class IncUintOptRleDecoder extends Decoder {
  
  IncUintOptRleDecoder(Uint8List arr) : super(arr);
  
  int s = 0;
  int count = 0;

  int read() {
    if (this.count == 0) {
      this.s = readVarInt(this);
      // if the sign is negative, we read the count too, otherwise count is 1
      final isNegative = isNegativeZero(this.s);
      this.count = 1;
      if (isNegative) {
        this.s = -this.s;
        this.count = readVarUint(this) + 2;
      }
    }
    this.count--;
    return  this.s++;
  }
}

class IntDiffOptRleDecoder extends Decoder {
  
  IntDiffOptRleDecoder(Uint8List arr) : super(arr);
  
  int s = 0;
  int count = 0;
  int diff = 0;

  
  int read() {
    if (this.count == 0) {
      final diff = readVarInt(this);
      // if the first bit is set, we read more data
      final hasCount = diff & 1;
      this.diff = diff >> 1;
      this.count = 1;
      if (hasCount != 0) {
        this.count = readVarUint(this) + 2;
      }
    }
    this.s += this.diff;
    this.count--;
    return this.s;
  }
}

class StringDecoder {
  
  StringDecoder(Uint8List arr) {
    this.decoder = UintOptRleDecoder(arr);
    this.str = readVarString(this.decoder);
  }
  late final UintOptRleDecoder decoder;
  
  int spos = 0;
  late final String str;

  
  String read() {
    final end = this.spos + this.decoder.read();
    final res = this.str.substring(this.spos, end);
    this.spos = end;
    return res;
  }
}
