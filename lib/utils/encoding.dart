import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_crdt/lib0/binary.dart' as binary;

/**
 * @module encoding
 */
import "package:flutter_crdt/lib0/decoding.dart" as decoding;
import "package:flutter_crdt/lib0/encoding.dart" as encoding;
import 'package:flutter_crdt/structs/abstract_struct.dart';
import 'package:flutter_crdt/structs/gc.dart';
import 'package:flutter_crdt/structs/item.dart';
import 'package:flutter_crdt/utils/delete_set.dart';
import 'package:flutter_crdt/utils/doc.dart';
import 'package:flutter_crdt/utils/id.dart';
import 'package:flutter_crdt/utils/struct_store.dart';
import 'package:flutter_crdt/utils/transaction.dart';
import 'package:flutter_crdt/utils/update_decoder.dart';
import 'package:flutter_crdt/utils/update_encoder.dart';
import 'package:flutter_crdt/y_crdt_base.dart';

import '../structs/skip.dart';
import 'updates.dart';

AbstractDSEncoder Function() DefaultDSEncoder = DSEncoderV1.create;
AbstractDSDecoder Function(decoding.Decoder) DefaultDSDecoder =
    DSDecoderV1.create;
AbstractUpdateEncoder Function() DefaultUpdateEncoder = UpdateEncoderV1.create;
AbstractUpdateDecoder Function(decoding.Decoder) DefaultUpdateDecoder =
    UpdateDecoderV1.create;

void useV1Encoding() {
  DefaultDSEncoder = DSEncoderV1.create;
  DefaultDSDecoder = DSDecoderV1.create;
  DefaultUpdateEncoder = UpdateEncoderV1.create;
  DefaultUpdateDecoder = UpdateDecoderV1.create;
}

void useV2Encoding() {
  DefaultDSEncoder = DSEncoderV2.create;
  DefaultDSDecoder = DSDecoderV2.create;
  DefaultUpdateEncoder = UpdateEncoderV2.create;
  DefaultUpdateDecoder = UpdateDecoderV2.create;
}

/**
 * @param {AbstractUpdateEncoder} encoder
 * @param {List<GC|Item>} structs All structs by `client`
 * @param {number} client
 * @param {number} clock write structs starting with `ID(client,clock)`
 *
 * @function
 */
void _writeStructs(AbstractUpdateEncoder encoder, List<AbstractStruct> structs,
    int client, int clock) {
  // write first id
  clock = max(clock, structs[0].id.clock);
  final startNewStructs = findIndexSS(structs, clock);
  // write # encoded structs
  encoding.writeVarUint(encoder.restEncoder, structs.length - startNewStructs);
  encoder.writeClient(client);
  encoding.writeVarUint(encoder.restEncoder, clock);
  final firstStruct = structs[startNewStructs];
  // write first struct with an offset
  firstStruct.write(encoder, clock - firstStruct.id.clock);
  for (var i = startNewStructs + 1; i < structs.length; i++) {
    structs[i].write(encoder, 0);
  }
}

/**
 * @param {AbstractUpdateEncoder} encoder
 * @param {StructStore} store
 * @param {Map<number,number>} _sm
 *
 * @private
 * @function
 */
void writeClientsStructs(
    AbstractUpdateEncoder encoder, StructStore store, Map<int, int> _sm) {
  // we filter all valid _sm entries into sm
  final sm = <int, int>{};
  _sm.forEach((client, clock) {
    // only write if new structs are available
    if (getState(store, client) > clock) {
      sm.set(client, clock);
    }
  });
  getStateVector(store).forEach((client, clock) {
    if (!_sm.containsKey(client)) {
      sm.set(client, 0);
    }
  });
  // write # states that were updated
  encoding.writeVarUint(encoder.restEncoder, sm.length);
  // Write items with higher client ids first
  // This heavily improves the conflict algorithm.
  final entries = sm.entries.toList();
  entries.sort((a, b) => b.key - a.key);
  entries.forEach((entry) {
    // @ts-ignore
    _writeStructs(
        encoder, store.clients.get(entry.key)!, entry.key, entry.value);
  });
}

/**
 * @param {UpdateDecoderV1 | UpdateDecoderV2} decoder The decoder object to read data from.
 * @param {Doc} doc
 * @return {Map<number, { i: number, refs: Array<Item | GC> }>}
 *
 * @private
 * @function
 */
