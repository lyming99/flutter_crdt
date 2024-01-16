// import {
//   GC,
//   getState,
//   AbstractStruct,
//   replaceStruct,
//   addStruct,
//   addToDeleteSet,
//   findRootTypeKey,
//   compareIDs,
//   getItem,
//   getItemCleanEnd,
//   getItemCleanStart,
//   readContentDeleted,
//   readContentBinary,
//   readContentJSON,
//   readContentAny,
//   readContentString,
//   readContentEmbed,
//   readContentDoc,
//   createID,
//   readContentFormat,
//   readContentType,
//   addChangedTypeToTransaction,
//   AbstractUpdateDecoder, AbstractUpdateEncoder, ContentType, ContentDeleted, StructStore, ID, AbstractType, Transaction // eslint-disable-line
// } from '../internals.js'

import 'package:flutter_crdt/lib0/binary.dart' as binary;

// import * as error from 'lib0/error.js'
// import * as binary from 'lib0/binary.js'

import 'package:flutter_crdt/structs/abstract_struct.dart';
import 'package:flutter_crdt/structs/content_any.dart';
import 'package:flutter_crdt/structs/content_binary.dart';
import 'package:flutter_crdt/structs/content_deleted.dart';
import 'package:flutter_crdt/structs/content_doc.dart';
import 'package:flutter_crdt/structs/content_embed.dart';
import 'package:flutter_crdt/structs/content_format.dart';
import 'package:flutter_crdt/structs/content_json.dart';
import 'package:flutter_crdt/structs/content_string.dart';
import 'package:flutter_crdt/structs/content_type.dart';
import 'package:flutter_crdt/structs/gc.dart';
import 'package:flutter_crdt/types/abstract_type.dart';
import 'package:flutter_crdt/utils/delete_set.dart';
import 'package:flutter_crdt/utils/id.dart';
import 'package:flutter_crdt/utils/struct_store.dart';
import 'package:flutter_crdt/utils/transaction.dart';
import 'package:flutter_crdt/utils/undo_manager.dart';
import 'package:flutter_crdt/utils/update_decoder.dart';
import 'package:flutter_crdt/utils/update_encoder.dart';
import 'package:flutter_crdt/utils/y_event.dart';
import 'package:flutter_crdt/y_crdt_base.dart';

export 'package:flutter_crdt/structs/content_any.dart' show readContentAny;
export 'package:flutter_crdt/structs/content_binary.dart'
    show readContentBinary;
export 'package:flutter_crdt/structs/content_deleted.dart'
    show readContentDeleted;
export 'package:flutter_crdt/structs/content_doc.dart' show readContentDoc;
export 'package:flutter_crdt/structs/content_embed.dart' show readContentEmbed;
export 'package:flutter_crdt/structs/content_format.dart'
    show readContentFormat;
export 'package:flutter_crdt/structs/content_json.dart' show readContentJSON;
export 'package:flutter_crdt/structs/content_string.dart'
    show readContentString;
export 'package:flutter_crdt/structs/content_type.dart' show readContentType;

/**
 * @todo This should return several items
 *
 * @param {StructStore} store
 * @param {ID} id
 * @return {{item:Item, diff:number}}
 */
_R followRedone(StructStore store, ID id) {
  /**
   * @type {ID|null}
   */
  ID? nextID = id;
  var diff = 0;
  AbstractStruct item;
  do {
    if (diff > 0) {
      nextID = createID(nextID!.client, nextID.clock + diff);
    }
    item = getItem(store, nextID!);
    diff = nextID.clock - item.id.clock;
    if (item is Item) {
      nextID = (item as Item).redone;
    } else {
      break;
    }
  } while (nextID != null);

  return _R(item, diff);
}

class _R {
  final AbstractStruct item;
  final int diff;

  const _R(this.item, this.diff);
}

/**
 * Make sure that neither item nor any of its parents is ever deleted.
 *
 * This property does not persist when storing it into a database or when
 * sending it to other peers
 *
 * @param {Item|null} item
 * @param {boolean} keep
 */
void keepItem(item, keep) {
  while (item != null && item.keep != keep) {
    item.keep = keep;
    item = /** @type {AbstractType<any>} */ (item.parent as AbstractType)
        .innerItem;
  }
}

