import 'dart:math' as math;

import 'package:flutter_crdt/structs/abstract_struct.dart';
import 'package:flutter_crdt/structs/item.dart';
import 'package:flutter_crdt/types/abstract_type.dart';
import 'package:flutter_crdt/utils/delete_set.dart';
import 'package:flutter_crdt/utils/doc.dart';
import 'package:flutter_crdt/utils/encoding.dart';
import 'package:flutter_crdt/utils/event_handler.dart';
import 'package:flutter_crdt/utils/id.dart';
import 'package:flutter_crdt/utils/struct_store.dart';
import 'package:flutter_crdt/utils/update_encoder.dart';
import 'package:flutter_crdt/utils/y_event.dart';
import 'package:flutter_crdt/y_crdt_base.dart';

class Transaction {
  Transaction(this.doc, this.origin, this.local)
      : beforeState = getStateVector(doc.store);

  final Doc doc;

  final deleteSet = DeleteSet();

  late Map<int, int> beforeState;

  var afterState = <int, int>{};

  final changed = <AbstractType<YEvent>, Set<String?>>{};

  final changedParentTypes = <AbstractType<YEvent>, List<YEvent>>{};

  final mergeStructs = <AbstractStruct>[];

  final Object? origin;

  final meta = <Object, dynamic>{};

  bool local;

  final subdocsAdded = <Doc>{};

  final subdocsRemoved = <Doc>{};

  final subdocsLoaded = <Doc>{};
}

bool writeUpdateMessageFromTransaction(
    AbstractUpdateEncoder encoder, Transaction transaction) {
  if (transaction.deleteSet.clients.length == 0 &&
      !transaction.afterState.entries.any(
          (entry) => transaction.beforeState.get(entry.key) != entry.value)) {
    return false;
  }
  sortAndMergeDeleteSet(transaction.deleteSet);
  writeStructsFromTransaction(encoder, transaction);
  writeDeleteSet(encoder, transaction.deleteSet);
  return true;
}

ID nextID(Transaction transaction) {
  final y = transaction.doc;
  return createID(y.clientID, getState(y.store, y.clientID));
}

void addChangedTypeToTransaction(
    Transaction transaction, AbstractType<YEvent> type, String? parentSub) {
  final item = type.innerItem;
  if (item == null ||
      (item.id.clock < (transaction.beforeState.get(item.id.client) ?? 0) &&
          !item.deleted)) {
    transaction.changed.putIfAbsent(type, () => {}).add(parentSub);
  }
}

void tryToMergeWithLeft(List<AbstractStruct> structs, int pos) {
  final left = structs[pos - 1];
  final right = structs[pos];
  if (left.deleted == right.deleted && left.runtimeType == right.runtimeType) {
    if (left.mergeWith(right)) {
      structs.removeAt(pos);
      if (right is Item &&
          right.parentSub != null &&
          (right.parent as AbstractType).innerMap.get(right.parentSub!) ==
              right) {
        (right.parent as AbstractType)
            .innerMap
            .set(right.parentSub!, /** @type {Item} */ left as Item);
      }
    }
  }
}

void tryGcDeleteSet(
    DeleteSet ds, StructStore store, bool Function(Item) gcFilter) {
  for (final entry in ds.clients.entries) {
    final client = entry.key;
    final deleteItems = entry.value;
    final structs = store.clients.get(client)!;
    for (var di = deleteItems.length - 1; di >= 0; di--) {
      final deleteItem = deleteItems[di];
      final endDeleteItemClock = deleteItem.clock + deleteItem.len;

      for (var si = findIndexSS(structs, deleteItem.clock);
          si < structs.length && structs[si].id.clock < endDeleteItemClock;
          si++) {
        final struct = structs[si];
        if (deleteItem.clock + deleteItem.len <= struct.id.clock) {
          break;
        }
        if (struct is Item &&
            struct.deleted &&
            !struct.keep &&
            gcFilter(struct)) {
          struct.gc(store, false);
        }
      }
    }
  }
}

void tryMergeDeleteSet(DeleteSet ds, StructStore store) {
  ds.clients.forEach((client, deleteItems) {
    final structs = /** @type {List<GC|Item>} */ store.clients.get(client);
    if (structs != null) {
      for (var di = deleteItems.length - 1; di >= 0; di--) {
        final deleteItem = deleteItems[di];
        // start with merging the item next to the last deleted item
        final mostRightIndexToCheck = math.min(structs.length - 1,
            1 + findIndexSS(structs, deleteItem.clock + deleteItem.len - 1));
        for (var si = mostRightIndexToCheck, struct = structs[si];
            si > 0 && struct.id.clock >= deleteItem.clock;
            struct = structs[--si]) {
          tryToMergeWithLeft(structs, si);
        }
      }
    }
  });
}

void tryGc(DeleteSet ds, StructStore store, bool Function(Item) gcFilter) {
  tryGcDeleteSet(ds, store, gcFilter);
  tryMergeDeleteSet(ds, store);
}

