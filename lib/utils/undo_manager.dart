import 'package:flutter_crdt/structs/item.dart';
import 'package:flutter_crdt/types/abstract_type.dart';
import 'package:flutter_crdt/utils/delete_set.dart';
import 'package:flutter_crdt/utils/doc.dart';
import 'package:flutter_crdt/utils/id.dart';
import 'package:flutter_crdt/utils/is_parent_of.dart';
import 'package:flutter_crdt/utils/observable.dart';
import 'package:flutter_crdt/utils/struct_store.dart';
import 'package:flutter_crdt/utils/transaction.dart';
import 'package:flutter_crdt/y_crdt_base.dart';
import 'package:collection/collection.dart';

class StackItem {
  StackItem(this.deletions, this.insertions);

  DeleteSet deletions;
  DeleteSet insertions;

  final Map meta = {};
}

void clearUndoManagerStackItem(
    Transaction tr, UndoManager um, StackItem stackItem) {
  iterateDeletedStructs(tr, stackItem.deletions, (item) {
    if (item is Item && um.scope.any((type) => isParentOf(type, item))) {
      keepItem(item, false);
    }
  });
}

StackItem? popStackItem(
    UndoManager undoManager, List<StackItem> stack, String eventType) {
  StackItem? result;
  var _tr;
  final doc = undoManager.doc;
  final scope = undoManager.scope;
  transact(doc, (transaction) {
    while (stack.length > 0 && result == null) {
      final store = doc.store;
      final stackItem = stack.removeLast();
      final itemsToRedo = <Item>{};
      final itemsToDelete = <Item>[];
      var performedChange = false;
      iterateDeletedStructs(transaction, stackItem.insertions, (struct) {
        if (struct is Item) {
          if (struct.redone != null) {
            final itemAndDiff = followRedone(store, struct.id);
            var item = itemAndDiff.item;
            final diff = itemAndDiff.diff;
            if (diff > 0) {
              item = getItemCleanStart(
                  transaction, createID(item.id.client, item.id.clock + diff));
            }
            struct = item;
          }
          if (!struct.deleted &&
              scope.any((type) => isParentOf(type, struct as Item))) {
            itemsToDelete.add(struct as Item);
          }
        }
      });
      iterateDeletedStructs(transaction, stackItem.deletions, (struct) {
        if (struct is Item &&
            scope.any((type) => isParentOf(type, struct)) &&
            !isDeleted(stackItem.insertions, struct.id)) {
          itemsToRedo.add(struct);
        }
      });
      itemsToRedo.forEach((struct) {
        performedChange = redoItem(
                    transaction,
                    struct,
                    itemsToRedo,
                    stackItem.insertions,
                    undoManager.ignoreRemoteMapChanges,
                    undoManager) !=
                null ||
            performedChange;
      });
      for (var i = itemsToDelete.length - 1; i >= 0; i--) {
        final item = itemsToDelete[i];
        if (undoManager.deleteFilter(item)) {
          item.delete(transaction);
          performedChange = true;
        }
      }
      result = performedChange ? stackItem : null;
    }
    transaction.changed.forEach((type, subProps) {
      if (subProps.contains(null) && type.innerSearchMarker != null) {
        type.innerSearchMarker!.length = 0;
      }
    });
    _tr = transaction;
  }, undoManager);
  if (result != null) {
    final changedParentTypes = _tr.changedParentTypes;
    undoManager.emit('stack-item-popped', [
      {
        'stackItem': result,
        'type': eventType,
        'changedParentTypes': changedParentTypes
      },
      undoManager
    ]);
  }
  return result;
}
bool _defaultDeleteFilter(Item _) => true;

bool _defaultCaptureTransaction(Transaction _) => true;

class UndoManager extends Observable {
  int captureTimeout;

  UndoManager(
    List<AbstractType> typeScope, {
    this.captureTimeout = 500,
    this.deleteFilter = _defaultDeleteFilter,
    Set<dynamic>? trackedOrigins,
    this.ignoreRemoteMapChanges = false,
    this.captureTransaction = _defaultCaptureTransaction,
  }) {
    this.scope = [];
    addToScope(typeScope);
    this.doc = this.scope[0].doc!;
    this.trackedOrigins =
        trackedOrigins == null ? {null, this} : {...trackedOrigins, this};

    doc.on('afterTransaction', afterTransactionHandler);
    doc.on('destroy', (args) {
      destroy();
    });
  }