/**
 * Split leftItem into two items
 * @param {Transaction} transaction
 * @param {Item} leftItem
 * @param {number} diff
 * @return {Item}
 *
 * @function
 * @private
 */
Item splitItem(Transaction transaction, Item leftItem, int diff) {
  // create rightItem
  final client = leftItem.id.client;
  final clock = leftItem.id.clock;
  final rightItem = Item(
      createID(client, clock + diff),
      leftItem,
      createID(client, clock + diff - 1),
      leftItem.right,
      leftItem.rightOrigin,
      leftItem.parent,
      leftItem.parentSub,
      leftItem.content.splice(diff));
  if (leftItem.deleted) {
    rightItem.markDeleted();
  }
  if (leftItem.keep) {
    rightItem.keep = true;
  }
  final leftItemRedone = leftItem.redone;
  if (leftItemRedone != null) {
    rightItem.redone =
        createID(leftItemRedone.client, leftItemRedone.clock + diff);
  }
  // update left (do not set leftItem.rightOrigin as it will lead to problems when syncing)
  leftItem.right = rightItem;
  // update right
  if (rightItem.right != null) {
    rightItem.right!.left = rightItem;
  }
  // right is more specific.
  transaction.mergeStructs.add(rightItem);
  // update parent._map
  if (rightItem.parentSub != null && rightItem.right == null) {
    /** @type {AbstractType<any>} */
    (rightItem.parent as AbstractType)
        .innerMap
        .set(rightItem.parentSub!, rightItem);
  }
  leftItem.length = diff;
  return rightItem;
}

bool isDeletedByUndoStack(List<StackItem> stack, id) {
  return stack.any((element) => isDeleted(element.deletions, id));
}

/**
 * Redoes the effect of this operation.
 *
 * @param {Transaction} transaction The Yjs instance.
 * @param {Item} item
 * @param {Set<Item>} redoitems
 *
 * @return {Item|null}
 *
 * @private
 */
Item? redoItem(Transaction transaction, Item item, Set<Item> redoitems,
    DeleteSet itemsToDelete, bool ignoreRemoteMapChanges, UndoManager um) {
  final doc = transaction.doc;
  final store = doc.store;
  final ownClientID = doc.clientID;
  final redone = item.redone;
  if (redone != null) {
    return getItemCleanStart(transaction, redone);
  }
  Item? parentItem =
  /** @type {AbstractType<any>} */ (item.parent as AbstractType).innerItem;
  /**
   * @type {Item|null}
   */
  Item? left;
  /**
   * @type {Item|null}
   */
  Item? right;
  if (parentItem != null && parentItem.deleted == true) {
    if (parentItem.redone == null &&
        (!redoitems.contains(parentItem) ||
            redoItem(transaction, parentItem, redoitems, itemsToDelete,
                ignoreRemoteMapChanges, um) ==
                null)) {
      return null;
    }
    while (parentItem!.redone != null) {
      parentItem = getItemCleanStart(transaction, parentItem.redone!);
    }
  }
  // abstract type | content type
  var parentType = parentItem == null
      ? item.parent
      : (parentItem.content as ContentType).type;
  if (item.parentSub == null) {
    // Is an array item. Insert at the old position
    left = item.left;
    right = item;
    while (left != null) {
      Item? leftTrace = left;
      while (leftTrace != null &&
          (leftTrace.parent as AbstractType).innerItem != parentItem) {
        leftTrace = leftTrace.redone == null
            ? null
            : getItemCleanStart(transaction, leftTrace.redone!);
      }
      if (leftTrace != null &&
          (leftTrace.parent as AbstractType).innerItem == parentItem) {
        left = leftTrace;
        break;
      }
      left = left.left;
    }

    while (right != null) {
      Item? rightTrace = right;
      while (rightTrace != null &&
          (rightTrace.parent as AbstractType).innerItem == parentItem) {
        rightTrace = rightTrace.redone == null
            ? null
            : getItemCleanStart(transaction, rightTrace.redone!);
        break;
      }
      if (rightTrace != null &&
          (rightTrace.parent as AbstractType).innerItem == parentItem) {
        right = rightTrace;
        break;
      }
      right = right.right;
    }
  } else {
    right = null;
    if (item.right != null && !ignoreRemoteMapChanges) {
      left = item;
      while (left != null &&
          left.right != null &&
          (left.right!.redone != null ||
              isDeleted(itemsToDelete, left.right!.id) ||
              isDeletedByUndoStack(um.undoStack, left.right!.id) ||
              isDeletedByUndoStack(um.undoStack, left.right!.id))) {
        left = left.right;
        while (left?.redone != null) {
          left = getItemCleanStart(transaction, left!.redone!);
        }
      }
      if (left != null && left.right != null) {
        return null;
      }
    } else {
      left = (parentType as AbstractType).innerMap.get((item.parentSub ?? ""));
    }
  }
  final nextClock = getState(store, ownClientID);
  final nextId = createID(ownClientID, nextClock);
  final redoneItem = Item(
      nextId,
      left,
      left?.lastId,
      right,
      right?.id,
      parentType,
      item.parentSub,
      item.content.copy());
  item.redone = nextId;
  keepItem(redoneItem, true);
  redoneItem.integrate(transaction, 0);
  return redoneItem;
}

