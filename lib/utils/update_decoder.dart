import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_crdt/lib0/decoding.dart';
import 'package:flutter_crdt/lib0/decoding.dart' as decoding;
import 'package:flutter_crdt/utils/id.dart';

abstract class AbstractDSDecoder {
  AbstractDSDecoder(this.restDecoder) {
    UnimplementedError();
  }
  final decoding.Decoder restDecoder;

  resetDsCurVal() {}

  int readDsClock();

  int readDsLen();
}

abstract class AbstractUpdateDecoder extends AbstractDSDecoder {
  AbstractUpdateDecoder(Decoder decoder) : super(decoder);

  ID readLeftID();

  ID readRightID();

  int readClient();

  int readInfo();

  String readString();

  bool readParentInfo();

  int readTypeRef();

  int readLen();

  dynamic readAny();

  Uint8List readBuf();

  dynamic readJSON();

  String readKey();
}

class DSDecoderV1 implements AbstractDSDecoder {
  DSDecoderV1(this.restDecoder);
  @override
  final decoding.Decoder restDecoder;
  static DSDecoderV1 create(decoding.Decoder decoder) => DSDecoderV1(decoder);

  @override
  resetDsCurVal() {
    // nop
  }

  @override
  int readDsClock() {
    return decoding.readVarUint(this.restDecoder);
  }

  @override
  int readDsLen() {
    return decoding.readVarUint(this.restDecoder);
  }
}

class UpdateDecoderV1 extends DSDecoderV1 implements AbstractUpdateDecoder {
  UpdateDecoderV1(Decoder decoder) : super(decoder);
  static UpdateDecoderV1 create(decoding.Decoder decoder) =>
      UpdateDecoderV1(decoder);

  @override
  ID readLeftID() {
    return createID(decoding.readVarUint(this.restDecoder),
        decoding.readVarUint(this.restDecoder));
  }

  @override
  ID readRightID() {
    return createID(decoding.readVarUint(this.restDecoder),
        decoding.readVarUint(this.restDecoder));
  }

  @override
  int readClient() {
    return decoding.readVarUint(this.restDecoder);
  }

  @override
  int readInfo() {
    return decoding.readUint8(this.restDecoder);
  }

  @override
  String readString() {
    return decoding.readVarString(this.restDecoder);
  }

  @override
  bool readParentInfo() {
    return decoding.readVarUint(this.restDecoder) == 1;
  }

  @override
  int readTypeRef() {
    return decoding.readVarUint(this.restDecoder);
  }

  @override
  int readLen() {
    return decoding.readVarUint(this.restDecoder);
  }

  @override
  dynamic readAny() {
    return decoding.readAny(this.restDecoder);
  }

  @override
  Uint8List readBuf() {
    // TODO:
    return Uint8List.fromList(decoding.readVarUint8Array(this.restDecoder));
  }

  @override
  dynamic readJSON() {
    return jsonDecode(decoding.readVarString(this.restDecoder));
  }

  @override
  String readKey() {
    return decoding.readVarString(this.restDecoder);
  }
}

class DSDecoderV2 implements AbstractDSDecoder {
  DSDecoderV2(this.restDecoder);
  int dsCurrVal = 0;
  @override
  final decoding.Decoder restDecoder;
  static DSDecoderV2 create(decoding.Decoder decoder) => DSDecoderV2(decoder);

  @override
  void resetDsCurVal() {
    this.dsCurrVal = 0;
  }

  @override
  int readDsClock() {
    this.dsCurrVal += decoding.readVarUint(this.restDecoder);
    return this.dsCurrVal;
  }

  @override
  int readDsLen() {
    final diff = decoding.readVarUint(this.restDecoder) + 1;
    this.dsCurrVal += diff;
    return diff;
  }
}

class UpdateDecoderV2 extends DSDecoderV2 implements AbstractUpdateDecoder {
  static UpdateDecoderV2 create(decoding.Decoder decoder) =>
      UpdateDecoderV2(decoder);
  UpdateDecoderV2(Decoder decoder) : super(decoder) {
    decoding.readUint8(decoder); // read feature flag - currently unused
    this.keyClockDecoder =
        decoding.IntDiffOptRleDecoder(decoding.readVarUint8Array(decoder));
    this.clientDecoder =
        decoding.UintOptRleDecoder(decoding.readVarUint8Array(decoder));
    this.leftClockDecoder =
        decoding.IntDiffOptRleDecoder(decoding.readVarUint8Array(decoder));
    this.rightClockDecoder =
        decoding.IntDiffOptRleDecoder(decoding.readVarUint8Array(decoder));
    this.infoDecoder = decoding.RleDecoder(
        decoding.readVarUint8Array(decoder), decoding.readUint8);
    this.stringDecoder =
        decoding.StringDecoder(decoding.readVarUint8Array(decoder));
    this.parentInfoDecoder = decoding.RleDecoder(
        decoding.readVarUint8Array(decoder), decoding.readUint8);
    this.typeRefDecoder =
        decoding.UintOptRleDecoder(decoding.readVarUint8Array(decoder));
    this.lenDecoder =
        decoding.UintOptRleDecoder(decoding.readVarUint8Array(decoder));
  }
  final keys = <String>[];
  late final IntDiffOptRleDecoder keyClockDecoder;
  late final UintOptRleDecoder clientDecoder;
  late final IntDiffOptRleDecoder leftClockDecoder;
  late final IntDiffOptRleDecoder rightClockDecoder;
  late final RleDecoder infoDecoder;
  late final StringDecoder stringDecoder;
  late final RleDecoder parentInfoDecoder;
  late final UintOptRleDecoder typeRefDecoder;
  late final UintOptRleDecoder lenDecoder;

  @override
  ID readLeftID() {
    return ID(this.clientDecoder.read(), this.leftClockDecoder.read());
  }

  @override
  ID readRightID() {
    return ID(this.clientDecoder.read(), this.rightClockDecoder.read());
  }

  @override
  readClient() {
    return this.clientDecoder.read();
  }

  @override
  int readInfo() {
    return /** @type {number} */ this.infoDecoder.read() as int;
  }

  @override
  String readString() {
    return this.stringDecoder.read();
  }

  @override
  bool readParentInfo() {
    return this.parentInfoDecoder.read() == 1;
  }

  @override
  int readTypeRef() {
    return this.typeRefDecoder.read();
  }

  @override
  int readLen() {
    return this.lenDecoder.read();
  }

  @override
  dynamic readAny() {
    return decoding.readAny(this.restDecoder);
  }

  @override
  Uint8List readBuf() {
    return decoding.readVarUint8Array(this.restDecoder);
  }

  @override
  dynamic readJSON() {
    return decoding.readAny(this.restDecoder);
  }

  @override
  String readKey() {
    final keyClock = this.keyClockDecoder.read();
    if (keyClock < this.keys.length) {
      return this.keys[keyClock];
    } else {
      final key = this.stringDecoder.read();
      this.keys.add(key);
      return key;
    }
  }
}
