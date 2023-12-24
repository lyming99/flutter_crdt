import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_crdt/structs/abstract_struct.dart';
import 'package:flutter_crdt/utils/update_decoder.dart';
import 'package:flutter_crdt/utils/update_encoder.dart';
import "package:flutter_crdt/lib0/decoding.dart" as decoding;
import "package:flutter_crdt/lib0/encoding.dart" as encoding;
import 'package:flutter_crdt/lib0/binary.dart' as binary;
import '../structs/content_deleted.dart';
import '../structs/content_type.dart';
import '../structs/gc.dart';
import '../structs/item.dart';
import '../structs/skip.dart';
import 'delete_set.dart';
import 'encoding.dart';
import 'id.dart';

/**
 * @param decoder UpdateDecoderV1 or UpdateDecoderV2
 */
Iterable<AbstractStruct> lazyStructReaderGenerator(
    AbstractUpdateDecoder decoder) sync* {
  final numOfStateUpdates = decoding.readVarUint(decoder.restDecoder);
  for (var i = 0; i < numOfStateUpdates; i++) {
    final numberOfStructs = decoding.readVarUint(decoder.restDecoder);
    final client = decoder.readClient();
    var clock = decoding.readVarUint(decoder.restDecoder);
    for (var i = 0; i < numberOfStructs; i++) {
      final info = decoder.readInfo();
      // @todo use switch instead of ifs
      if (info == 10) {
        final len = decoding.readVarUint(decoder.restDecoder);
        yield Skip(createID(client, clock), len);
        clock += len;
      } else if ((binary.BITS5 & info) != 0) {
        final cantCopyParentInfo = (info & (binary.BIT7 | binary.BIT8)) == 0;
        // If parent = null and neither left nor right are defined, then we know that `parent` is child of `y`
        // and we read the next string as parentYKey.
        // It indicates how we store/retrieve parent from `y.share`
        // @type {string|null}
        final struct = Item(
          createID(client, clock),
          null,
          // left
          (info & binary.BIT8) == binary.BIT8 ? decoder.readLeftID() : null,
          // origin
          null,
          // right
          (info & binary.BIT7) == binary.BIT7 ? decoder.readRightID() : null,
          // right origin
          // @ts-ignore Force writing a string here.
          cantCopyParentInfo
              ? (decoder.readParentInfo()
                  ? decoder.readString()
                  : decoder.readLeftID())
              : null,
          // parent
          cantCopyParentInfo && (info & binary.BIT6) == binary.BIT6
              ? decoder.readString()
              : null,
          // parentSub
          readItemContent(decoder, info), // item content
        );
        yield struct;
        clock += struct.length;
      } else {
        final len = decoder.readLen();
        yield GC(createID(client, clock), len);
        clock += len;
      }
    }
  }
}

class LazyStructReader {
  AbstractStruct? curr;
  AbstractUpdateDecoder decoder;
  bool filterSkips;
  late Iterator gen;
  late bool done;

  LazyStructReader(this.decoder, this.filterSkips) {
    gen = lazyStructReaderGenerator(decoder).iterator;
    done = false;
    next();
  }

  AbstractStruct? next() {
    do {
      curr = gen.moveNext() ? gen.current : null;
    } while (filterSkips && curr != null && curr.runtimeType == Skip);
    return curr;
  }
}

/**
 * @param {Uint8Array} update
 *
 */
void logUpdate(Uint8List update) {
  logUpdateV2(update, UpdateDecoderV1.create(decoding.Decoder(update)));
}

/**
 * @param update Uint8List
 * @param YDecoder Type<UpdateDecoderV2> | Type<UpdateDecoderV1>
 *
 */
void logUpdateV2(Uint8List update, AbstractUpdateDecoder updateDecoder) {
  final List<dynamic> structs = [];
  final lazyDecoder = LazyStructReader(updateDecoder, false);
  for (var curr = lazyDecoder.curr; curr != null; curr = lazyDecoder.next()) {
    structs.add(curr);
  }
  readDeleteSet(updateDecoder);
}

/**
 * @param {Uint8List} update
 *
 */
Map<String, dynamic> decodeUpdate(Uint8List update) =>
    decodeUpdateV2(update, (e) => UpdateDecoderV1.create(e));