Map<int, Map<String, dynamic>> readClientsStructRefs(
    AbstractUpdateDecoder decoder, Doc doc) {
  Map<int, Map<String, dynamic>> clientRefs = Map();
  int numOfStateUpdates = decoding.readVarUint(decoder.restDecoder);
  for (int i = 0; i < numOfStateUpdates; i++) {
    int numberOfStructs = decoding.readVarUint(decoder.restDecoder);
    List<AbstractStruct> refs = List.filled(numberOfStructs, Skip(createID(0, 0),0));
    int client = decoder.readClient();
    int clock = decoding.readVarUint(decoder.restDecoder);
    clientRefs[client] = {'i': 0, 'refs': refs};
    for (int i = 0; i < numberOfStructs; i++) {
      int info = decoder.readInfo();
      switch (binary.BITS5 & info) {
        case 0:
          {
            int len = decoder.readLen();
            refs[i] = GC(createID(client, clock), len);
            clock += len;
            break;
          }
        case 10:
          {
            int len = decoding.readVarUint(decoder.restDecoder);
            refs[i] = Skip(createID(client, clock), len);
            clock += len;
            break;
          }
        default:
          {
            bool cantCopyParentInfo = (info & (binary.BIT7 | binary.BIT8)) == 0;
            Item struct = Item(
              createID(client, clock),
              null,
              (info & binary.BIT8) == binary.BIT8 ? decoder.readLeftID() : null,
              null,
              (info & binary.BIT7) == binary.BIT7
                  ? decoder.readRightID()
                  : null,
              cantCopyParentInfo
                  ? (decoder.readParentInfo()
                      ? doc.get(decoder.readString())
                      : decoder.readLeftID())
                  : null,
              cantCopyParentInfo && (info & binary.BIT6) == binary.BIT6
                  ? decoder.readString()
                  : null,
              readItemContent(decoder, info),
            );
            refs[i] = struct;
            clock += struct.length;
          }
      }
    }
  }
  return clientRefs;
}

/**
 * Resume computing structs generated by struct readers.
 *
 * While there is something to do, we integrate structs in this order
 * 1. top element on stack, if stack is not empty
 * 2. next element from current struct reader (if empty, use next struct reader)
 *
 * If struct causally depends on another struct (ref.missing), we put next reader of
 * `ref.id.client` on top of stack.
 *
 * At some point we find a struct that has no causal dependencies,
 * then we start emptying the stack.
 *
 * It is not possible to have circles: i.e. struct1 (from client1) depends on struct2 (from client2)
 * depends on struct3 (from client1). Therefore the max stack size is eqaul to `structReaders.length`.
 *
 * This method is implemented in a way so that we can resume computation if this update
 * causally depends on another update.
 *
 * @param transaction {Transaction}
 * @param store {StructStore}
 * @param clientsStructRefs {Map<int, Map<String, dynamic>>}
 * @return {Map<String, dynamic> | Null}
 *
 * @private
 * @function
 */
