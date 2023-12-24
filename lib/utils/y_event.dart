// import {
//   isDeleted,
//   Item,
//   AbstractType,
//   Transaction,
//   AbstractStruct, // eslint-disable-line
// } from "../internals.js";

// import * as set from "lib0/set.js";
// import * as array from "lib0/array.js";

import 'package:flutter_crdt/structs/abstract_struct.dart';
import 'package:flutter_crdt/structs/item.dart';
import 'package:flutter_crdt/types/abstract_type.dart';
import 'package:flutter_crdt/utils/delete_set.dart';
import 'package:flutter_crdt/utils/transaction.dart';
import 'package:flutter_crdt/y_crdt_base.dart';

/**
 * YEvent describes the changes on a YType.
 */
class YEvent {
  /**
   * @param {AbstractType<any>} target The changed type.
   * @param {Transaction} transaction
   */
  YEvent(this.target, this.transaction) : currentTarget = target;

  /**
   * The type on which this event was created on.
   * @type {AbstractType<any>}
   */
  final AbstractType<YEvent> target;

  /**
   * The current target on which the observe callback is called.
   * @type {AbstractType<any>}
   */
  AbstractType currentTarget;

  /**
   * The transaction that triggered this event.
   * @type {Transaction}
   */
  Transaction transaction;

  /**
   * @type {Object|null}
   */
  YChanges? _changes;
  Map<String, YChange>? _keys;

  /**
   * Computes the path from `y` to the changed type.
   *
   * The following property holds:
   * @example
   *   var type = y
   *   event.path.forEach(dir => {
   *     type = type.get(dir)
   *   })
   *   type == event.target // => true
   */
  List get path {
    // @ts-ignore _item is defined because target is integrated
    return getPathTo(this.currentTarget, this.target);
  }

  /**
   * Check if a struct is deleted by this event.
   *
   * In contrast to change.deleted, this method also returns true if the struct was added and then deleted.
   *
   * @param {AbstractStruct} struct
   * @return {boolean}
   */
  bool deletes(AbstractStruct struct) {
    return isDeleted(this.transaction.deleteSet, struct.id);
  }

  Map<String, YChange> get keys {
    if (_keys == null) {
      final keys = Map<String, YChange>();
      final target = this.target;
      final changed = this.transaction.changed[target] as Set<String?>;
      changed.forEach((key) {
        if (key != null) {
          final item = target.innerMap[key] as Item;
          YChangeType action;
          dynamic oldValue;
          if (adds(item)) {
            var prev = item.left;
            while (prev != null && adds(prev)) {
              prev = prev.left;
            }
            if (deletes(item)) {
              if (prev != null && deletes(prev)) {
                action = YChangeType.delete;
                oldValue = prev.content.getContent().last;
              } else {
                return;
              }
            } else {
              if (prev != null && deletes(prev)) {
                action = YChangeType.update;
                oldValue = prev.content.getContent().last;
              } else {
                action = YChangeType.add;
                oldValue = null;
              }
            }
          } else {
            if (deletes(item)) {
              action = YChangeType.delete;
              oldValue = item.content.getContent().last;
            } else {
              return;
            }
          }
          keys[key] = YChange(action, oldValue);
        }
      });
      _keys = keys;
    }
    return _keys!;
  }

  List<Map<String, dynamic>> get delta{
    return changes.delta;
  }

