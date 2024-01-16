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

void writeClientsStructs(
    AbstractUpdateEncoder encoder, StructStore store, Map<int, int> _sm) {
  final sm = <int, int>{};
  _sm.forEach((client, clock) {
    if (getState(store, client) > clock) {
      sm.set(client, clock);
    }
  });
  getStateVector(store).forEach((client, clock) {
    if (!_sm.containsKey(client)) {
      sm.set(client, 0);
    }
  });
  encoding.writeVarUint(encoder.restEncoder, sm.length);
  final entries = sm.entries.toList();
  entries.sort((a, b) => b.key - a.key);
  entries.forEach((entry) {
    _writeStructs(
        encoder, store.clients.get(entry.key)!, entry.key, entry.value);
  });
}

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
        restStructs.clients[client] = [item];
      }
      clientsStructRefsIds.removeWhere((c) => c == client);
    }
    stack.length = 0;
  }

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
          final structRefs = clientsStructRefs[missing] ?? {'refs': [], 'i': 0};
          if (structRefs['refs'].length == structRefs['i']) {
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

void writeStructsFromTransaction(encoder, transaction) {
  writeClientsStructs(encoder, transaction.doc.store, transaction.beforeState);
}

void readUpdateV2(
  decoding.Decoder decoder,
  Doc ydoc,
  transactionOrigin,
  AbstractUpdateDecoder structDecoder,
) {
  globalTransact(ydoc, (transaction) {
    transaction.local = false;
    var retry = false;
    var doc = transaction.doc;
    var store = doc.store;
    var ss = readClientsStructRefs(
      structDecoder,
      doc,
    );
    var restStructs = integrateStructs(transaction, store, ss);
    var pending = store.pendingStructs;
    if (pending != null) {
      for (var entry in pending['missing'].entries) {
        var client = entry.key;
        var clock = entry.value;
        if (clock < getState(store, client)) {
          retry = true;
          break;
        }
      }
      if (restStructs != null) {
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
    var dsRest = readAndApplyDeleteSet(
      structDecoder,
      transaction,
      store,
    );
    if (store.pendingDs != null) {
      var pendingDSUpdate =
          UpdateDecoderV2(decoding.createDecoder(store.pendingDs!));
      decoding.readVarUint(pendingDSUpdate.restDecoder);
      var dsRest2 = readAndApplyDeleteSet(
        pendingDSUpdate,
        transaction,
        store,
      );
      if (dsRest != null && dsRest2 != null) {
        store.pendingDs = mergeUpdatesV2([dsRest, dsRest2]);
      } else {
        store.pendingDs = dsRest ?? dsRest2;
      }
    } else {
      store.pendingDs = dsRest;
    }
    if (retry) {
      var update = store.pendingStructs!['update']!;
      store.pendingStructs = null;
      applyUpdateV2(transaction.doc, update, null);
    }
  }, transactionOrigin, false);
}

void readUpdate(
        decoding.Decoder decoder, Doc ydoc, dynamic transactionOrigin) =>
    readUpdateV2(
        decoder, ydoc, transactionOrigin, DefaultUpdateDecoder(decoder));

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

void applyUpdate(Doc ydoc, Uint8List update, dynamic transactionOrigin) =>
    applyUpdateV2(ydoc, update, transactionOrigin, DefaultUpdateDecoder);

void writeStateAsUpdate(AbstractUpdateEncoder encoder, Doc doc,
    [Map<int, int> targetStateVector = const <int, int>{}]) {
  writeClientsStructs(encoder, doc.store, targetStateVector);
  writeDeleteSet(encoder, createDeleteSetFromStructStore(doc.store));
}

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

Uint8List encodeStateAsUpdate(Doc doc, Uint8List? encodedTargetStateVector) =>
    encodeStateAsUpdateV2(
        doc, encodedTargetStateVector, DefaultUpdateEncoder());

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

Map<int, int> decodeStateVectorV2(Uint8List decodedState) =>
    readStateVector(DSDecoderV2(decoding.createDecoder(decodedState)));

Map<int, int> decodeStateVector(Uint8List decodedState) =>
    readStateVector(DefaultDSDecoder(decoding.createDecoder(decodedState)));

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

void writeDocumentStateVector(AbstractDSEncoder encoder, Doc doc) =>
    writeStateVector(encoder, getStateVector(doc.store));

Uint8List encodeStateVectorV2(Doc doc, [AbstractDSEncoder? encoder]) {
  final _encoder = encoder ?? DSEncoderV2();
  writeDocumentStateVector(_encoder, doc);
  return _encoder.toUint8Array();
}

Uint8List encodeStateVector(Doc doc) =>
    encodeStateVectorV2(doc, DefaultDSEncoder());