/**
 * @param update Uint8List
 * @param YDecoder Type<UpdateDecoderV2> | Type<UpdateDecoderV1>
 *
 */
Map<String, dynamic> decodeUpdateV2(Uint8List update,
    [AbstractUpdateDecoder Function(decoding.Decoder decoder)? updateDecoder]) {
  updateDecoder ??= (e) => UpdateDecoderV2(e);
  final structs = [];
  var decoder = updateDecoder.call(decoding.Decoder(update));
  final lazyDecoder = LazyStructReader(decoder, false);
  for (var curr = lazyDecoder.curr; curr != null; curr = lazyDecoder.next()) {
    structs.add(curr);
  }
  return {'structs': structs, 'ds': readDeleteSet(decoder)};
}

class LazyStructWriter {
  AbstractUpdateEncoder encoder;
  int currClient = 0;
  int startClock = 0;
  int written = 0;
  List<Map<String, dynamic>> clientStructs = [];

  LazyStructWriter(this.encoder);
}

/**
 * @param {List<Uint8List>} updates
 * @return {Uint8List}
 */
Uint8List mergeUpdates(List<Uint8List> updates) => mergeUpdatesV2(
    updates, (e) => UpdateDecoderV1.create(e), () => UpdateEncoderV1.create());

/**
 * @param update {Uint8List}
 * @param YEncoder {Type<DSEncoderV1> | Type<DSEncoderV2>}
 * @param YDecoder {Type<UpdateDecoderV1> | Type<UpdateDecoderV2>}
 * @return {Uint8List}
 */
Uint8List encodeStateVectorFromUpdateV2(
  Uint8List update, [
  AbstractDSEncoder Function()? YEncoder,
  AbstractUpdateDecoder Function(decoding.Decoder decoder)? YDecoder,
]) {
  YEncoder ??= () => DSEncoderV2.create();
  YDecoder ??= (decoder) => UpdateDecoderV2(decoder);
  var encoder = YEncoder.call();
  final updateDecoder =
      LazyStructReader(YDecoder.call(decoding.createDecoder(update)), false);
  var curr = updateDecoder.curr;
  if (curr != null) {
    var size = 0;
    var currClient = curr.id.client;
    var stopCounting = curr.id.clock != 0; // must start at 0
    var currClock = stopCounting ? 0 : curr.id.clock + curr.length;
    for (; curr != null; curr = updateDecoder.next()) {
      if (currClient != curr.id.client) {
        if (currClock != 0) {
          size++;
          // We found a new client
          // write what we have to the encoder
          encoding.writeVarUint(encoder.restEncoder, currClient);
          encoding.writeVarUint(encoder.restEncoder, currClock);
        }
        currClient = curr.id.client;
        currClock = 0;
        stopCounting = curr.id.clock != 0;
      }
      // we ignore skips
      if (curr.runtimeType == Skip) {
        stopCounting = true;
      }
      if (!stopCounting) {
        currClock = curr.id.clock + curr.length;
      }
    }
    // write what we have
    if (currClock != 0) {
      size++;
      encoding.writeVarUint(encoder.restEncoder, currClient);
      encoding.writeVarUint(encoder.restEncoder, currClock);
    }
    // prepend the size of the state vector
    final enc = encoding.createEncoder();
    encoding.writeVarUint(enc, size);
    encoding.writeBinaryEncoder(enc, encoder.restEncoder);
    encoder.restEncoder = enc;
    return encoder.toUint8Array();
  } else {
    encoding.writeVarUint(encoder.restEncoder, 0);
    return encoder.toUint8Array();
  }
}

Map parseUpdateMetaV2(Uint8List update,
    {AbstractUpdateDecoder Function(decoding.Decoder decoder)? YDecoder}) {
  YDecoder ??= (dd) => UpdateDecoderV2.create(dd);
  Map<int, int> from = {};
  Map<int, int> to = {};
  LazyStructReader updateDecoder =
      LazyStructReader(YDecoder(decoding.createDecoder(update)), false);
  var curr = updateDecoder.curr;
  if (curr != null) {
    var currClient = curr.id.client;
    var currClock = curr.id.clock;
    from[currClient] = currClock;
    for (; curr != null; curr = updateDecoder.next()) {
      if (currClient != curr.id.client) {
        to[currClient] = currClock;
        from[curr.id.client] = curr.id.clock;
        currClient = curr.id.client;
      }
      currClock = curr.id.clock + curr.length;
    }
    to[currClient] = currClock;
  }
  return {'from': from, 'to': to};
}