/**
 * Abstract class that represents any content.
 */
class Item extends AbstractStruct {
  /**
   * @param {ID} id
   * @param {Item | null} left
   * @param {ID | null} origin
   * @param {Item | null} right
   * @param {ID | null} rightOrigin
   * @param {AbstractType<any>|ID|null} parent Is a type if integrated, is null if it is possible to copy parent from left or right, is ID before integration to search for it.
   * @param {string | null} parentSub
   * @param {AbstractContent} content
   */
  Item(ID id, this.left, this.origin, this.right, this.rightOrigin, this.parent,
      this.parentSub, this.content)
      : info = content.isCountable() ? binary.BIT2 : 0,
        super(id, content.getLength());

  ID? origin;

  Item? left;

  Item? right;

  ID? rightOrigin;
  Object? parent;

  String? parentSub;
  ID? redone;
  AbstractContent content;

  int info;

  set marker(bool isMarked) {
    if (((this.info & binary.BIT4) > 0) != isMarked) {
      this.info ^= binary.BIT4;
    }
  }

  bool get marker {
    return (this.info & binary.BIT4) > 0;
  }

  bool get keep {
    return (this.info & binary.BIT1) > 0;
  }

  set keep(bool doKeep) {
    if (this.keep != doKeep) {
      this.info ^= binary.BIT1;
    }
  }

  bool get countable {
    return (this.info & binary.BIT2) > 0;
  }

  @override
  bool get deleted {
    return (this.info & binary.BIT3) > 0;
  }

  set deleted(doDelete) {
    if (this.deleted != doDelete) {
      this.info ^= binary.BIT3;
    }
  }

  void markDeleted() {
    this.info |= binary.BIT3;
  }

  int? getMissing(Transaction transaction, StructStore store) {
    final _origin = this.origin;
    if (_origin != null &&
        _origin.client != this.id.client &&
        _origin.clock >= getState(store, _origin.client)) {
      return _origin.client;
    }
    final _rightOrigin = this.rightOrigin;
    if (_rightOrigin != null &&
        _rightOrigin.client != this.id.client &&
        _rightOrigin.clock >= getState(store, _rightOrigin.client)) {
      return _rightOrigin.client;
    }
    final _parent = this.parent;
    if (_parent != null &&
        _parent is ID &&
        this.id.client != _parent.client &&
        _parent.clock >= getState(store, _parent.client)) {
      return _parent.client;
    }

    // We have all missing ids, now find the items

    if (_origin != null) {
      this.left = getItemCleanEnd(transaction, store, _origin);
      this.origin = this.left!.lastId;
    }
    if (this.rightOrigin != null) {
      this.right = getItemCleanStart(transaction, this.rightOrigin!);
      this.rightOrigin = this.right!.id;
    }
    if (this.left is GC || this.right is GC) {
      this.parent = null;
    }
    // only set parent if this shouldn't be garbage collected
    if (this.parent == null) {
      final _left = this.left;
      if (_left is Item) {
        this.parent = _left.parent;
        this.parentSub = _left.parentSub;
      }
      final _right = this.right;
      if (_right is Item) {
        this.parent = _right.parent;
        this.parentSub = _right.parentSub;
      }
    } else if (this.parent is ID) {
      final parentItem = getItem(store, this.parent as ID);
      if (parentItem is GC) {
        this.parent = null;
      } else {
        this.parent = ((parentItem as Item).content as ContentType).type;
      }
    }
    return null;
  }