  /**
   * Check if a struct is added by this event.
   *
   * In contrast to change.deleted, this method also returns true if the struct was added and then deleted.
   *
   * @param {AbstractStruct} struct
   * @return {boolean}
   */
  bool adds(AbstractStruct struct) {
    return struct.id.clock >=
        (this.transaction.beforeState.get(struct.id.client) ?? 0);
  }
  /**
   * This is a computed property. Note that this can only be safely computed during the
   * event call. Computing this property after other changes happened might result in
   * unexpected behavior (incorrect computation of deltas). A safe way to collect changes
   * is to store the `changes` or the `delta` object. Avoid storing the `transaction` object.
   *
   * @type {{added:Set<Item>,deleted:Set<Item>,keys:Map<String,{action:'add'|'update'|'delete',oldValue:any}>,delta:Array<{insert?:List<dynamic>|String, delete?:int, retain?:int}>}}
   */
 YChanges get changes {
    var changes = _changes;
    if (changes == null) {
      var target = this.target;
      var added = Set<Item>();
      var deleted = Set<Item>();
      /**
       * @type {List<{insert:List<dynamic>}|{delete:int}|{retain:int}>}
       */
      var delta = <Map<String, dynamic>>[];
      changes=YChanges(added: added, deleted: deleted, keys: keys, delta: delta);
      var changed = this.transaction.changed[target];
      if (changed?.contains(null)==true) {
        /**
         * @type {dynamic}
         */
        var lastOp = null;
        var packOp = () {
          if (lastOp != null) {
            delta.add(lastOp);
          }
        };
        for (var item = target.innerStart; item != null; item = item.right) {
          if (item.deleted) {
            if (this.deletes(item) && !this.adds(item)) {
              if (lastOp == null || lastOp['delete'] == null) {
                packOp();
                lastOp = {'delete': 0};
              }
              lastOp['delete'] += item.length;
              deleted.add(item);
            } // else nop
          } else {
            if (this.adds(item)) {
              if (lastOp == null || lastOp['insert'] == null) {
                packOp();
                lastOp = {'insert': []};
              }
              lastOp['insert'].addAll(item.content.getContent());
              added.add(item);
            } else {
              if (lastOp == null || lastOp['retain'] == null) {
                packOp();
                lastOp = {'retain': 0};
              }
              lastOp['retain'] += item.length;
            }
          }
        }
        if (lastOp != null && lastOp['retain'] == null) {
          packOp();
        }
      }
      _changes = changes;
    }
    return changes;
  }

}

class YChanges {
  final Set<Item> added;
  final Set<Item> deleted;
  final Map<String, YChange> keys;
  final List<Map<String, dynamic>> delta;

  YChanges({
    required this.added,
    required this.deleted,
    required this.keys,
    required this.delta,
  });

  @override
  String toString() {
    return 'YChanges(added: $added, deleted: $deleted,'
        ' keys: $keys, delta: $delta)';
  }
}

enum YChangeType { add, update, delete }

class YChange {
  final YChangeType action;
  final Object? oldValue;

  YChange(this.action, this.oldValue);
}

enum _DeltaType { insert, retain, delete }

class YDelta {
  _DeltaType type;
  List<dynamic>? inserts;
  int? amount;

  factory YDelta.insert(List<dynamic> inserts) {
    return YDelta._(_DeltaType.insert, inserts, null);
  }

  factory YDelta.retain(int amount) {
    return YDelta._(_DeltaType.retain, null, amount);
  }

  factory YDelta.delete(int amount) {
    return YDelta._(_DeltaType.delete, null, amount);
  }

  YDelta._(this.type, this.inserts, this.amount);
}

/**
 * Compute the path from this type to the specified target.
 *
 * @example
 *   // `child` should be accessible via `type.get(path[0]).get(path[1])..`
 *   const path = type.getPathTo(child)
 *   // assuming `type is YArray`
 *   console.log(path) // might look like => [2, 'key1']
 *   child == type.get(path[0]).get(path[1])
 *
 * @param {AbstractType<any>} parent
 * @param {AbstractType<any>} child target
 * @return {List<string|number>} Path to the target
 *
 * @private
 * @function
 */
List getPathTo(AbstractType parent, AbstractType child) {
  final path = [];
  var childItem = child.innerItem;
  while (childItem != null && child != parent) {
    if (childItem.parentSub != null) {
      // parent is map-ish
      path.insert(0, childItem.parentSub);
    } else {
      // parent is array-ish
      var i = 0;
      var c =
          /** @type {AbstractType<any>} */ (childItem.parent as AbstractType)
              .innerStart;
      while (c != childItem && c != null) {
        if (!c.deleted) {
          i++;
        }
        c = c.right;
      }
      path.insert(0, i);
    }
    child = /** @type {AbstractType<any>} */ childItem.parent as AbstractType;
    childItem = child.innerItem;
  }
  return path;
}
