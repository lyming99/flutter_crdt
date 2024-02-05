import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_crdt/lib0/binary.dart' as binary;
import 'package:flutter_crdt/lib0/decoding.dart' show isNegativeZero, rightShift;

class Encoder {
  Encoder();
  int cpos = 0;
  Uint8List cbuf = Uint8List(100);
  
  final List<Uint8List> bufs = [];
}

Encoder createEncoder() => Encoder();

int length(Encoder encoder) {
  var len = encoder.cpos;
  for (var i = 0; i < encoder.bufs.length; i++) {
    len += encoder.bufs[i].length;
  }
  return len;
}


Uint8List _toUint8Array(Encoder encoder) {
  final uint8arr = Uint8List(length(encoder));
  var curPos = 0;
  for (var i = 0; i < encoder.bufs.length; i++) {
    final d = encoder.bufs[i];
    uint8arr.setAll(curPos, d);
    curPos += d.length;
  }
  uint8arr.setAll(
    curPos,
    Uint8List.view(encoder.cbuf.buffer, 0, encoder.cpos),
  );
  return uint8arr;
}

const toUint8Array = _toUint8Array;


void verifyLen(Encoder encoder, int len) {
  final bufferLen = encoder.cbuf.length;
  if (bufferLen - encoder.cpos < len) {
    encoder.bufs.add(Uint8List.view(encoder.cbuf.buffer, 0, encoder.cpos));
    encoder.cbuf = Uint8List(math.max(bufferLen, len) * 2);
    encoder.cpos = 0;
  }
}


void write(Encoder encoder, int number) {
  final bufferLen = encoder.cbuf.length;
  if (encoder.cpos == bufferLen) {
    encoder.bufs.add(encoder.cbuf);
    encoder.cbuf = Uint8List(bufferLen * 2);
    encoder.cpos = 0;
  }
  encoder.cbuf[encoder.cpos++] = number;
}


void set(Encoder encoder, int pos, int number) {
  Uint8List? buffer;
  // iterate all buffers and adjust position
  for (var i = 0; i < encoder.bufs.length && buffer == null; i++) {
    final b = encoder.bufs[i];
    if (pos < b.length) {
      buffer = b; // found buffer
    } else {
      pos -= b.length;
    }
  }
  if (buffer == null) {
    // use current buffer
    buffer = encoder.cbuf;
  }
  buffer[pos] = number;
}


const writeUint8 = write;


const setUint8 = set;


void writeUint16(Encoder encoder, int number) {
  write(encoder, number & binary.BITS8);
  write(encoder, rightShift(number, 8) & binary.BITS8);
}


void setUint16(Encoder encoder, int pos, int number) {
  set(encoder, pos, number & binary.BITS8);
  set(encoder, pos + 1, rightShift(number, 8) & binary.BITS8);
}


void writeUint32(Encoder encoder, int number) {
  for (var i = 0; i < 4; i++) {
    write(encoder, number & binary.BITS8);
    number = rightShift(number, 8);
  }
}


void writeUint32BigEndian(Encoder encoder, int number) {
  for (var i = 3; i >= 0; i--) {
    write(encoder, rightShift(number, 8 * i) & binary.BITS8);
  }
}


void setUint32(Encoder encoder, int pos, int number) {
  for (var i = 0; i < 4; i++) {
    set(encoder, pos + i, number & binary.BITS8);
    number = rightShift(number, 8);
  }
}

/**
 * Write a variable length unsigned integer.
 *
 * Encodes integers in the range from [0, 4294967295] / [0, 0xffffffff]. (max 32 bit unsigned integer)
 *
 * @function
 * @param {Encoder} encoder
 * @param {number} num The number that is to be encoded.
 */
void writeVarUint(Encoder encoder, int number) {
  while (number > binary.BITS7) {
    write(encoder, binary.BIT8 | (binary.BITS7 & number));
    number = rightShift(number, 7);
  }
  write(encoder, binary.BITS7 & number);
}