  bool Function(Transaction _) captureTransaction;

  late final List<AbstractType<dynamic>> scope;

  late final Set<dynamic> trackedOrigins;

  final bool Function(Item) deleteFilter;

  List<StackItem> undoStack = [];

  List<StackItem> redoStack = [];

  bool undoing = false;
  bool redoing = false;
  late final Doc doc;
  int lastChange = 0;

  bool ignoreRemoteMapChanges = false;

  void afterTransactionHandler(List args) {
    Transaction transaction = args[0] as Transaction;
    if (!captureTransaction(transaction) ||
        !scope
            .any((type) => transaction.changedParentTypes.containsKey(type)) ||
        (!trackedOrigins.contains(transaction.origin) &&
            (transaction.origin == null ||
                !trackedOrigins.contains(transaction.origin.runtimeType)))) {
      return;
    }
    final undoing = this.undoing;
    final redoing = this.redoing;
    final stack = undoing ? this.redoStack : this.undoStack;
    if (undoing) {
      stopCapturing();
    } else if (!redoing) {
      clear(false, true);
    }
    final insertions = DeleteSet();
    transaction.afterState.forEach((client, endClock) {
      final startClock = transaction.beforeState[client] ?? 0;
      final len = endClock - startClock;
      if (len > 0) {
        addToDeleteSet(insertions, client, startClock, len);
      }
    });
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    var didAdd = false;
    if (this.lastChange > 0 &&
        now - this.lastChange < this.captureTimeout &&
        stack.length > 0 &&
        !undoing &&
        !redoing) {
      final lastOp = stack[stack.length - 1];
      lastOp.deletions =
          mergeDeleteSets([lastOp.deletions, transaction.deleteSet]);
      lastOp.insertions = mergeDeleteSets([lastOp.insertions, insertions]);
    } else {
      stack.add(StackItem(transaction.deleteSet, insertions));
      didAdd = true;
    }
    if (!undoing && !redoing) {
      this.lastChange = now;
    }
    iterateDeletedStructs(transaction, transaction.deleteSet, (item) {
      if (item is Item && scope.any((type) => isParentOf(type, item))) {
        keepItem(item, true);
      }
    });
    final changeEvent = [
      {
        'stackItem': stack[stack.length - 1],
        'origin': transaction.origin,
        'type': undoing ? 'redo' : 'undo',
        'changedParentTypes': transaction.changedParentTypes
      },
      this
    ];
    if (didAdd) {
      emit('stack-item-added', changeEvent);
    } else {
      emit('stack-item-updated', changeEvent);
    }
  }

  void addToScope(dynamic ytypes) {
    ytypes = ytypes is List<AbstractType<dynamic>> ? ytypes : [ytypes];
    ytypes.forEach((ytype) {
      if (this.scope.every((yt) => yt != ytype)) {
        this.scope.add(ytype);
      }
    });
  }

  void clear([bool clearUndoStack = true, bool clearRedoStack = true]) {
    if ((clearUndoStack && canUndo()) || (clearRedoStack && canRedo())) {
      doc.transact((tr) {
        if (clearUndoStack) {
          undoStack
              .forEach((item) => clearUndoManagerStackItem(tr, this, item));
          undoStack = [];
        }
        if (clearRedoStack) {
          redoStack
              .forEach((item) => clearUndoManagerStackItem(tr, this, item));
          redoStack = [];
        }
        emit('stack-cleared', [
          {
            'undoStackCleared': clearUndoStack,
            'redoStackCleared': clearRedoStack
          }
        ]);
      });
    }
  }

  void stopCapturing() {
    this.lastChange = 0;
  }

  StackItem? undo() {
    this.undoing = true;
    StackItem? res;
    try {
      res = popStackItem(this, this.undoStack, "undo");
    } finally {
      this.undoing = false;
    }
    return res;
  }

  StackItem? redo() {
    this.redoing = true;
    StackItem? res;
    try {
      res = popStackItem(this, this.redoStack, "redo");
    } finally {
      this.redoing = false;
    }
    return res;
  }

  bool canUndo() {
    return this.undoStack.length > 0;
  }

  bool canRedo() {
    return this.redoStack.length > 0;
  }

  @override
  void destroy() {
    trackedOrigins.remove(this);
    doc.off("afterTransaction", afterTransactionHandler);
    super.destroy();
  }
}
