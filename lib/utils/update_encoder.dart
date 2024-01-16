import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_crdt/lib0/encoding.dart' as encoding;
import 'package:flutter_crdt/utils/id.dart';
import 'package:flutter_crdt/y_crdt_base.dart';

abstract class AbstractDSEncoder {
  encoding.Encoder restEncoder = encoding.createEncoder();

  Uint8List toUint8Array();

  void resetDsCurVal() {}

  void writeDsClock(int clock) {}

  void writeDsLen(int len) {}
}

abstract class AbstractUpdateEncoder extends AbstractDSEncoder {
  @override
  Uint8List toUint8Array();

  void writeLeftID(ID id) {}

  void writeRightID(ID id) {}

  void writeClient(int client) {}

  void writeInfo(int info) {}

  void writeString(String s) {}

  void writeParentInfo(bool isYKey) {}

  void writeTypeRef(int info) {}

  void writeLen(int len) {}

  void writeAny(dynamic any) {}

  void writeBuf(Uint8List buf) {}

  void writeJSON(dynamic embed) {}

  void writeKey(String key) {}
}

class DSEncoderV1 implements AbstractDSEncoder {
  @override
  encoding.Encoder restEncoder = encoding.Encoder();

  static DSEncoderV1 create() => DSEncoderV1();

  @override
  Uint8List toUint8Array() {
    return encoding.toUint8Array(this.restEncoder);
  }

  @override
  void resetDsCurVal() {
    // nop
  }

  @override
  void writeDsClock(int clock) {
    encoding.writeVarUint(this.restEncoder, clock);
  }

  @override
  void writeDsLen(int len) {
    encoding.writeVarUint(this.restEncoder, len);
  }
}

class UpdateEncoderV1 extends DSEncoderV1 implements AbstractUpdateEncoder {
  static UpdateEncoderV1 create() => UpdateEncoderV1();

  @override
  void writeLeftID(id) {
    encoding.writeVarUint(this.restEncoder, id.client);
    encoding.writeVarUint(this.restEncoder, id.clock);
  }

  @override
  void writeRightID(id) {
    encoding.writeVarUint(this.restEncoder, id.client);
    encoding.writeVarUint(this.restEncoder, id.clock);
  }

  @override
  void writeClient(client) {
    encoding.writeVarUint(this.restEncoder, client);
  }

  @override
  void writeInfo(info) {
    encoding.writeUint8(this.restEncoder, info);
  }

  @override
  void writeString(s) {
    encoding.writeVarString(this.restEncoder, s);
  }

  @override
  void writeParentInfo(isYKey) {
    encoding.writeVarUint(this.restEncoder, isYKey ? 1 : 0);
  }

  @override
  void writeTypeRef(info) {
    encoding.writeVarUint(this.restEncoder, info);
  }

  @override
  void writeLen(len) {
    encoding.writeVarUint(this.restEncoder, len);
  }

  @override
  void writeAny(dynamic any) {
    encoding.writeAny(this.restEncoder, any);
  }

  @override
  void writeBuf(buf) {
    encoding.writeVarUint8Array(this.restEncoder, buf);
  }

  @override
  void writeJSON(embed) {
    encoding.writeVarString(this.restEncoder, jsonEncode(embed));
  }

  @override
  void writeKey(key) {
    encoding.writeVarString(this.restEncoder, key);
  }
}

class DSEncoderV2 implements AbstractDSEncoder {
  static DSEncoderV2 create() => DSEncoderV2();

  @override
  encoding.Encoder restEncoder = encoding.Encoder();
  int dsCurrVal = 0;

  @override
  Uint8List toUint8Array() {
    return encoding.toUint8Array(this.restEncoder);
  }

  @override
  void resetDsCurVal() {
    this.dsCurrVal = 0;
  }

  @override
  void writeDsClock(int clock) {
    final diff = clock - this.dsCurrVal;
    this.dsCurrVal = clock;
    encoding.writeVarUint(this.restEncoder, diff);
  }