void writeVarInt(Encoder encoder, int number) {
  final isNegative = isNegativeZero(number);
  if (isNegative) {
    number = -number;
  }
  //             |- whether to continue reading         |- whether is negative     |- number
  write(
      encoder,
      (number > binary.BITS6 ? binary.BIT8 : 0) |
          (isNegative ? binary.BIT7 : 0) |
          (binary.BITS6 & number));
  number = rightShift(number, 6);
  // We don't need to consider the case of num === 0 so we can use a different
  // pattern here than above.
  while (number > 0) {
    write(encoder,
        (number > binary.BITS7 ? binary.BIT8 : 0) | (binary.BITS7 & number));
    number = rightShift(number, 7);
  }
}


void writeVarString(Encoder encoder, String str) {
  // TODO:
  // final encodedString = unescape(encodeURIComponent(str));
  final encodedString = Uri.encodeComponent(str);
  final len = encodedString.length;
  writeVarUint(encoder, len);
  for (var i = 0; i < len; i++) {
    write(encoder,  encodedString.codeUnitAt(i));
  }
}


void writeBinaryEncoder(Encoder encoder, Encoder append) =>
    writeUint8Array(encoder, _toUint8Array(append));


void writeUint8Array(Encoder encoder, Uint8List uint8Array) {
  final bufferLen = encoder.cbuf.length;
  final cpos = encoder.cpos;
  final leftCopyLen = math.min(bufferLen - cpos, uint8Array.length);
  final rightCopyLen = uint8Array.length - leftCopyLen;
  encoder.cbuf.setAll(cpos, uint8Array.sublist(0, leftCopyLen));
  encoder.cpos += leftCopyLen;
  if (rightCopyLen > 0) {
    // Still something to write, write right half..
    // Append new buffer
    encoder.bufs.add(encoder.cbuf);
    // must have at least size of remaining buffer
    encoder.cbuf = Uint8List(math.max(bufferLen * 2, rightCopyLen));
    // copy array
    encoder.cbuf.setAll(0, uint8Array.sublist(leftCopyLen));
    encoder.cpos = rightCopyLen;
  }
}


void writeVarUint8Array(Encoder encoder, Uint8List uint8Array) {
  writeVarUint(encoder, uint8Array.lengthInBytes);
  writeUint8Array(encoder, uint8Array);
}

/**
 * Create an DataView of the next `len` bytes. Use it to write data after
 * calling this function.
 *
 * ```js
 * // write float32 using DataView
 * const dv = writeOnDataView(encoder, 4)
 * dv.setFloat32(0, 1.1)
 * // read float32 using DataView
 * const dv = readFromDataView(encoder, 4)
 * dv.getFloat32(0) // => 1.100000023841858 (leaving it to the reader to find out why this is the correct result)
 * ```
 *
 * @param {Encoder} encoder
 * @param {number} len
 * @return {DataView}
 */
ByteData writeOnDataView(Encoder encoder, int len) {
  verifyLen(encoder, len);
  final dview = ByteData.view(encoder.cbuf.buffer, encoder.cpos, len);
  encoder.cpos += len;
  return dview;
}


void writeFloat32(Encoder encoder, double number) =>
    writeOnDataView(encoder, 4).setFloat32(0, number);


void writeFloat64(Encoder encoder, double number) =>
    writeOnDataView(encoder, 8).setFloat64(0, number);


void writeBigInt64(Encoder encoder, BigInt number) =>
     (writeOnDataView(encoder, 8))
        .setInt64(0, number.toInt());


void writeBigUint64(Encoder encoder, BigInt number) =>
     (writeOnDataView(encoder, 8))
        .setUint64(0, number.toInt());

final floatTestBed = ByteData(4);

bool isFloat32(double number) {
  floatTestBed.setFloat32(0, number);
  return floatTestBed.getFloat32(0) == number;
}