Map parseUpdateMeta(Uint8List update) {
  return parseUpdateMetaV2(update, YDecoder: (e) => UpdateDecoderV1.create(e));
}

AbstractStruct sliceStruct(dynamic left, int diff) {
  if (left.runtimeType == GC) {
    final client = left.id.client;
    final clock = left.id.clock;
    return GC(createID(client, clock + diff), left.length - diff);
  } else if (left.runtimeType == Skip) {
    final client = left.id.client;
    final clock = left.id.clock;
    return Skip(createID(client, clock + diff), left.length - diff);
  } else {
    final leftItem = left as Item;
    final client = leftItem.id.client;
    final clock = leftItem.id.clock;
    return Item(
      createID(client, clock + diff),
      null,
      createID(client, clock + diff - 1),
      null,
      leftItem.rightOrigin,
      leftItem.parent,
      leftItem.parentSub,
      leftItem.content.splice(diff),
    );
  }
}

/**
 *
 * This function works similarly to `readUpdateV2`.
 *
 * @param {List<Uint8List>} updates
 * @param {Type} [yDecoder]
 * @param {Type} [yEncoder]
 * @return {Uint8List}
 */
Uint8List mergeUpdatesV2(List<Uint8List> updates,
    [AbstractUpdateDecoder Function(decoding.Decoder decoder)? yDecoder,
    AbstractUpdateEncoder Function()? yEncoder]) {
  if (updates.length == 1) {
    return updates[0];
  }
  yDecoder ??= (e) => UpdateDecoderV2(e);
  yEncoder ??= () => UpdateEncoderV2();
  List<AbstractUpdateDecoder> updateDecoders =
      updates.map((e) => yDecoder!.call(decoding.Decoder(e))).toList();

  List<LazyStructReader> lazyStructDecoders =
      updateDecoders.map((decoder) => LazyStructReader(decoder, true)).toList();

  /**
   * @todo we don't need offset because we always slice before
   * @type {null | { struct: Item | GC | Skip, offset: number }}
   */
  var currWrite;
  var updateEncoder = yEncoder.call();
  // write structs lazily
  LazyStructWriter lazyStructEncoder = LazyStructWriter(updateEncoder);
  // Note: We need to ensure that all lazyStructDecoders are fully consumed
  // Note: Should merge document updates whenever possible - even from different updates
  // Note: Should handle that some operations cannot be applied yet ()
  while (true) {
    // Write higher clients first ⇒ sort by clientID & clock and remove decoders without content
    lazyStructDecoders =
        lazyStructDecoders.where((dec) => dec.curr != null).toList();
    lazyStructDecoders.sort(
        /** @type {function(any,any):number} */
        (dec1, dec2) {
      if (dec1.curr!.id.client == dec2.curr!.id.client) {
        int clockDiff = dec1.curr!.id.clock - dec2.curr!.id.clock;
        if (clockDiff == 0) {
          // @todo remove references to skip since the structDecoders must filter Skips.
          return dec1.curr.runtimeType == dec2.curr.runtimeType
              ? 0
              : dec1.curr.runtimeType == Skip
                  ? 1
                  : -1; // we are filtering skips anyway.
        } else {
          return clockDiff;
        }
      } else {
        return dec2.curr!.id.client - dec1.curr!.id.client;
      }
    });
    if (lazyStructDecoders.isEmpty) {
      break;
    }
    LazyStructReader currDecoder = lazyStructDecoders[0];
    // write from currDecoder until the next operation is from another client or if filler-struct
    // then we need to reorder the decoders and find the next operation to write
    int firstClient = currDecoder.curr!.id.client;

    if (currWrite != null) {
      var curr = currDecoder.curr;
      bool iterated = false;

      // iterate until we find something that we haven't written already
      // remember: first the high client-ids are written
      while (curr != null &&
          curr.id.clock + curr.length <=
              currWrite['struct'].id.clock +  currWrite['struct'].length &&
          curr.id.client >=  currWrite['struct'].id.client) {
        curr = currDecoder.next();
        iterated = true;
      }
      if (curr == null || // current decoder is empty
              curr.id.client !=
                  firstClient || // check whether there is another decoder that has has updates from `firstClient`
              (iterated &&
                  curr.id.clock >
                       currWrite['struct'].id.clock +
                           currWrite['struct']
                              .length) // the above while loop was used and we are potentially missing updates
          ) {
        continue;
      }

      if (firstClient !=  currWrite['struct'].id.client) {
        writeStructToLazyStructWriter(
            lazyStructEncoder,  currWrite['struct'],  currWrite['offset']);
        currWrite = {"struct": curr, "offset": 0};
        currDecoder.next();
      } else {
        if ( currWrite['struct'].id.clock +  currWrite['struct'].length <
            curr.id.clock) {
          // @todo write currStruct & set currStruct = Skip(clock = currStruct.id.clock + currStruct.length, length = curr.id.clock - self.clock)
          if ( currWrite['struct'].runtimeType == Skip) {
            // extend existing skip
             currWrite['struct'].length =
                curr.id.clock + curr.length -  currWrite['struct'].id.clock;
          } else {
            writeStructToLazyStructWriter(
                lazyStructEncoder,  currWrite['struct'],  currWrite['offset']);
            int diff = curr.id.clock -
                currWrite['struct'].id.clock -
                currWrite['struct'].length as int;
            /**
             * @type {Skip}
             */
            Skip struct = Skip(
                createID(firstClient,
                     currWrite['struct'].id.clock +  currWrite['struct'].length),
                diff);
            currWrite = {'struct': struct, 'offset': 0};
          }
        } else {
          // if ( currWrite['struct'].id.clock +  currWrite['struct'].length >= curr.id.clock) {
          int diff =  currWrite['struct'].id.clock +
               currWrite['struct'].length -
              curr.id.clock;
          if (diff > 0) {
            if ( currWrite['struct'].runtimeType == Skip) {
              // prefer to slice Skip because the other struct might contain more information
               currWrite['struct'].length -= diff;
            } else {
              curr = sliceStruct(curr, diff);
            }
          }
          if (! currWrite['struct'].mergeWith(curr)) {
            writeStructToLazyStructWriter(
                lazyStructEncoder,  currWrite['struct'],  currWrite['offset']);
            currWrite = {'struct': curr, 'offset': 0};
            currDecoder.next();
          }
        }
      }
    } else {
      currWrite = {'struct': currDecoder.curr, 'offset': 0};
      currDecoder.next();
    }
    for (var next = currDecoder.curr;
        next != null &&
            next.id.client == firstClient &&
            next.id.clock ==
                currWrite['struct'].id.clock + currWrite['struct'].length &&
            next.runtimeType != Skip;
        next = currDecoder.next()) {
      writeStructToLazyStructWriter(
          lazyStructEncoder, currWrite['struct'], currWrite['offset']);
      currWrite = {'struct': next, 'offset': 0};
    }
  }
  if (currWrite != null) {
    writeStructToLazyStructWriter(
        lazyStructEncoder, currWrite['struct'], currWrite['offset']);
    currWrite = null;
  }
  finishLazyStructWriting(lazyStructEncoder);

  final dss = updateDecoders.map((decoder) => readDeleteSet(decoder)).toList();
  final ds = mergeDeleteSets(dss);
  writeDeleteSet(updateEncoder, ds);
  return updateEncoder.toUint8Array();
}

