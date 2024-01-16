import 'dart:typed_data';

import 'package:flutter_crdt/structs/abstract_struct.dart';
import 'package:flutter_crdt/structs/gc.dart';
import 'package:flutter_crdt/structs/item.dart';
import 'package:flutter_crdt/utils/id.dart';
import 'package:flutter_crdt/utils/transaction.dart';
import 'package:flutter_crdt/y_crdt_base.dart';

class StructStore {
  final clients = <int, List<AbstractStruct>>{};

  Map? pendingStructs;

  Uint8List? pendingDs;
}

Map<int, int> getStateVector(StructStore store) {
  final sm = <int, int>{};
  store.clients.forEach((client, structs) {
    final struct = structs[structs.length - 1];
    sm.set(client, struct.id.clock + struct.length);
  });
  return sm;
}

int getState(StructStore store, int client) {
  final structs = store.clients.get(client);
  if (structs == null) {
    return 0;
  }
  final lastStruct = structs[structs.length - 1];
  return lastStruct.id.clock + lastStruct.length;
}

void integretyCheck(StructStore store) {
  store.clients.values.forEach((structs) {
    for (var i = 1; i < structs.length; i++) {
      final l = structs[i - 1];
      final r = structs[i];
      if (l.id.clock + l.length != r.id.clock) {
        throw Exception('StructStore failed integrety check');
      }
    }
  });
}

void addStruct(StructStore store, AbstractStruct struct) {
  var structs = store.clients.get(struct.id.client);
  if (structs == null) {
    structs = [];
    store.clients.set(struct.id.client, structs);
  } else {
    final lastStruct = structs[structs.length - 1];
    if (lastStruct.id.clock + lastStruct.length != struct.id.clock) {
      throw Exception('Unexpected case');
    }
  }
  structs.add(struct);
}

int findIndexSS(List<AbstractStruct> structs, int clock) {
  var left = 0;
  var right = structs.length - 1;
  var mid = structs[right];
  var midclock = mid.id.clock;
  if (midclock == clock) {
    return right;
  }
  var midindex = ((clock / (midclock + mid.length - 1)) * right)
      .floor(); // pivoting the search
  while (left <= right) {
    mid = structs[midindex];
    midclock = mid.id.clock;
    if (midclock <= clock) {
      if (clock < midclock + mid.length) {
        return midindex;
      }
      left = midindex + 1;
    } else {
      right = midindex - 1;
    }
    midindex = ((left + right) / 2).floor();
  }
  throw Exception('Unexpected case');
}

AbstractStruct find(StructStore store, ID id) {
  final structs = store.clients.get(id.client)!;
  return structs[findIndexSS(structs, id.clock)];
}

const getItem = find;

int findIndexCleanStart(
    Transaction transaction, List<AbstractStruct> structs, int clock) {
  final index = findIndexSS(structs, clock);
  final struct = structs[index];
  if (struct.id.clock < clock && struct is Item) {
    structs.insert(
        index + 1, splitItem(transaction, struct, clock - struct.id.clock));
    return index + 1;
  }
  return index;
}

Item getItemCleanStart(Transaction transaction, ID id) {
  final structs = (transaction.doc.store.clients.get(id.client))!;
  return structs[findIndexCleanStart(transaction, structs, id.clock)] as Item;
}

Item? getItemCleanEnd(Transaction transaction, StructStore store, ID id) {
  final structs = store.clients.get(id.client)!;
  final index = findIndexSS(structs, id.clock);
  if (structs[index] is GC) {
    return null;
  }
  final struct = structs[index] as Item;
  if (id.clock != struct.id.clock + struct.length - 1 && struct is! GC) {
    structs.insert(index + 1,
        splitItem(transaction, struct, id.clock - struct.id.clock + 1));
  }
  return struct;
}

void replaceStruct(
    StructStore store, AbstractStruct struct, AbstractStruct newStruct) {
  final structs =
      /** @type {List<GC|Item>} */ (store.clients.get(struct.id.client))!;
  structs[findIndexSS(structs, struct.id.clock)] = newStruct;
}

void iterateStructs(
  Transaction transaction,
  List<AbstractStruct> structs,
  int clockStart,
  int len,
  void Function(AbstractStruct) f,
) {
  if (len == 0) {
    return;
  }
  final clockEnd = clockStart + len;
  var index = findIndexCleanStart(transaction, structs, clockStart);
  AbstractStruct struct;
  do {
    struct = structs[index++];
    if (clockEnd < struct.id.clock + struct.length) {
      findIndexCleanStart(transaction, structs, clockEnd);
    }
    f(struct);
  } while (index < structs.length && structs[index].id.clock < clockEnd);
}