/**
 * Encode data with efficient binary format.
 *
 * Differences to JSON:
 * • Transforms data to a binary format (not to a string)
 * • Encodes undefined, NaN, and ArrayBuffer (these can't be represented in JSON)
 * • Numbers are efficiently encoded either as a variable length integer, as a
 *   32 bit float, as a 64 bit float, or as a 64 bit bigint.
 *
 * Encoding table:
 *
 * | Data Type           | Prefix   | Encoding Method    | Comment |
 * | ------------------- | -------- | ------------------ | ------- |
 * | undefined           | 127      |                    | Functions, symbol, and everything that cannot be identified is encoded as undefined |
 * | null                | 126      |                    | |
 * | integer             | 125      | writeVarInt        | Only encodes 32 bit signed integers |
 * | float32             | 124      | writeFloat32       | |
 * | float64             | 123      | writeFloat64       | |
 * | bigint              | 122      | writeBigInt64      | |
 * | boolean (false)     | 121      |                    | True and false are different data types so we save the following byte |
 * | boolean (true)      | 120      |                    | - 0b01111000 so the last bit determines whether true or false |
 * | string              | 119      | writeVarString     | |
 * | object<string,any>  | 118      | custom             | Writes {length} then {length} key-value pairs |
 * | array<any>          | 117      | custom             | Writes {length} then {length} json values |
 * | Uint8Array          | 116      | writeVarUint8Array | We use Uint8Array for any kind of binary data |
 *
 * Reasons for the decreasing prefix:
 * We need the first bit for extendability (later we may want to encode the
 * prefix with writeVarUint). The remaining 7 bits are divided as follows:
 * [0-30]   the beginning of the data range is used for custom purposes
 *          (defined by the function that uses this library)
 * [31-127] the end of the data range is used for data encoding by
 *          lib0/encoding.js
 *
 * @param {Encoder} encoder
 * @param {undefined|null|number|bigint|boolean|string|Object<string,any>|Array<any>|Uint8Array} data
 */
void writeAny(Encoder encoder, dynamic _data) {
  final data = _data;
  if (data is String) {
    // TYPE 119: STRING
    write(encoder, 119);
    writeVarString(encoder, data);
  } else if (data is int) {
    // TODO: && data <= binary.BITS31
    // TYPE 125: INTEGER
    write(encoder, 125);
    writeVarInt(encoder, data);
  } else if (data is double) {
    if (isFloat32(data)) {
      // TYPE 124: FLOAT32
      write(encoder, 124);
      writeFloat32(encoder, data);
    } else {
      // TYPE 123: FLOAT64
      write(encoder, 123);
      writeFloat64(encoder, data);
    }
  } else if (data is BigInt) {
    // TYPE 122: BigInt
    write(encoder, 122);
    writeBigInt64(encoder, data);
  } else if (data == null) {
    // TYPE 126: null
    write(encoder, 126);
  } else if (data is Uint8List) {
    // TYPE 116: ArrayBuffer
    write(encoder, 116);
    writeVarUint8Array(encoder, data);
  } else if (data is List) {
    // TYPE 117: Array
    write(encoder, 117);
    writeVarUint(encoder, data.length);
    for (var i = 0; i < data.length; i++) {
      writeAny(encoder, data[i]);
    }
  } else if (data is Map) {
    // TYPE 118: Object
    write(encoder, 118);
    final keys = data.keys.toList().cast<String>();
    writeVarUint(encoder, keys.length);
    for (var i = 0; i < keys.length; i++) {
      final key = keys[i];
      writeVarString(encoder, key);
      writeAny(encoder, data[key]);
    }
  } else if (data is bool) {
    // TYPE 120/121: boolean (true/false)
    write(encoder, data ? 120 : 121);
  } else {
    // TYPE 127: undefined
    write(encoder, 127);
  }
}



/**
 * Basic Run Length Encoder - a basic compression implementation.
 *
 * Encodes [1,1,1,7] to [1,3,7,1] (3 times 1, 1 time 7). This encoder might do more harm than good if there are a lot of values that are not repeated.
 *
 * It was originally used for image compression. Cool .. article http://csbruce.com/cbm/transactor/pdfs/trans_v7_i06.pdf
 *
 * @note T must not be null!
 *
 * @template T
 */
class RleEncoder<T> extends Encoder {
  
  RleEncoder(this.w);
  
  T? s;
  int count = 0;

  
  void Function(Encoder, T) w;

  
  void write(T v) {
    if (this.s == v) {
      this.count++;
    } else {
      if (this.count > 0) {
        // flush counter, unless this is the first value (count = 0)
        writeVarUint(
            this,
            this.count -
                1); // since count is always > 0, we can decrement by one. non-standard encoding ftw
      }
      this.count = 1;
      // write first value
      this.w(this, v);
      this.s = v;
    }
  }
}


class IntDiffEncoder extends Encoder {
  
  IntDiffEncoder(this.s);
  