void cleanupTransactions(List<Transaction> transactionCleanups, int i) {
  if (i < transactionCleanups.length) {
    final transaction = transactionCleanups[i];
    final doc = transaction.doc;
    final store = doc.store;
    final ds = transaction.deleteSet;
    final mergeStructs = transaction.mergeStructs;
    try {
      sortAndMergeDeleteSet(ds);
      transaction.afterState = getStateVector(transaction.doc.store);
      doc.transaction = null;
      doc.emit('beforeObserverCalls', [transaction, doc]);
      final fs = <void Function()>[];
      transaction.changed.forEach((itemtype, subs) => fs.add(() {
            if (itemtype.innerItem == null || !itemtype.innerItem!.deleted) {
              itemtype.innerCallObserver(transaction, subs);
            }
          }));
      fs.add(() {
        transaction.changedParentTypes.forEach((type, events) => fs.add(() {
              if (type.innerItem == null || !type.innerItem!.deleted) {
                events = events
                    .where((event) =>
                        event.target.innerItem == null ||
                        !event.target.innerItem!.deleted)
                    .toList();
                events.forEach((event) {
                  event.currentTarget = type;
                });
                events.sort((event1, event2) =>
                    event1.path.length - event2.path.length);
                callEventHandlerListeners(type.innerdEH, events, transaction);
              }
            }));
        fs.add(() => doc.emit('afterTransaction', [transaction, doc]));
      });
      Object? _err;
      StackTrace? _stack;
      for (var i = 0; i < fs.length; i++) {
        try {
          fs[i]();
        } catch (e, s) {
          _err = e;
          _stack = s;
        }
      }
      if (_err != null) {
        logger.e("Exception from observer", _err, _stack);
        throw _err;
      }
    } finally {
      if (doc.gc) {
        tryGcDeleteSet(ds, store, doc.gcFilter);
      }
      tryMergeDeleteSet(ds, store);

      // on all affected store.clients props, try to merge
      transaction.afterState.forEach((client, clock) {
        final beforeClock = transaction.beforeState.get(client) ?? 0;
        if (beforeClock != clock) {
          final structs = store.clients.get(client);
          // we iterate from right to left so we can safely remove entries
          if (structs != null) {
            final firstChangePos =
                math.max(findIndexSS(structs, beforeClock), 1);
            for (var i = structs.length - 1; i >= firstChangePos; i--) {
              tryToMergeWithLeft(structs, i);
            }
          }
        }
      });
      for (var i = 0; i < mergeStructs.length; i++) {
        final client = mergeStructs[i].id.client;
        final clock = mergeStructs[i].id.clock;
        final structs = store.clients.get(client);
        if (structs != null) {
          final replacedStructPos = findIndexSS(structs, clock);
          if (replacedStructPos + 1 < structs.length) {
            tryToMergeWithLeft(structs, replacedStructPos + 1);
          }
          if (replacedStructPos > 0) {
            tryToMergeWithLeft(structs, replacedStructPos);
          }
        }
      }
      if (!transaction.local &&
          transaction.afterState.get(doc.clientID) !=
              transaction.beforeState.get(doc.clientID)) {
        doc.clientID = generateNewClientId();
        logger.w(
            'Changed the client-id because another client seems to be using it.');
      }
      doc.emit('afterTransactionCleanup', [transaction, doc]);
      if (doc.innerObservers.containsKey('update')) {
        final encoder = DefaultUpdateEncoder();
        final hasContent =
            writeUpdateMessageFromTransaction(encoder, transaction);
        if (hasContent) {
          doc.emit('update', [encoder.toUint8Array(), transaction.origin, doc]);
        }
      }
      if (doc.innerObservers.containsKey('updateV2')) {
        final encoder = UpdateEncoderV2();
        final hasContent =
            writeUpdateMessageFromTransaction(encoder, transaction);
        if (hasContent) {
          doc.emit('updateV2',
              [encoder.toUint8Array(), transaction.origin, doc, transaction]);
        }
      }

      final subdocsAdded = transaction.subdocsAdded;
      final subdocsLoaded = transaction.subdocsLoaded;
      final subdocsRemoved = transaction.subdocsRemoved;
      if (subdocsAdded.length > 0 || subdocsRemoved.length > 0 || subdocsLoaded.length > 0) {
        subdocsAdded.forEach((subdoc) {
          subdoc.clientID = doc.clientID;
          if (subdoc.collectionid == null) {
            subdoc.collectionid = doc.collectionid;
          }
          doc.subdocs.add(subdoc);
        });
        subdocsRemoved.forEach((subdoc) => doc.subdocs.remove(subdoc));
        doc.emit('subdocs', [
          {
            'loaded': subdocsLoaded,
            'added': subdocsAdded,
            'removed': subdocsRemoved
          },
          doc,
          transaction
        ]);
        subdocsRemoved.forEach((subdoc) => subdoc.destroy());
      }

      if (transactionCleanups.length <= i + 1) {
        doc.transactionCleanups = [];
        doc.emit('afterAllTransactions', [doc, transactionCleanups]);
      } else {
        cleanupTransactions(transactionCleanups, i + 1);
      }
    }
  }
}

void transact(Doc doc, void Function(Transaction) f,
    [Object? origin, bool local = true]) {
  final transactionCleanups = doc.transactionCleanups;
  var initialCall = false;
  if (doc.transaction == null) {
    initialCall = true;
    doc.transaction = Transaction(doc, origin, local);
    transactionCleanups.add(doc.transaction!);
    if (transactionCleanups.length == 1) {
      doc.emit('beforeAllTransactions', [doc]);
    }
    doc.emit('beforeTransaction', [doc.transaction, doc]);
  }
  try {
    f(doc.transaction!);
  } finally {
    if (initialCall && transactionCleanups[0] == doc.transaction) {
      cleanupTransactions(transactionCleanups, 0);
    }
  }
}