  @override
  void writeDsLen(int len) {
    if (len == 0) {
      ArgumentError.value(len, "len", "must be different than 0");
    }
    encoding.writeVarUint(this.restEncoder, len - 1);
    this.dsCurrVal += len;
  }
}

class UpdateEncoderV2 extends DSEncoderV2 implements AbstractUpdateEncoder {
  static UpdateEncoderV2 create() => UpdateEncoderV2();

  final keyMap = <String, int>{};

  int keyClock = 0;
  final keyClockEncoder = encoding.IntDiffOptRleEncoder();
  final clientEncoder = encoding.UintOptRleEncoder();
  final leftClockEncoder = encoding.IntDiffOptRleEncoder();
  final rightClockEncoder = encoding.IntDiffOptRleEncoder();
  final infoEncoder = encoding.RleEncoder(encoding.writeUint8);
  final stringEncoder = encoding.StringEncoder();
  final parentInfoEncoder = encoding.RleEncoder(encoding.writeUint8);
  final typeRefEncoder = encoding.UintOptRleEncoder();
  final lenEncoder = encoding.UintOptRleEncoder();

  @override
  Uint8List toUint8Array() {
    final encoder = encoding.createEncoder();
    encoding.writeUint8(
        encoder, 0); // this is a feature flag that we might use in the future
    encoding.writeVarUint8Array(encoder, this.keyClockEncoder.toUint8Array());
    encoding.writeVarUint8Array(encoder, this.clientEncoder.toUint8Array());
    encoding.writeVarUint8Array(encoder, this.leftClockEncoder.toUint8Array());
    encoding.writeVarUint8Array(encoder, this.rightClockEncoder.toUint8Array());
    encoding.writeVarUint8Array(
        encoder, encoding.toUint8Array(this.infoEncoder));
    encoding.writeVarUint8Array(encoder, this.stringEncoder.toUint8Array());
    encoding.writeVarUint8Array(
        encoder, encoding.toUint8Array(this.parentInfoEncoder));
    encoding.writeVarUint8Array(encoder, this.typeRefEncoder.toUint8Array());
    encoding.writeVarUint8Array(encoder, this.lenEncoder.toUint8Array());
    // @note The rest encoder is appended! (note the missing var)
    encoding.writeUint8Array(encoder, encoding.toUint8Array(this.restEncoder));
    return encoding.toUint8Array(encoder);
  }

  @override
  void writeLeftID(ID id) {
    this.clientEncoder.write(id.client);
    this.leftClockEncoder.write(id.clock);
  }

  @override
  void writeRightID(ID id) {
    this.clientEncoder.write(id.client);
    this.rightClockEncoder.write(id.clock);
  }

  @override
  void writeClient(int client) {
    this.clientEncoder.write(client);
  }

  @override
  void writeInfo(int info) {
    this.infoEncoder.write(info);
  }

  @override
  void writeString(String s) {
    this.stringEncoder.write(s);
  }

  @override
  void writeParentInfo(isYKey) {
    this.parentInfoEncoder.write(isYKey ? 1 : 0);
  }

  @override
  void writeTypeRef(int info) {
    this.typeRefEncoder.write(info);
  }

  @override
  void writeLen(int len) {
    this.lenEncoder.write(len);
  }

  @override
  void writeAny(dynamic any) {
    encoding.writeAny(this.restEncoder, any);
  }

  @override
  void writeBuf(Uint8List buf) {
    encoding.writeVarUint8Array(this.restEncoder, buf);
  }

  @override
  void writeJSON(dynamic embed) {
    encoding.writeAny(this.restEncoder, embed);
  }

  @override
  void writeKey(String key) {
    final clock = this.keyMap.get(key);
    if (clock == null) {
      this.keyClockEncoder.write(this.keyClock++);
      this.stringEncoder.write(key);
    } else {
      this.keyClockEncoder.write(this.keyClock++);
    }
  }
}