  int s;

  
  void write(int v) {
    writeVarInt(this, v - this.s);
    this.s = v;
  }
}


class RleIntDiffEncoder extends Encoder {
  
  RleIntDiffEncoder(this.s);
  
  int s;
  int count = 0;

  
  void write(int v) {
    if (this.s == v && this.count > 0) {
      this.count++;
    } else {
      if (this.count > 0) {
        // flush counter, unless this is the first value (count = 0)
        writeVarUint(
            this,
            this.count -
                1); // since count is always > 0, we can decrement by one. non-standard encoding ftw
      }
      this.count = 1;
      // write first value
      writeVarInt(this, v - this.s);
      this.s = v;
    }
  }
}


void flushUintOptRleEncoder(UintOptRleEncoder encoder) {
  if (encoder.count > 0) {
    // flush counter, unless this is the first value (count = 0)
    // case 1: just a single value. set sign to positive
    // case 2: write several values. set sign to negative to indicate that there is a length coming
    writeVarInt(encoder.encoder, encoder.count == 1 ? encoder.s : -encoder.s);
    if (encoder.count > 1) {
      writeVarUint(
          encoder.encoder,
          encoder.count -
              2); // since count is always > 1, we can decrement by one. non-standard encoding ftw
    }
  }
}


class UintOptRleEncoder {
  UintOptRleEncoder();
  final encoder = Encoder();
  
  int s = 0;
  int count = 0;

  
  void write(int v) {
    if (this.s == v) {
      this.count++;
    } else {
      flushUintOptRleEncoder(this);
      this.count = 1;
      this.s = v;
    }
  }

  Uint8List toUint8Array() {
    flushUintOptRleEncoder(this);
    return _toUint8Array(this.encoder);
  }
}


class IncUintOptRleEncoder implements UintOptRleEncoder {
  IncUintOptRleEncoder();
  @override
  final encoder = Encoder();
  
  @override
  int s = 0;
  @override
  int count = 0;

  
  @override
  void write(int v) {
    if (this.s + this.count == v) {
      this.count++;
    } else {
      flushUintOptRleEncoder(this);
      this.count = 1;
      this.s = v;
    }
  }

  @override
  Uint8List toUint8Array() {
    flushUintOptRleEncoder(this);
    return _toUint8Array(this.encoder);
  }
}


void flushIntDiffOptRleEncoder(IntDiffOptRleEncoder encoder) {
  if (encoder.count > 0) {
    //          31 bit making up the diff | wether to write the counter
    final encodedDiff = encoder.diff << 1 | (encoder.count == 1 ? 0 : 1);
    // flush counter, unless this is the first value (count = 0)
    // case 1: just a single value. set first bit to positive
    // case 2: write several values. set first bit to negative to indicate that there is a length coming
    writeVarInt(encoder.encoder, encodedDiff);
    if (encoder.count > 1) {
      writeVarUint(
          encoder.encoder,
          encoder.count -
              2); // since count is always > 1, we can decrement by one. non-standard encoding ftw
    }
  }
}


class IntDiffOptRleEncoder {
  IntDiffOptRleEncoder();
  final encoder = Encoder();
  
  int s = 0;
  int count = 0;
  int diff = 0;

  
  void write(int v) {
    if (this.diff == v - this.s) {
      this.s = v;
      this.count++;
    } else {
      flushIntDiffOptRleEncoder(this);
      this.count = 1;
      this.diff = v - this.s;
      this.s = v;
    }
  }

  Uint8List toUint8Array() {
    flushIntDiffOptRleEncoder(this);
    return _toUint8Array(this.encoder);
  }
}


class StringEncoder {
  StringEncoder();
  
  final sarr = <String>[];
  var s = '';
  final lensE = UintOptRleEncoder();

  
  void write(String string) {
    this.s += string;
    if (this.s.length > 19) {
      this.sarr.add(this.s);
      this.s = '';
    }
    this.lensE.write(string.length);
  }

  Uint8List toUint8Array() {
    final encoder = Encoder();
    this.sarr.add(this.s);
    this.s = '';
    writeVarString(encoder, this.sarr.join(''));
    writeUint8Array(encoder, this.lensE.toUint8Array());
    return _toUint8Array(encoder);
  }
}