Map<String, dynamic>? integrateStructs(Transaction transaction,
    StructStore store, Map<int, Map<String, dynamic>> clientsStructRefs) {
  List<dynamic> stack = [];
  // sort them so that we take the higher id first, in case of conflicts the lower id will probably not conflict with the id from the higher user.
  List<int> clientsStructRefsIds = clientsStructRefs.keys.toList()..sort();
  if (clientsStructRefsIds.length == 0) {
    return null;
  }
  Map<String, dynamic>? getNextStructTarget() {
    if (clientsStructRefsIds.length == 0) {
      return null;
    }
    Map<String, dynamic> nextStructsTarget = clientsStructRefs[
        clientsStructRefsIds[clientsStructRefsIds.length - 1]]!;
    while (nextStructsTarget['refs'].length == nextStructsTarget['i']) {
      clientsStructRefsIds.removeLast();
      if (clientsStructRefsIds.length > 0) {
        nextStructsTarget = clientsStructRefs[
            clientsStructRefsIds[clientsStructRefsIds.length - 1]]!;
      } else {
        return null;
      }
    }
    return nextStructsTarget;
  }

  Map<String, dynamic>? curStructsTarget = getNextStructTarget();
  if (curStructsTarget == null && stack.length == 0) {
    return null;
  }

  StructStore restStructs = new StructStore();
  Map<int, int> missingSV = new Map<int, int>();
  void updateMissingSv(int client, int clock) {
    int? mclock = missingSV[client];
    if (mclock == null || mclock > clock) {
      missingSV[client] = clock;
    }
  }

  var stackHead = (curStructsTarget!['refs'][curStructsTarget["i"]++]);
  Map<dynamic, dynamic> state = new Map<dynamic, dynamic>();
  void addStackToRestSS() {
    for (var item in stack) {
      var client = item.id.client;
      var unapplicableItems = clientsStructRefs[client];
      if (unapplicableItems != null) {
        // decrement because we weren't able to apply previous operation
        unapplicableItems['i']--;
        restStructs.clients[client] =
            unapplicableItems['refs'].sublist(unapplicableItems['i']);
        clientsStructRefs.remove(client);
        unapplicableItems['i'] = 0;
        unapplicableItems['refs'] = [];
      } else {
        // item was the last item on clientsStructRefs and the field was already cleared. Add item to restStructs and continue
        restStructs.clients[client] = [item];
      }
      // remove client from clientsStructRefsIds to prevent users from applying the same update again
      clientsStructRefsIds.removeWhere((c) => c == client);
    }
    stack.length = 0;
  }

  // iterate over all struct readers until we are done
  while (true) {
    if (stackHead.runtimeType != Skip) {
      final localClock = state.putIfAbsent(
          stackHead.id.client, () => getState(store, stackHead.id.client));
      final offset = localClock - stackHead.id.clock;
      if (offset < 0) {
        // update from the same client is missing
        stack.add(stackHead);
        updateMissingSv(stackHead.id.client, stackHead.id.clock - 1);
        // hid a dead wall, add all items from stack to restSS
        addStackToRestSS();
      } else {
        final missing = stackHead.getMissing(transaction, store);
        if (missing != null) {
          stack.add(stackHead);
          // get the struct reader that has the missing struct
          /**
           * @type {{ refs: Array<GC|Item>, i: number }}
           */
          final structRefs = clientsStructRefs[missing] ?? {'refs': [], 'i': 0};
          if (structRefs['refs'].length == structRefs['i']) {
            // This update message causally depends on another update message that doesn't exist yet
            updateMissingSv(missing, getState(store, missing));
            addStackToRestSS();
          } else {
            stackHead = structRefs['refs'][structRefs['i']++];
            continue;
          }
        } else if (offset == 0 || offset < stackHead.length) {
          // all fine, apply the stackhead
          stackHead.integrate(transaction, offset);
          state[stackHead.id.client] = stackHead.id.clock + stackHead.length;
        }
      }
    }

    // iterate to next stackHead
    if (stack.length > 0) {
      stackHead = stack.removeLast();
    } else if (curStructsTarget != null &&
        curStructsTarget['i'] < curStructsTarget['refs'].length) {
      stackHead = curStructsTarget['refs'][curStructsTarget['i']++];
    } else {
      curStructsTarget = getNextStructTarget();
      if (curStructsTarget == null) {
        // we are done!
        break;
      } else {
        stackHead = curStructsTarget['refs'][curStructsTarget['i']++];
      }
    }
  }
  if (restStructs.clients.length > 0) {
    final encoder = UpdateEncoderV2();
    writeClientsStructs(encoder, restStructs, Map());
    // write empty deleteset
    // writeDeleteSet(encoder, DeleteSet());
    encoding.writeVarUint(encoder.restEncoder,
        0); // => no need for an extra function call, just write 0 deletes
    return {'missing': missingSV, 'update': encoder.toUint8Array()};
  }
  return null;
}

/**
 * @param {UpdateEncoderV1 | UpdateEncoderV2} encoder
 * @param {Transaction} transaction
 *
 * @private
 * @function
 */
void writeStructsFromTransaction(encoder, transaction) {
  writeClientsStructs(encoder, transaction.doc.store, transaction.beforeState);
}