  @override
  void integrate(Transaction transaction, int offset) {
    if (offset > 0) {
      this.id.clock += offset;
      this.left = getItemCleanEnd(
        transaction,
        transaction.doc.store,
        createID(this.id.client, this.id.clock - 1),
      );
      this.origin = this.left!.lastId;
      this.content = this.content.splice(offset);
      this.length -= offset;
    }

    if (this.parent != null) {
      if ((this.left == null &&
          (this.right == null || this.right!.left != null)) ||
          (this.left != null && this.left!.right != this.right)) {
        Item? left = this.left;
        Item? o;
        // set o to the first conflicting item
        if (left != null) {
          o = left.right;
        } else if (this.parentSub != null) {
          o = (this.parent as AbstractType)
              .innerMap
              .get(this.parentSub!);
          while (o != null && o.left != null) {
            o = o.left;
          }
        } else {
          o = (this.parent as AbstractType)
              .innerStart;
        }
        final conflictingItems = <Item>{};
        final itemsBeforeOrigin = <Item>{};
        while (o != null && o != this.right) {
          itemsBeforeOrigin.add(o);
          conflictingItems.add(o);
          if (compareIDs(this.origin, o.origin)) {
            // case 1
            if (o.id.client < this.id.client) {
              left = o;
              conflictingItems.clear();
            } else if (compareIDs(this.rightOrigin, o.rightOrigin)) {
              break;
            }
          } else if (o.origin != null &&
              itemsBeforeOrigin
                  .contains(getItem(transaction.doc.store, o.origin!))) {
            if (!conflictingItems
                .contains(getItem(transaction.doc.store, o.origin!))) {
              left = o;
              conflictingItems.clear();
            }
          } else {
            break;
          }
          o = o.right;
        }
        this.left = left;
      }
      final _left = this.left;
      if (_left != null) {
        final right = _left.right;
        this.right = right;
        _left.right = this;
      } else {
        Item? r;
        if (this.parentSub != null) {
          r = (this.parent as AbstractType)
              .innerMap
              .get(this.parentSub!);
          while (r != null && r.left != null) {
            r = r.left;
          }
        } else {
          r = (this.parent as AbstractType)
              .innerStart;
          (this.parent as AbstractType).innerStart = this;
        }
        this.right = r;
      }
      if (this.right != null) {
        this.right!.left = this;
      } else if (this.parentSub != null) {
        (this.parent as AbstractType).innerMap.set(this.parentSub!, this);
        if (this.left != null) {
          this.left!.delete(transaction);
        }
      }
      if (this.parentSub == null && this.countable && !this.deleted) {
        (this.parent as AbstractType).innerLength += this.length;
      }
      addStruct(transaction.doc.store, this);
      this.content.integrate(transaction, this);
      final _parent = this.parent;
      if (_parent is AbstractType<YEvent>) {
        addChangedTypeToTransaction(transaction, _parent, this.parentSub);
        if ((_parent.innerItem != null && _parent.innerItem!.deleted) ||
            (this.parentSub != null && this.right != null)) {
          this.delete(transaction);
        }
      }
    } else {
      // parent is not defined. Integrate GC struct instead
      GC(this.id, this.length).integrate(transaction, 0);
    }
  }

  Item? get next {
    var n = this.right;
    while (n != null && n.deleted) {
      n = n.right;
    }
    return n;
  }

  Item? get prev {
    var n = this.left;
    while (n != null && n.deleted) {
      n = n.left;
    }
    return n;
  }

  ID get lastId {
    // allocating ids is pretty costly because of the amount of ids created, so we try to reuse whenever possible
    return this.length == 1
        ? this.id
        : createID(this.id.client, this.id.clock + this.length - 1);
  }

