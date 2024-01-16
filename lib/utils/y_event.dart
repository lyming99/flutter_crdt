import 'package:flutter_crdt/structs/abstract_struct.dart';
import 'package:flutter_crdt/structs/item.dart';
import 'package:flutter_crdt/types/abstract_type.dart';
import 'package:flutter_crdt/utils/delete_set.dart';
import 'package:flutter_crdt/utils/transaction.dart';
import 'package:flutter_crdt/y_crdt_base.dart';

class YEvent {
  YEvent(this.target, this.transaction) : currentTarget = target;

  final AbstractType<YEvent> target;

  AbstractType currentTarget;

  Transaction transaction;

  YChanges? _changes;
  Map<String, YChange>? _keys;

  List get path {
    return getPathTo(this.currentTarget, this.target);
  }

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

  List<Map<String, dynamic>> get delta {
    return changes.delta;
  }

  bool adds(AbstractStruct struct) {
    return struct.id.clock >=
        (this.transaction.beforeState.get(struct.id.client) ?? 0);
  }

  YChanges get changes {
    var changes = _changes;
    if (changes == null) {
      var target = this.target;
      var added = Set<Item>();
      var deleted = Set<Item>();
      var delta = <Map<String, dynamic>>[];
      changes =
          YChanges(added: added, deleted: deleted, keys: keys, delta: delta);
      var changed = this.transaction.changed[target];
      if (changed?.contains(null) == true) {
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
      var c = (childItem.parent as AbstractType).innerStart;
      while (c != childItem && c != null) {
        if (!c.deleted) {
          i++;
        }
        c = c.right;
      }
      path.insert(0, i);
    }
    child = childItem.parent as AbstractType;
    childItem = child.innerItem;
  }
  return path;
}