void readUpdateV2(
  decoding.Decoder decoder,
  Doc ydoc,
  transactionOrigin,
  AbstractUpdateDecoder structDecoder,
) {
  // We use the `transaction` method of `ydoc` to perform the transaction
  globalTransact(ydoc, (transaction) {
    // force that transaction.local is set to non-local
    transaction.local = false;
    var retry = false;
    var doc = transaction.doc;
    var store = doc.store;
    // let start = performance.now()
    var ss = readClientsStructRefs(
      structDecoder,
      doc,
    );
    // print('time to read structs: ${performance.now() - start}'); // @todo remove
    // start = performance.now()
    // print('time to merge: ${performance.now() - start}'); // @todo remove
    // start = performance.now()
    var restStructs = integrateStructs(transaction, store, ss);
    var pending = store.pendingStructs;
    if (pending != null) {
      // check if we can apply something
      for (var entry in pending['missing'].entries) {
        var client = entry.key;
        var clock = entry.value;
        if (clock < getState(store, client)) {
          retry = true;
          break;
        }
      }
      if (restStructs != null) {
        // merge restStructs into store.pending
        for (var entry in restStructs['missing'].entries) {
          var client = entry.key;
          var clock = entry.value;
          var mclock = pending['missing'][client];
          if (mclock == null || mclock > clock) {
            pending['missing'][client] = clock;
          }
        }
        pending['update'] =
            mergeUpdatesV2([pending['update'], restStructs['update']]);
      }
    } else {
      store.pendingStructs = restStructs;
    }
    // print('time to integrate: ${performance.now() - start}'); // @todo remove
    // start = performance.now()
    var dsRest = readAndApplyDeleteSet(
      structDecoder,
      transaction,
      store,
    );
    if (store.pendingDs != null) {
      // @todo we could make a lower-bound state-vector check as we do above
      var pendingDSUpdate =
          UpdateDecoderV2(decoding.createDecoder(store.pendingDs!));
      decoding.readVarUint(pendingDSUpdate.restDecoder);
      var dsRest2 = readAndApplyDeleteSet(
        pendingDSUpdate,
        transaction,
        store,
      );
      if (dsRest != null && dsRest2 != null) {
        // case 1: ds1 != null && ds2 != null
        store.pendingDs = mergeUpdatesV2([dsRest, dsRest2]);
      } else {
        // case 2: ds1 != null
        // case 3: ds2 != null
        // case 4: ds1 == null && ds2 == null
        store.pendingDs = dsRest ?? dsRest2;
      }
    } else {
      // Either dsRest == null && pendingDs == null OR dsRest != null
      store.pendingDs = dsRest;
    }
    // print('time to cleanup: ${performance.now() - start}'); // @todo remove
    // start = performance.now()

    // print('time to resume delete readers: ${performance.now() - start}'); // @todo remove
    // start = performance.now()
    if (retry) {
      var update = store.pendingStructs!['update']!;
      store.pendingStructs = null;
      applyUpdateV2(transaction.doc, update, null);
    }
  }, transactionOrigin, false);
}

/**
 * Read and apply a document update.
 *
 * This function has the same effect as `applyUpdate` but accepts an decoder.
 *
 * @param {decoding.Decoder} decoder
 * @param {Doc} ydoc
 * @param {any} [transactionOrigin] This will be stored on `transaction.origin` and `.on('update', (update, origin))`
 *
 * @function
 */
void readUpdate(
        decoding.Decoder decoder, Doc ydoc, dynamic transactionOrigin) =>
    readUpdateV2(
        decoder, ydoc, transactionOrigin, DefaultUpdateDecoder(decoder));

/**
 * Apply a document update created by, for example, `y.on('update', update => ..)` or `update = encodeStateAsUpdate()`.
 *
 * This function has the same effect as `readUpdate` but accepts an Uint8Array instead of a Decoder.
 *
 * @param {Doc} ydoc
 * @param {Uint8Array} update
 * @param {any} [transactionOrigin] This will be stored on `transaction.origin` and `.on('update', (update, origin))`
 * @param {typeof UpdateDecoderV1 | typeof UpdateDecoderV2} [YDecoder]
 *
 * @function
 */
void applyUpdateV2(
  Doc ydoc,
  Uint8List update,
  dynamic transactionOrigin, [
  AbstractUpdateDecoder Function(decoding.Decoder decoder)? YDecoder,
]) {
  final _YDecoder = YDecoder ?? UpdateDecoderV2.create;
  final decoder = decoding.createDecoder(update);
  readUpdateV2(decoder, ydoc, transactionOrigin, _YDecoder(decoder));
}

/**
 * Apply a document update created by, for example, `y.on('update', update => ..)` or `update = encodeStateAsUpdate()`.
 *
 * This function has the same effect as `readUpdate` but accepts an Uint8Array instead of a Decoder.
 *
 * @param {Doc} ydoc
 * @param {Uint8Array} update
 * @param {any} [transactionOrigin] This will be stored on `transaction.origin` and `.on('update', (update, origin))`
 *
 * @function
 */
void applyUpdate(Doc ydoc, Uint8List update, dynamic transactionOrigin) =>
    applyUpdateV2(ydoc, update, transactionOrigin, DefaultUpdateDecoder);

/**
 * Write all the document as a single update message. If you specify the state of the remote client (`targetStateVector`) it will
 * only write the operations that are missing.
 *
 * @param {AbstractUpdateEncoder} encoder
 * @param {Doc} doc
 * @param {Map<number,number>} [targetStateVector] The state of the target that receives the update. Leave empty to write all known structs
 *
 * @function
 */
void writeStateAsUpdate(AbstractUpdateEncoder encoder, Doc doc,
    [Map<int, int> targetStateVector = const <int, int>{}]) {
  writeClientsStructs(encoder, doc.store, targetStateVector);
  writeDeleteSet(encoder, createDeleteSetFromStructStore(doc.store));
}