  @override
  bool mergeWith(AbstractStruct right) {
    if (right is! Item) {
      return false;
    }
    if (compareIDs(right.origin, this.lastId) &&
        this.right == right &&
        compareIDs(this.rightOrigin, right.rightOrigin) &&
        this.id.client == right.id.client &&
        this.id.clock + this.length == right.id.clock &&
        this.deleted == right.deleted &&
        this.redone == null &&
        right.redone == null &&
        this.content.runtimeType == right.content.runtimeType &&
        this.content.mergeWith(right.content)) {
      var searchMarker = (this.parent as AbstractType).innerSearchMarker;
      if (searchMarker != null) {
        for (var marker in searchMarker) {
          if (marker.p == right) {
            marker.p = this;
            if (!this.deleted && this.countable) {
              marker.index -= this.length;
            }
          }
        }
      }
      if (right.keep) {
        this.keep = true;
      }
      this.right = right.right;
      if (this.right != null) {
        this.right!.left = this;
      }
      this.length += right.length;
      return true;
    }
    return false;
  }

  void delete(Transaction transaction) {
    if (!this.deleted) {
      final parent = this.parent as AbstractType<YEvent>;
      // adjust the length of parent
      if (this.countable && this.parentSub == null) {
        parent.innerLength -= this.length;
      }
      this.markDeleted();
      addToDeleteSet(
        transaction.deleteSet,
        this.id.client,
        this.id.clock,
        this.length,
      );
      addChangedTypeToTransaction(transaction, parent, this.parentSub);
      this.content.delete(transaction);
    }
  }

  void gc(StructStore store, bool parentGCd) {
    if (!this.deleted) {
      throw Exception('Unexpected case');
    }
    this.content.gc(store);
    if (parentGCd) {
      replaceStruct(store, this, GC(this.id, this.length));
    } else {
      this.content = ContentDeleted(this.length);
    }
  }

  @override
  void write(AbstractUpdateEncoder encoder, int offset) {
    final origin = offset > 0
        ? createID(this.id.client, this.id.clock + offset - 1)
        : this.origin;
    final rightOrigin = this.rightOrigin;
    final parentSub = this.parentSub;
    final info = (this.content.getRef() & binary.BITS5) |
    (origin == null ? 0 : binary.BIT8) | // origin is defined
    (rightOrigin == null ? 0 : binary.BIT7) | // right origin is defined
    (parentSub == null ? 0 : binary.BIT6); // parentSub is non-null
    encoder.writeInfo(info);
    if (origin != null) {
      encoder.writeLeftID(origin);
    }
    if (rightOrigin != null) {
      encoder.writeRightID(rightOrigin);
    }
    if (origin == null && rightOrigin == null) {
      final parent = this.parent;
      if (parent is AbstractType) {
        final parentItem = parent.innerItem;
        if (parentItem == null) {
          final ykey = findRootTypeKey(parent);
          encoder.writeParentInfo(true); // write parentYKey
          encoder.writeString(ykey);
        } else {
          encoder.writeParentInfo(false); // write parent id
          encoder.writeLeftID(parentItem.id);
        }
      } else if (parent is String) {
        encoder.writeParentInfo(true);
        encoder.writeString(parent);
      } else if (parent is ID) {
        encoder.writeParentInfo(false);
        encoder.writeLeftID(parent);
      } else {
        throw Exception("");
      }
      if (parentSub != null) {
        encoder.writeString(parentSub);
      }
    }
    this.content.write(encoder, offset);
  }
}

dynamic readItemContent(AbstractUpdateDecoder decoder, int info) =>
    contentRefs[info & binary.BITS5](decoder);

final contentRefs = [
      () {
    throw Exception('Unexpected case');
  }, // GC is not ItemContent
  readContentDeleted, // 1
  readContentJSON, // 2
  readContentBinary, // 3
  readContentString, // 4
  readContentEmbed, // 5
  readContentFormat, // 6
  readContentType, // 7
  readContentAny, // 8
  readContentDoc // 9
];

abstract class AbstractContent {
  int getLength();

  List getContent();

  bool isCountable();

  AbstractContent copy();

  AbstractContent splice(int offset);

  bool mergeWith(AbstractContent right);

  void integrate(Transaction transaction, Item item);

  void delete(Transaction transaction);

  void gc(StructStore store);

  void write(AbstractUpdateEncoder encoder, int offset);

  int getRef();
}
