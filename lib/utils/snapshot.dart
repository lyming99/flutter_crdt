import 'dart:typed_data';

import 'package:flutter_crdt/lib0/decoding.dart' as decoding;
import 'package:flutter_crdt/lib0/encoding.dart' as encoding;
import 'package:flutter_crdt/structs/item.dart';
import 'package:flutter_crdt/utils/delete_set.dart';
import 'package:flutter_crdt/utils/doc.dart';
import 'package:flutter_crdt/utils/encoding.dart';
import 'package:flutter_crdt/utils/id.dart';
import 'package:flutter_crdt/utils/struct_store.dart';
import 'package:flutter_crdt/utils/transaction.dart';
import 'package:flutter_crdt/utils/update_decoder.dart';
import 'package:flutter_crdt/utils/update_encoder.dart';
import 'package:flutter_crdt/y_crdt_base.dart';

class Snapshot {
  Snapshot(this.ds, this.sv);
  final DeleteSet ds;
  final Map<int, int> sv;
}

bool equalSnapshots(Snapshot snap1, Snapshot snap2) {
  final ds1 = snap1.ds.clients;
  final ds2 = snap2.ds.clients;
  final sv1 = snap1.sv;
  final sv2 = snap2.sv;
  if (sv1.length != sv2.length || ds1.length != ds2.length) {
    return false;
  }
  for (final entry in sv1.entries) {
    if (sv2.get(entry.key) != entry.value) {
      return false;
    }
  }
  for (final entry in ds1.entries) {
    final dsitems2 = ds2.get(entry.key) ?? [];
    final dsitems1 = entry.value;
    if (dsitems1.length != dsitems2.length) {
      return false;
    }
    for (var i = 0; i < dsitems1.length; i++) {
      final dsitem1 = dsitems1[i];
      final dsitem2 = dsitems2[i];
      if (dsitem1.clock != dsitem2.clock || dsitem1.len != dsitem2.len) {
        return false;
      }
    }
  }
  return true;
}

Uint8List encodeSnapshotV2(Snapshot snapshot, AbstractDSEncoder? encoder) {
  final _encoder = encoder ?? DSEncoderV2();
  writeDeleteSet(_encoder, snapshot.ds);
  writeStateVector(_encoder, snapshot.sv);
  return _encoder.toUint8Array();
}

Uint8List encodeSnapshot(Snapshot snapshot) =>
    encodeSnapshotV2(snapshot, DSEncoderV1());

Snapshot decodeSnapshotV2(Uint8List buf, [AbstractDSDecoder? decoder]) {
  final _decoder = decoder ?? DSDecoderV2(decoding.createDecoder(buf));
  return Snapshot(readDeleteSet(_decoder), readStateVector(_decoder));
}

Snapshot decodeSnapshot(Uint8List buf) =>
    decodeSnapshotV2(buf, DSDecoderV1(decoding.createDecoder(buf)));

Snapshot createSnapshot(DeleteSet ds, Map<int, int> sm) => Snapshot(ds, sm);

final emptySnapshot = createSnapshot(createDeleteSet(), {});

Snapshot snapshot(Doc doc) => createSnapshot(
    createDeleteSetFromStructStore(doc.store), getStateVector(doc.store));

bool isVisible(Item item, Snapshot? snapshot) => snapshot == null
    ? !item.deleted
    : snapshot.sv.containsKey(item.id.client) &&
        (snapshot.sv.get(item.id.client) ?? 0) > item.id.clock &&
        !isDeleted(snapshot.ds, item.id);

void splitSnapshotAffectedStructs(Transaction transaction, Snapshot snapshot) {
  final meta = transaction.meta
      .putIfAbsent(splitSnapshotAffectedStructs, () => <dynamic>{}) as Set;
  final store = transaction.doc.store;
  if (!meta.contains(snapshot)) {
    snapshot.sv.forEach((client, clock) {
      if (clock < getState(store, client)) {
        getItemCleanStart(transaction, createID(client, clock));
      }
    });
    iterateDeletedStructs(transaction, snapshot.ds, (item) {});
    meta.add(snapshot);
  }
}

Doc createDocFromSnapshot(Doc originDoc, Snapshot snapshot, [Doc? newDoc]) {
  if (originDoc.gc) {
    throw Exception("originDoc must not be garbage collected");
  }
  final ds = snapshot.ds;
  final sv = snapshot.sv;

  final encoder = UpdateEncoderV2();
  originDoc.transact((transaction) {
    var size = 0;
    sv.forEach((_, clock) {
      if (clock > 0) {
        size++;
      }
    });
    encoding.writeVarUint(encoder.restEncoder, size);
    for (final v in sv.entries) {
      final client = v.key;
      final clock = v.value;

      if (clock == 0) {
        continue;
      }
      if (clock < getState(originDoc.store, client)) {
        getItemCleanStart(transaction, createID(client, clock));
      }
      final structs = originDoc.store.clients.get(client) ?? [];
      final lastStructIndex = findIndexSS(structs, clock - 1);
      // write # encoded structs
      encoding.writeVarUint(encoder.restEncoder, lastStructIndex + 1);
      encoder.writeClient(client);
      // first clock written is 0
      encoding.writeVarUint(encoder.restEncoder, 0);
      for (var i = 0; i <= lastStructIndex; i++) {
        structs[i].write(encoder, 0);
      }
    }
    writeDeleteSet(encoder, ds);
  });
  final _newDoc = newDoc ?? Doc();
  applyUpdateV2(_newDoc, encoder.toUint8Array(), "snapshot");
  return _newDoc;
}