Uint8List diffUpdateV2(Uint8List update, Uint8List sv,
    [AbstractUpdateDecoder Function(decoding.Decoder decoder)? YDecoder,
    AbstractUpdateEncoder Function()? YEncoder]) {
  YEncoder ??= () => UpdateEncoderV2();
  YDecoder ??= (e) => UpdateDecoderV2.create(e);
  final state = decodeStateVector(sv);
  final encoder = YEncoder();
  final lazyStructWriter = LazyStructWriter(encoder);
  final decoder = YDecoder(decoding.createDecoder(update));
  final reader = LazyStructReader(decoder, false);
  while (reader.curr != null) {
    final curr = reader.curr;
    final currClient = curr!.id.client;
    final svClock = state[currClient] ?? 0;
    if (reader.curr.runtimeType == Skip) {
      reader.next();
      continue;
    }
    if (curr.id.clock + curr.length > svClock) {
      writeStructToLazyStructWriter(
          lazyStructWriter, curr, max(svClock - curr.id.clock, 0));
      reader.next();
      while (reader.curr != null && reader.curr!.id.client == currClient) {
        writeStructToLazyStructWriter(lazyStructWriter, reader.curr, 0);
        reader.next();
      }
    } else {
      while (reader.curr != null &&
          reader.curr!.id.client == currClient &&
          reader.curr!.id.clock + reader.curr!.length <= svClock) {
        reader.next();
      }
    }
  }
  finishLazyStructWriting(lazyStructWriter);
  final ds = readDeleteSet(decoder);
  writeDeleteSet(encoder, ds);
  return encoder.toUint8Array();
}