/**
 * Write all the document as a single update message that can be applied on the remote document. If you specify the state of the remote client (`targetState`) it will
 * only write the operations that are missing.
 *
 * Use `writeStateAsUpdate` instead if you are working with lib0/encoding.js#Encoder
 *
 * @param {Doc} doc
 * @param {Uint8Array} [encodedTargetStateVector] The state of the target that receives the update. Leave empty to write all known structs
 * @param {AbstractUpdateEncoder} [encoder]
 * @return {Uint8Array}
 *
 * @function
 */
Uint8List encodeStateAsUpdateV2(
  Doc doc,
  Uint8List? encodedTargetStateVector, [
  AbstractUpdateEncoder? encoder,
]) {
  final _encoder = encoder ?? UpdateEncoderV2();
  final targetStateVector = encodedTargetStateVector == null
      ? const <int, int>{}
      : decodeStateVector(encodedTargetStateVector);
  writeStateAsUpdate(_encoder, doc, targetStateVector);
  return _encoder.toUint8Array();
}

/**
 * Write all the document as a single update message that can be applied on the remote document. If you specify the state of the remote client (`targetState`) it will
 * only write the operations that are missing.
 *
 * Use `writeStateAsUpdate` instead if you are working with lib0/encoding.js#Encoder
 *
 * @param {Doc} doc
 * @param {Uint8Array} [encodedTargetStateVector] The state of the target that receives the update. Leave empty to write all known structs
 * @return {Uint8Array}
 *
 * @function
 */
Uint8List encodeStateAsUpdate(Doc doc, Uint8List? encodedTargetStateVector) =>
    encodeStateAsUpdateV2(
        doc, encodedTargetStateVector, DefaultUpdateEncoder());

/**
 * Read state vector from Decoder and return as Map
 *
 * @param {AbstractDSDecoder} decoder
 * @return {Map<number,number>} Maps `client` to the number next expected `clock` from that client.
 *
 * @function
 */
Map<int, int> readStateVector(AbstractDSDecoder decoder) {
  final ss = <int, int>{};
  final ssLength = decoding.readVarUint(decoder.restDecoder);
  for (var i = 0; i < ssLength; i++) {
    final client = decoding.readVarUint(decoder.restDecoder);
    final clock = decoding.readVarUint(decoder.restDecoder);
    ss.set(client, clock);
  }
  return ss;
}

/**
 * Read decodedState and return State as Map.
 *
 * @param {Uint8Array} decodedState
 * @return {Map<number,number>} Maps `client` to the number next expected `clock` from that client.
 *
 * @function
 */
Map<int, int> decodeStateVectorV2(Uint8List decodedState) =>
    readStateVector(DSDecoderV2(decoding.createDecoder(decodedState)));

/**
 * Read decodedState and return State as Map.
 *
 * @param {Uint8Array} decodedState
 * @return {Map<number,number>} Maps `client` to the number next expected `clock` from that client.
 *
 * @function
 */
Map<int, int> decodeStateVector(Uint8List decodedState) =>
    readStateVector(DefaultDSDecoder(decoding.createDecoder(decodedState)));

/**
 * @param {AbstractDSEncoder} encoder
 * @param {Map<number,number>} sv
 * @function
 */
AbstractDSEncoder writeStateVector(
    AbstractDSEncoder encoder, Map<int, int> sv) {
  encoding.writeVarUint(encoder.restEncoder, sv.length);
  sv.forEach((client, clock) {
    encoding.writeVarUint(encoder.restEncoder,
        client); // @todo use a special client decoder that is based on mapping
    encoding.writeVarUint(encoder.restEncoder, clock);
  });
  return encoder;
}

/**
 * @param {AbstractDSEncoder} encoder
 * @param {Doc} doc
 *
 * @function
 */
void writeDocumentStateVector(AbstractDSEncoder encoder, Doc doc) =>
    writeStateVector(encoder, getStateVector(doc.store));

/**
 * Encode State as Uint8Array.
 *
 * @param {Doc} doc
 * @param {AbstractDSEncoder} [encoder]
 * @return {Uint8Array}
 *
 * @function
 */
Uint8List encodeStateVectorV2(Doc doc, [AbstractDSEncoder? encoder]) {
  final _encoder = encoder ?? DSEncoderV2();
  writeDocumentStateVector(_encoder, doc);
  return _encoder.toUint8Array();
}

/**
 * Encode State as Uint8Array.
 *
 * @param {Doc} doc
 * @return {Uint8Array}
 *
 * @function
 */
Uint8List encodeStateVector(Doc doc) =>
    encodeStateVectorV2(doc, DefaultDSEncoder());
