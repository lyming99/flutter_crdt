import 'dart:typed_data';

import 'package:flutter_crdt/lib0/decoding.dart' as decoding;
import 'package:flutter_crdt/lib0/encoding.dart' as encoding;
// import * as array from "lib0/array.js";
// import * as math from "lib0/math.js";
// import * as map from "lib0/map.js";
// import * as encoding from "lib0/encoding.js";
// import * as decoding from "lib0/decoding.js";

import 'package:flutter_crdt/structs/abstract_struct.dart';
import 'package:flutter_crdt/structs/item.dart';
import 'package:flutter_crdt/utils/id.dart';
import 'package:flutter_crdt/utils/struct_store.dart';
import 'package:flutter_crdt/utils/transaction.dart';
import 'package:flutter_crdt/utils/update_decoder.dart';
import 'package:flutter_crdt/utils/update_encoder.dart';
import 'package:flutter_crdt/y_crdt_base.dart';

class DeleteItem {
  DeleteItem(this.clock, this.len);
  final int clock;
  int len;
}
class DeleteSet {
  DeleteSet();
  final clients = <int, List<DeleteItem>>{};
}

void iterateDeletedStructs(Transaction transaction, DeleteSet ds,
        void Function(AbstractStruct) f) =>
    ds.clients.forEach((clientid, deletes) {
      final structs = transaction.doc.store.clients
          .get(clientid);
      for (var i = 0; i < deletes.length; i++) {
        final del = deletes[i];
        iterateStructs(transaction, structs!, del.clock, del.len, f);
      }
    });

int? findIndexDS(List<DeleteItem> dis, int clock) {
  var left = 0;
  var right = dis.length - 1;
  while (left <= right) {
    final midindex = ((left + right) / 2).floor();
    final mid = dis[midindex];
    final midclock = mid.clock;
    if (midclock <= clock) {
      if (clock < midclock + mid.len) {
        return midindex;
      }
      left = midindex + 1;
    } else {
      right = midindex - 1;
    }
  }
  return null;
}

bool isDeleted(DeleteSet ds, ID id) {
  final dis = ds.clients.get(id.client);
  return dis != null && findIndexDS(dis, id.clock) != null;
}

void sortAndMergeDeleteSet(DeleteSet ds) {
  ds.clients.forEach((_, dels) {
    dels.sort((a, b) => a.clock - b.clock);
    var i = 1, j = 1;
    for (; i < dels.length; i++) {
      final left = dels[j - 1];
      final right = dels[i];
      if (left.clock + left.len == right.clock) {
        left.len += right.len;
      } else {
        if (j < i) {
          dels[j] = right;
        }
        j++;
      }
    }
    dels.length = j;
  });
}
DeleteSet mergeDeleteSets(List<DeleteSet> dss) {
  final merged = DeleteSet();
  for (var dssI = 0; dssI < dss.length; dssI++) {
    dss[dssI].clients.forEach((client, delsLeft) {
      if (!merged.clients.containsKey(client)) {
        final dels = [...delsLeft];
        for (var i = dssI + 1; i < dss.length; i++) {
          dels.addAll(dss[i].clients.get(client) ?? []);
        }
        merged.clients.set(client, dels);
      }
    });
  }
  sortAndMergeDeleteSet(merged);
  return merged;
}

void addToDeleteSet(DeleteSet ds, int client, int clock, int length) {
  ds.clients.putIfAbsent(client, () => []).add(
        DeleteItem(clock, length),
      );
}

DeleteSet createDeleteSet() => DeleteSet();

DeleteSet createDeleteSetFromStructStore(StructStore ss) {
  final ds = createDeleteSet();
  ss.clients.forEach((client, structs) {
    final dsitems = <DeleteItem>[];
    for (var i = 0; i < structs.length; i++) {
      final struct = structs[i];
      if (struct.deleted) {
        final clock = struct.id.clock;
        var len = struct.length;
        for (; i + 1 < structs.length; i++) {
          final next = structs[i + 1];
          if (next.id.clock == clock + len && next.deleted) {
            len += next.length;
          } else {
            break;
          }
        }
        dsitems.add(DeleteItem(clock, len));
      }
    }
    if (dsitems.length > 0) {
      ds.clients.set(client, dsitems);
    }
  });
  return ds;
}

void writeDeleteSet(AbstractDSEncoder encoder, DeleteSet ds) {
  encoding.writeVarUint(encoder.restEncoder, ds.clients.length);
  List<MapEntry<int, List<DeleteItem>>> entries = ds.clients.entries.toList();
  entries.sort((a, b) => b.key - a.key);
  entries.forEach((entry) {
    encoder.resetDsCurVal();
    encoding.writeVarUint(encoder.restEncoder, entry.key);
    int len = entry.value.length;
    encoding.writeVarUint(encoder.restEncoder, len);
    for (int i = 0; i < len; i++) {
      DeleteItem item = entry.value[i];
      encoder.writeDsClock(item.clock);
      encoder.writeDsLen(item.len);
    }
  });
}
DeleteSet readDeleteSet(AbstractDSDecoder decoder) {
  final ds = DeleteSet();
  final numClients = decoding.readVarUint(decoder.restDecoder);
  for (var i = 0; i < numClients; i++) {
    decoder.resetDsCurVal();
    final client = decoding.readVarUint(decoder.restDecoder);
    final numberOfDeletes = decoding.readVarUint(decoder.restDecoder);
    if (numberOfDeletes > 0) {
      final dsField = ds.clients.putIfAbsent(client, () => []);
      for (var i = 0; i < numberOfDeletes; i++) {
        dsField.add(DeleteItem(decoder.readDsClock(), decoder.readDsLen()));
      }
    }
  }
  return ds;
}

Uint8List? readAndApplyDeleteSet(
    AbstractDSDecoder decoder, Transaction transaction, StructStore store) {
  final unappliedDS = DeleteSet();
  final numClients = decoding.readVarUint(decoder.restDecoder);
  for (var i = 0; i < numClients; i++) {
    decoder.resetDsCurVal();
    final client = decoding.readVarUint(decoder.restDecoder);
    final numberOfDeletes = decoding.readVarUint(decoder.restDecoder);
    final structs = store.clients.get(client) ?? [];
    final state = getState(store, client);
    for (var i = 0; i < numberOfDeletes; i++) {
      final clock = decoder.readDsClock();
      final clockEnd = clock + decoder.readDsLen();
      if (clock < state) {
        if (state < clockEnd) {
          addToDeleteSet(unappliedDS, client, state, clockEnd - state);
        }
        var index = findIndexSS(structs, clock);
        var struct = structs[index];
        if (!struct.deleted && struct.id.clock < clock) {
          structs.insert(
            index + 1,
            splitItem(transaction, struct as Item, clock - struct.id.clock),
          );
          index++;
        }
        while (index < structs.length) {
          // @ts-ignore
          struct = structs[index++];
          if (struct.id.clock < clockEnd) {
            if (!struct.deleted && struct is Item) {
              if (clockEnd < struct.id.clock + struct.length) {
                structs.insert(
                  index,
                  splitItem(transaction, struct, clockEnd - struct.id.clock),
                );
              }
              struct.delete(transaction);
            }
          } else {
            break;
          }
        }
      } else {
        addToDeleteSet(unappliedDS, client, clock, clockEnd - clock);
      }
    }
  }
  if (unappliedDS.clients.length > 0) {
    final ds = UpdateEncoderV2();
    encoding.writeVarUint(ds.restEncoder, 0);
    writeDeleteSet(ds, unappliedDS);
    return ds.toUint8Array();
  }
  return null;
}