void diffUpdate(Uint8List update, Uint8List sv) => diffUpdateV2(update, sv,
    (e) => UpdateDecoderV1.create(e), () => UpdateEncoderV1.create());

/**
 * @param lazyWriter {LazyStructWriter}
 */
void flushLazyStructWriter(LazyStructWriter lazyWriter) {
  if (lazyWriter.written > 0) {
    lazyWriter.clientStructs.add({
      'written': lazyWriter.written,
      'restEncoder': encoding.toUint8Array(lazyWriter.encoder.restEncoder)
    });
    lazyWriter.encoder.restEncoder = encoding.createEncoder();
    lazyWriter.written = 0;
  }
}

/**
 * @param lazyWriter {LazyStructWriter}
 * @param struct {Item | GC}
 * @param offset {int}
 */
void writeStructToLazyStructWriter(
    LazyStructWriter lazyWriter, dynamic struct, int offset) {
  // flush curr if we start another client
  if (lazyWriter.written > 0 && lazyWriter.currClient != struct.id.client) {
    flushLazyStructWriter(lazyWriter);
  }
  if (lazyWriter.written == 0) {
    lazyWriter.currClient = struct.id.client;
    // write next client
    lazyWriter.encoder.writeClient(struct.id.client);
    // write startClock
    encoding.writeVarUint(
        lazyWriter.encoder.restEncoder, struct.id.clock + offset);
  }
  struct.write(lazyWriter.encoder, offset);
  lazyWriter.written++;
}

/**
 * Call this function when we collected all parts and want to
 * put all the parts together. After calling this method,
 * you can continue using the UpdateEncoder.
 *
 * @param lazyWriter {LazyStructWriter}
 */
void finishLazyStructWriting(LazyStructWriter lazyWriter) {
  flushLazyStructWriter(lazyWriter);

  // this is a fresh encoder because we called flushCurr
  final restEncoder = lazyWriter.encoder.restEncoder;

  /**
   * Now we put all the fragments together.
   * This works similarly to `writeClientsStructs`
   */

  // write # states that were updated - i.e. the clients
  encoding.writeVarUint(restEncoder, lazyWriter.clientStructs.length);

  for (var i = 0; i < lazyWriter.clientStructs.length; i++) {
    final partStructs = lazyWriter.clientStructs[i];
    /**
     * Works similarly to `writeStructs`
     */
    // write # encoded structs
    encoding.writeVarUint(restEncoder, partStructs['written']);
    // write the rest of the fragment
    encoding.writeUint8Array(restEncoder, partStructs['restEncoder']);
  }
}

/**
 * @param update {Uint8List}
 * @param blockTransformer {Function(dynamic): dynamic}
 * @param YDecoder {Type}
 * @param YEncoder {Type}
 */
Uint8List convertUpdateFormat(
    Uint8List update,
    Function(dynamic) blockTransformer,
    AbstractUpdateDecoder Function(decoding.Decoder decoder) YDecoder,
    AbstractUpdateEncoder Function() YEncoder) {
  final updateDecoder = YDecoder(decoding.createDecoder(update));
  final lazyDecoder = LazyStructReader(updateDecoder, false);
  final updateEncoder = YEncoder();
  final lazyWriter = LazyStructWriter(updateEncoder);
  for (var curr = lazyDecoder.curr; curr != null; curr = lazyDecoder.next()) {
    writeStructToLazyStructWriter(lazyWriter, blockTransformer(curr), 0);
  }
  finishLazyStructWriting(lazyWriter);
  final ds = readDeleteSet(updateDecoder);
  writeDeleteSet(updateEncoder, ds);
  return updateEncoder.toUint8Array();
}
