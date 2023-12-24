/**
 * @module YText
 */

// import {
//   YEvent,
//   AbstractType,
//   getItemCleanStart,
//   getState,
//   isVisible,
//   createID,
//   YTextRefID,
//   callTypeObservers,
//   transact,
//   ContentEmbed,
//   GC,
//   ContentFormat,
//   ContentString,
//   splitSnapshotAffectedStructs,
//   iterateDeletedStructs,
//   iterateStructs,
//   findMarker,
//   updateMarkerChanges,
//   ArraySearchMarker,
//   AbstractUpdateDecoder,
//   AbstractUpdateEncoder,
//   ID,
//   Doc,
//   Item,
//   Snapshot,
//   Transaction, // eslint-disable-line
// } from "../internals.js";

// import * as object from "lib0/object.js";
// import * as map from "lib0/map.js";
// import * as error from "lib0/error.js";

import 'package:flutter_crdt/structs/content_embed.dart';
import 'package:flutter_crdt/structs/content_format.dart';
import 'package:flutter_crdt/structs/content_string.dart';
import 'package:flutter_crdt/structs/content_type.dart';
import 'package:flutter_crdt/structs/gc.dart';
import 'package:flutter_crdt/structs/item.dart';
import 'package:flutter_crdt/types/abstract_type.dart';
import 'package:flutter_crdt/utils/delete_set.dart';
import 'package:flutter_crdt/utils/doc.dart';
import 'package:flutter_crdt/utils/id.dart';
import 'package:flutter_crdt/utils/snapshot.dart';
import 'package:flutter_crdt/utils/struct_store.dart';
import 'package:flutter_crdt/utils/transaction.dart';
import 'package:flutter_crdt/utils/update_decoder.dart';
import 'package:flutter_crdt/utils/update_encoder.dart';
import 'package:flutter_crdt/utils/y_event.dart';
import 'package:flutter_crdt/y_crdt_base.dart';

/**
 * @param {any} a
 * @param {any} b
 * @return {boolean}
 */
bool equalAttrs(dynamic a, dynamic b) =>
    a == b ||
        (a is Map &&
            b is Map &&
            a.length == b.length &&
            a.entries.every((entry) =>
            b.containsKey(entry.key) && b[entry.key] == entry.value));

class ItemTextListPosition {
  /**
   * @param {Item|null} left
   * @param {Item|null} right
   * @param {number} index
   * @param {Map<string,any>} currentAttributes
   */
  ItemTextListPosition(this.left, this.right, this.index,
      this.currentAttributes);

  Item? left;
  Item? right;
  int index;
  final Map<String, Object?> currentAttributes;

  /**
   * Only call this if you know that this.right is defined
   */
  void forward() {
    final _right = this.right;
    if (_right == null) {
      throw Exception('Unexpected case');
    }
    if (_right.content is ContentEmbed || _right.content is ContentString) {
      if (!_right.deleted) {
        this.index += _right.length;
      }
    } else if (_right.content is ContentFormat) {
      if (!_right.deleted) {
        updateCurrentAttributes(
            this.currentAttributes, _right.content as ContentFormat);
      }
    }

    this.left = this.right;
    this.right = this.right!.right;
  }
}

/**
 * @param {Transaction} transaction
 * @param {ItemTextListPosition} pos
 * @param {number} count steps to move forward
 * @return {ItemTextListPosition}
 *
 * @private
 * @function
 */
ItemTextListPosition findNextPosition(Transaction transaction,
    ItemTextListPosition pos, int count) {
  var _right = pos.right;
  while (_right != null && count > 0) {
    if (_right.content is ContentEmbed || _right.content is ContentString) {
      if (!_right.deleted) {
        if (count < _right.length) {
          // split right
          getItemCleanStart(
              transaction, createID(_right.id.client, _right.id.clock + count));
        }
        pos.index += _right.length;
        count -= _right.length;
      }
    } else if (_right.content is ContentFormat) {
      if (!_right.deleted) {
        updateCurrentAttributes(
            pos.currentAttributes,
            /** @type {ContentFormat} */ _right.content as ContentFormat);
      }
    }
    pos.left = pos.right;
    pos.right = _right.right;
    _right = pos.right;
    // pos.forward() - we don't forward because that would halve the performance because we already do the checks above
  }
  return pos;
}

/**
 * @param {Transaction} transaction
 * @param {AbstractType<any>} parent
 * @param {number} index
 * @return {ItemTextListPosition}
 *
 * @private
 * @function
 */
ItemTextListPosition findPosition(Transaction transaction, AbstractType parent,
    int index) {
  final currentAttributes = <String, Object?>{};
  final marker = findMarker(parent, index);
  if (marker != null) {
    final pos = ItemTextListPosition(
        marker.p.left, marker.p, marker.index, currentAttributes);
    return findNextPosition(transaction, pos, index - marker.index);
  } else {
    final pos =
    ItemTextListPosition(null, parent.innerStart, 0, currentAttributes);
    return findNextPosition(transaction, pos, index);
  }
}

/**
 * Negate applied formats
 *
 * @param {Transaction} transaction
 * @param {AbstractType<any>} parent
 * @param {ItemTextListPosition} currPos
 * @param {Map<string,any>} negatedAttributes
 *
 * @private
 * @function
 */
void insertNegatedAttributes(Transaction transaction,
    AbstractType parent,
    ItemTextListPosition currPos,
    Map<String, Object?> negatedAttributes,) {
  // check if we really need to remove attributes
  var _right = currPos.right;
  while (_right != null &&
      (_right.deleted == true ||
          (_right.content is ContentFormat &&
              equalAttrs(
                  negatedAttributes.get(
                    /** @type {ContentFormat} */
                      (_right.content as ContentFormat).key),
                  /** @type {ContentFormat} */ (_right.content as ContentFormat)
                  .value)))) {
    if (!_right.deleted) {
      negatedAttributes.remove(
        /** @type {ContentFormat} */
          (_right.content as ContentFormat).key);
    }
    currPos.forward();
    _right = currPos.right;
  }
  final doc = transaction.doc;
  final ownClientId = doc.clientID;
  negatedAttributes.forEach((key, val) {
    var left = currPos.left;
    var right = currPos.right;
    var nextFormat = Item(
      createID(ownClientId, getState(doc.store, ownClientId)),
      left,
      left?.lastId,
      right,
      right?.id,
      parent,
      null,
      ContentFormat(key, val),
    );
    nextFormat.integrate(transaction, 0);
    currPos.right = nextFormat;
    currPos.forward();
  });
}

/**
 * @param {Map<string,any>} currentAttributes
 * @param {ContentFormat} format
 *
 * @private
 * @function
 */
void updateCurrentAttributes(Map<String, dynamic> currentAttributes,
    ContentFormat format) {
  final key = format.key;
  final value = format.value;
  if (value == null) {
    currentAttributes.remove(key);
  } else {
    currentAttributes.set(key, value);
  }
}

/**
 * @param {ItemTextListPosition} currPos
 * @param {Object<string,any>} attributes
 *
 * @private
 * @function
 */
void minimizeAttributeChanges(ItemTextListPosition currPos,
    Map<String, dynamic> attributes) {
  // go right while attributes[right.key] == right.value (or right is deleted)
  while (true) {
    final _right = currPos.right;
    if (_right == null) {
      break;
    } else if (_right.deleted ||
        (_right.content is ContentFormat &&
            equalAttrs(attributes[(_right.content as ContentFormat).key],
                (_right.content as ContentFormat).value))) {
      //
    } else {
      break;
    }
    currPos.forward();
  }
}

/**
 * @param {Transaction} transaction
 * @param {AbstractType<any>} parent
 * @param {ItemTextListPosition} currPos
 * @param {Object<string,any>} attributes
 * @return {Map<string,any>}
 *
 * @private
 * @function
 **/
Map<String, Object?> insertAttributes(Transaction transaction,
    AbstractType parent,
    ItemTextListPosition currPos,
    Map<String, Object?> attributes) {
  final doc = transaction.doc;
  final ownClientId = doc.clientID;
  final negatedAttributes = <String, Object?>{};
  // insert format-start items
  for (final key in attributes.keys) {
    final val = attributes[key];
    final currentVal = currPos.currentAttributes.get(key);
    if (!equalAttrs(currentVal, val)) {
      // save negated attribute (set null if currentVal undefined)
      negatedAttributes.set(key, currentVal);
      final left = currPos.left;
      final right = currPos.right;
      currPos.right = Item(
        createID(ownClientId, getState(doc.store, ownClientId)),
        left,
        left?.lastId,
        right,
        right?.id,
        parent,
        null,
        ContentFormat(key, val),
      );
      currPos.right!.integrate(transaction, 0);
      currPos.forward();
    }
  }
  return negatedAttributes;
}

/**
 * @param {Transaction} transaction
 * @param {AbstractType<any>} parent
 * @param {ItemTextListPosition} currPos
 * @param {string|object} text
 * @param {Object<string,any>} attributes
 *
 * @private
 * @function
 **/
void _insertText(Transaction transaction,
    AbstractType parent,
    ItemTextListPosition currPos,
    Object text,
    Map<String, Object?> attributes,) {
  currPos.currentAttributes.forEach((key, val) {
    if (!attributes.containsKey(key)) {
      attributes[key] = null;
    }
  });
  final doc = transaction.doc;
  final ownClientId = doc.clientID;
  minimizeAttributeChanges(currPos, attributes);
  final negatedAttributes =
  insertAttributes(transaction, parent, currPos, attributes);
  // insert content
  final content = text is String ? ContentString(/** @type {string} */
      text) : ContentEmbed(text as Map<String, dynamic>);
  final index = currPos.index;
  var right = currPos.right;
  final left = currPos.left;
  if (parent.innerSearchMarker != null &&
      parent.innerSearchMarker!.isNotEmpty) {
    updateMarkerChanges(
        parent.innerSearchMarker!, currPos.index, content.getLength());
  }
  right = Item(
      createID(ownClientId, getState(doc.store, ownClientId)),
      left,
      left?.lastId,
      right,
      right?.id,
      parent,
      null,
      content);
  right.integrate(transaction, 0);
  currPos.right = right;
  currPos.index = index;
  currPos.forward();
  insertNegatedAttributes(transaction, parent, currPos, negatedAttributes);
}

/**
 * @param {Transaction} transaction
 * @param {AbstractType<any>} parent
 * @param {ItemTextListPosition} currPos
 * @param {number} length
 * @param {Object<string,any>} attributes
 *
 * @private
 * @function
 */
void formatText(Transaction transaction,
    AbstractType parent,
    ItemTextListPosition currPos,
    int length,
    Map<String, Object?> attributes,) {
  final doc = transaction.doc;
  final ownClientId = doc.clientID;
  minimizeAttributeChanges(currPos, attributes);
  final negatedAttributes =
  insertAttributes(transaction, parent, currPos, attributes);
  // iterate until first non-format or null is found
  // delete all formats with attributes[format.key] != null
  iterationLoop:
  while (length > 0 &&
      currPos.right != null &&
      (length > 0 ||
          (negatedAttributes.length > 0 &&
              (currPos.right!.deleted ||
                  currPos.right!.content.runtimeType == ContentFormat)))) {
    final _right = currPos.right!;
    if (!_right.deleted) {
      final _content = _right.content;
      if (_content is ContentFormat) {
        final key = /** @type {ContentFormat} */ _content.key;
        final value = /** @type {ContentFormat} */ _content.value;
        final attr = attributes[key];
        if (attributes.containsKey(key)) {
          if (equalAttrs(attr, value)) {
            negatedAttributes.remove(key);
          } else {
            if (length == 0) {
              break iterationLoop;
            }
            negatedAttributes.set(key, value);
          }
          _right.delete(transaction);
        } else {
          currPos.currentAttributes.set(key, value);
        }
      } else {
        if (length < _right.length) {
          getItemCleanStart(transaction,
              createID(_right.id.client, _right.id.clock + length));
        }
        length -= _right.length;
      }
    }
    currPos.forward();
  }
  // Quill just assumes that the editor starts with a newline and that it always
  // ends with a newline. We only insert that newline when a new newline is
  // inserted - i.e when length is bigger than type.length
  if (length > 0) {
    var newlines = "";
    for (; length > 0; length--) {
      newlines += "\n";
    }
    currPos.right = Item(
        createID(ownClientId, getState(doc.store, ownClientId)),
        currPos.left,
        currPos.left?.lastId,
        currPos.right,
        currPos.right?.id,
        parent,
        null,
        ContentString(newlines));
    currPos.right!.integrate(transaction, 0);
    currPos.forward();
  }
  insertNegatedAttributes(transaction, parent, currPos, negatedAttributes);
}

/**
 * Call this function after string content has been deleted in order to
 * clean up formatting Items.
 *
 * @param transaction
 * @param start
 * @param curr exclusive end, automatically iterates to the next Content Item
 * @param startAttributes
 * @param currAttributes
 * @return The amount of formatting Items deleted.
 *
 * @function
 */
int cleanupFormattingGap(Transaction transaction, Item start, Item? curr,
    Map<String, dynamic> startAttributes, Map<String, dynamic> currAttributes) {
  Item? end = start;
  Item? _start = start;
  Map<String, ContentFormat> endFormats = Map<String, ContentFormat>();
  while (end != null && (!end.countable || end.deleted)) {
    if (!end.deleted && end.content is ContentFormat) {
      ContentFormat cf = end.content as ContentFormat;
      endFormats[cf.key] = cf;
    }
    end = end.right;
  }
  int cleanups = 0;
  bool reachedCurr = false;
  while (_start != null && _start != end) {
    if (curr == _start) {
      reachedCurr = true;
    }
    if (!_start.deleted) {
      var content = _start.content;
      switch (content.runtimeType) {
        case ContentFormat:
          {
            ContentFormat cf = content as ContentFormat;
            var key = cf.key;
            var value = cf.value;
            var startAttrValue = startAttributes[key];
            if (endFormats[key] != content || startAttrValue == value) {
              // Either this format is overwritten or it is not necessary because the attribute already existed.
              _start.delete(transaction);
              cleanups++;
              if (!reachedCurr &&
                  (currAttributes[key]) == value &&
                  startAttrValue != value) {
                if (startAttrValue == null) {
                  currAttributes.remove(key);
                } else {
                  currAttributes.set(key, startAttributes);
                }
              }
            }
            if (!reachedCurr && !_start.deleted) {
              updateCurrentAttributes(currAttributes, cf);
            }
            break;
          }
      }
    }
    _start = _start?.right as Item?;
  }
  return cleanups;
}

/**
 * @param transaction
 * @param item
 */
void cleanupContextlessFormattingGap(Transaction transaction, Item? item) {
  // iterate until item.right is null or content
  while (item != null &&
      item.right != null &&
      (item.right!.deleted || !item.right!.countable)) {
    item = item.right;
  }
  final attrs = Set();
  // iterate back until a content item is found
  while (item != null && (item.deleted || !item.countable)) {
    if (!item.deleted && item.content.runtimeType == ContentFormat) {
      final key = (item.content as ContentFormat).key;
      if (attrs.contains(key)) {
        item.delete(transaction);
      } else {
        attrs.add(key);
      }
    }
    item = item.left;
  }
}

/**
 * This function is experimental and subject to change / be removed.
 *
 * Ideally, we don't need this function at all. Formatting attributes should be cleaned up
 * automatically after each change. This function iterates twice over the complete YText type
 * and removes unnecessary formatting attributes. This is also helpful for testing.
 *
 * This function won't be exported anymore as soon as there is confidence that the YText type works as intended.
 *
 * @param {YText} type
 * @return {number} How many formatting attributes have been cleaned up.
 */
int cleanupYTextFormatting(YText type) {
  var res = 0;
  transact(
    /** @type {Doc} */
      type.doc!, (transaction) {
    var start = /** @type {Item} */ type.innerStart;
    var end = type.innerStart;
    var startAttributes = <String, dynamic>{};
    final currentAttributes = {...startAttributes};
    while (end != null) {
      if (end.deleted == false) {
        if (end.content is ContentFormat) {
          updateCurrentAttributes(
              currentAttributes,
              /** @type {ContentFormat} */ end.content as ContentFormat);
        } else {
          res += cleanupFormattingGap(
              transaction, start!, end, startAttributes, currentAttributes);
          startAttributes = {...currentAttributes};
          start = end;
        }
      }
      end = end.right;
    }
  });
  return res;
}

/**
 * @param {Transaction} transaction
 * @param {ItemTextListPosition} currPos
 * @param {number} length
 * @return {ItemTextListPosition}
 *
 * @private
 * @function
 */
ItemTextListPosition deleteText(Transaction transaction,
    ItemTextListPosition currPos, int length) {
  final startLength = length;
  final startAttrs = {...currPos.currentAttributes};
  final start = currPos.right;
  while (length > 0 && currPos.right != null) {
    final _right = currPos.right!;
    if (_right.deleted == false) {
      if (_right.content is ContentType ||
          _right.content is ContentEmbed ||
          _right.content is ContentString) {
        if (length < _right.length) {
          getItemCleanStart(transaction,
              createID(_right.id.client, _right.id.clock + length));
        }
        length -= _right.length;
        _right.delete(transaction);
      }
    }
    currPos.forward();
  }
  if (start != null) {
    cleanupFormattingGap(
      transaction,
      start,
      currPos.right,
      startAttrs,
      {...currPos.currentAttributes},
    );
  }
  final parent = /** @type {AbstractType<any>} */
  /** @type {Item} */ (currPos.left ?? currPos.right as Item).parent
  as AbstractType;
  if (parent.innerSearchMarker != null &&
      parent.innerSearchMarker!.isNotEmpty) {
    updateMarkerChanges(
        parent.innerSearchMarker!, currPos.index, -startLength + length);
  }
  return currPos;
}

/**
 * The Quill Delta format represents changes on a text document with
 * formatting information. For mor information visit {@link https://quilljs.com/docs/delta/|Quill Delta}
 *
 * @example
 *   {
 *     ops: [
 *       { insert: 'Gandalf', attributes: { bold: true } },
 *       { insert: ' the ' },
 *       { insert: 'Grey', attributes: { color: '#cccccc' } }
 *     ]
 *   }
 *
 */

/**
 * Attributes that can be assigned to a selection of text.
 *
 * @example
 *   {
 *     bold: true,
 *     font-size: '40px'
 *   }
 *
 * @typedef {Object} TextAttributes
 */

/**
 * @typedef {Object} DeltaItem
 * @property {number|undefined} DeltaItem.delete
 * @property {number|undefined} DeltaItem.retain
 * @property {string|undefined} DeltaItem.insert
 * @property {Object<string,any>} DeltaItem.attributes
 */

/**
 * Event that describes the changes on a YText type.
 */
class YTextEvent extends YEvent {
  bool childListChanged = false;
  Set<String> keysChanged = {};
  YChanges? _changes;

  /**
   * @param {YText} ytext
   * @param {Transaction} transaction
   */
  YTextEvent(YText ytext, Transaction transaction, Set<dynamic> subs)
      : super(ytext, transaction) {
    for (var sub in subs) {
      if (sub == null) {
        childListChanged = true;
      } else {
        keysChanged.add(sub);
      }
    }
  }

  @override
  YChanges get changes {
    _changes ??=
        YChanges(added: Set(), deleted: Set(), keys: keys, delta: delta);
    return _changes!;
  }

  List<Map<String, dynamic>>? _delta;

  @override
  List<Map<String, dynamic>> get delta {
    if (_delta == null) {
      final y = target.doc as Doc;
      final delta = <Map<String, dynamic>>[];
      transact(y, (transaction) {
        final currentAttributes = <String, dynamic>{};
        final oldAttributes = <String, dynamic>{};
        var item = target.innerStart;
        String? action;
        final attributes = <String, dynamic>{};
        dynamic insert = '';
        var retain = 0;
        var deleteLen = 0;
        void addOp() {
          if (action != null) {
            Map<String, dynamic>? op;
            switch (action) {
              case 'delete':
                if (deleteLen > 0) {
                  op = {'delete': deleteLen};
                }
                deleteLen = 0;
                break;
              case 'insert':
                if (insert is Map<String, dynamic> || insert.length > 0) {
                  op = {'insert': insert};
                  if (currentAttributes.isNotEmpty) {
                    op['attributes'] = <String, dynamic>{};
                    currentAttributes.forEach((key, value) {
                      if (value != null) {
                        op!['attributes']![key] = value;
                      }
                    });
                  }
                }
                insert = '';
                break;
              case 'retain':
                if (retain > 0) {
                  op = {'retain': retain};
                  if (attributes.isNotEmpty) {
                    op['attributes'] = Map<String, dynamic>.from(attributes);
                  }
                }
                retain = 0;
                break;
            }
            if (op != null) {
              delta.add(op);
            }
            action = null;
          }
        }

        while (item != null) {
          switch (item.content.runtimeType) {
            case ContentType:
            case ContentEmbed:
              if (adds(item)) {
                if (!deletes(item)) {
                  addOp();
                  action = 'insert';
                  insert = item.content.getContent()[0];
                  addOp();
                }
              } else if (deletes(item)) {
                if (action != 'delete') {
                  addOp();
                  action = 'delete';
                }
                deleteLen += 1;
              } else if (!item.deleted) {
                if (action != 'retain') {
                  addOp();
                  action = 'retain';
                }
                retain += 1;
              }
              break;
            case ContentString:
              if (adds(item)) {
                if (!deletes(item)) {
                  if (action != 'insert') {
                    addOp();
                    action = 'insert';
                  }
                  insert += (item.content as ContentString).str;
                }
              } else if (deletes(item)) {
                if (action != 'delete') {
                  addOp();
                  action = 'delete';
                }
                deleteLen += item.length;
              } else if (!item.deleted) {
                if (action != 'retain') {
                  addOp();
                  action = 'retain';
                }
                retain += item.length;
              }
              break;
            case ContentFormat:
              final key = (item.content as ContentFormat).key;
              final value = (item.content as ContentFormat).value;
              if (adds(item)) {
                if (!deletes(item)) {
                  final curVal = currentAttributes[key] ?? null;
                  if (!equalAttrs(curVal, value)) {
                    if (action == 'retain') {
                      addOp();
                    }
                    if (equalAttrs(value, oldAttributes[key] ?? null)) {
                      attributes.remove(key);
                    } else {
                      attributes[key] = value;
                    }
                  } else if (value != null) {
                    item.delete(transaction);
                  }
                }
              } else if (deletes(item)) {
                oldAttributes[key] = value;
                final curVal = currentAttributes[key] ?? null;
                if (!equalAttrs(curVal, value)) {
                  if (action == 'retain') {
                    addOp();
                  }
                  attributes[key] = curVal;
                }
              } else if (!item.deleted) {
                oldAttributes[key] = value;
                final attr = attributes[key];
                if (attr != null) {
                  if (!equalAttrs(attr, value)) {
                    if (action == 'retain') {
                      addOp();
                    }
                    if (value == null) {
                      attributes.remove(key);
                    } else {
                      attributes[key] = value;
                    }
                  } else if (attr != null) {
                    item.delete(transaction);
                  }
                }
              }
              if (!item.deleted) {
                if (action == 'insert') {
                  addOp();
                }
                updateCurrentAttributes(
                    currentAttributes, item.content as ContentFormat);
              }
              break;
          }
          item = item.right;
        }
        addOp();
        while (delta.isNotEmpty) {
          final lastOp = delta.last;
          if (lastOp.containsKey('retain') && lastOp['attributes'] == null) {
            delta.removeLast();
          } else {
            break;
          }
        }
      });
      _delta = delta;
    }
    return _delta!;
  }
}

/**
 * Type that represents text with formatting information.
 *
 * This type replaces y-richtext as this implementation is able to handle
 * block formats (format information on a paragraph), embeds (complex elements
 * like pictures and videos), and text formats (**bold**, *italic*).
 *
 * @extends AbstractType<YTextEvent>
 */
class YText extends AbstractType<YTextEvent> {
  static YText create() => YText();

  /**
   * @param {String} [string] The initial value of the YText.
   */
  YText([String? string]) {
    /**
     * Array of pending operations on this type
     * @type {List<function():void>?}
     */
    this._pending = string != null ? [() => this.insert(0, string)] : [];
  }

  /**
   * @type {List<ArraySearchMarker>}
   */
  @override
  final List<ArraySearchMarker> innerSearchMarker = [];

  List<void Function()>? _pending;

  /**
   * Number of characters of this text type.
   *
   * @type {number}
   */
  int get length {
    return this.innerLength;
  }

  /**
   * @param {Doc} y
   * @param {Item} item
   */
  @override
  innerIntegrate(Doc y, Item? item) {
    super.innerIntegrate(y, item);
    try {
      /** @type {List<function>} */
      (this._pending!).forEach((f) => f());
    } catch (e) {
      logger.e(e);
    }
    this._pending = null;
  }

  @override
  innerCopy() {
    return YText();
  }

  /**
   * @return {YText}
   */
  @override
  clone() {
    final text = YText();
    text.applyDelta(this.toDelta());
    return text;
  }

  /**
   * Creates YTextEvent and calls observers.
   *
   * @param {Transaction} transaction
   * @param {Set<null|string>} parentSubs Keys changed on this type. `null` if list was modified.
   */
  @override
  void innerCallObserver(Transaction transaction, Set<String?> parentSubs) {
    super.innerCallObserver(transaction, parentSubs);
    final event = YTextEvent(this, transaction, parentSubs);
    final doc = transaction.doc;
    callTypeObservers(this, transaction, event);
    // If a remote change happened, we try to cleanup potential formatting duplicates.
    if (!transaction.local) {
      // check if another formatting item was inserted
      var foundFormattingItem = false;
      for (final entry in transaction.afterState.entries) {
        final client = entry.key;
        final afterClock = entry.value;
        final clock = transaction.beforeState.get(client) ?? 0;
        if (afterClock == clock) {
          continue;
        }
        iterateStructs(
            transaction,
            /** @type {List<Item|GC>} */ doc.store.clients.get(client)!,
            clock,
            afterClock, (item) {
          if (!item.deleted &&
              /** @type {Item} */ (item as Item).content is ContentFormat) {
            foundFormattingItem = true;
          }
        });
        if (foundFormattingItem) {
          break;
        }
      }
      if (!foundFormattingItem) {
        iterateDeletedStructs(transaction, transaction.deleteSet, (item) {
          if (item is GC || foundFormattingItem) {
            return;
          }
          if (item is Item &&
              item.parent == this &&
              item.content is ContentFormat) {
            foundFormattingItem = true;
          }
        });
      }
      transact(doc, (t) {
        if (foundFormattingItem) {
          // If a formatting item was inserted, we simply clean the whole type.
          // We need to compute currentAttributes for the current position anyway.
          cleanupYTextFormatting(this);
        } else {
          // If no formatting attribute was inserted, we can make due with contextless
          // formatting cleanups.
          // Contextless: it is not necessary to compute currentAttributes for the affected position.
          iterateDeletedStructs(t, t.deleteSet, (item) {
            if (item is GC) {
              return;
            }
            if (item is Item && item.parent == this) {
              cleanupContextlessFormattingGap(t, item);
            }
          });
        }
      });
    }
  }

  /**
   * Returns the unformatted string representation of this YText type.
   *
   * @public
   */
  @override
  String toString() {
    var str = StringBuffer();
    /**
     * @type {Item|null}
     */
    var n = this.innerStart;
    while (n != null) {
      if (!n.deleted && n.countable && n.content is ContentString) {
        str.write((n.content as ContentString).str);
      }
      n = n.right;
    }
    return str.toString();
  }

  /**
   * Returns the unformatted string representation of this YText type.
   *
   * @return {string}
   * @public
   */
  @override
  String toJSON() {
    return this.toString();
  }

  /**
   * Apply a {@link Delta} on this shared YText type.
   *
   * @param {any} delta The changes to apply on this element.
   * @param {object}  [opts]
   * @param {boolean} [opts.sanitize] Sanitize input delta. Removes ending newlines if set to true.
   *
   *
   * @public
   */
  void applyDelta(List<Map<String, Object?>> delta, {bool sanitize = true}) {
    if (this.doc != null) {
      transact(this.doc!, (transaction) {
        final currPos = ItemTextListPosition(null, this.innerStart, 0, {});
        for (var i = 0; i < delta.length; i++) {
          final op = delta[i];

          if (op["insert"] != null) {
            // Quill assumes that the content starts with an empty paragraph.
            // Yjs/Y.Text assumes that it starts empty. We always hide that
            // there is a newline at the end of the content.
            // If we omit this step, clients will see a different number of
            // paragraphs, but nothing bad will happen.
            Map<String, Object?>? attributes;
            var attr = op["attributes"];
            if (attr != null) {
              var mp = attr as Map;
              attributes = mp.map((key, value) =>
                  MapEntry(key as String, value as Object?));
            }
            final _insert = op["insert"];
            final ins = !sanitize &&
                i == delta.length - 1 &&
                currPos.right == null &&
                _insert is String &&
                _insert[_insert.length - 1] == "\n"
                ? _insert.substring(0, _insert.length - 1)
                : _insert;
            if (ins is! String || ins.length > 0) {
              _insertText(
                transaction,
                this,
                currPos,
                ins!,
                attributes ?? {},
              );
            }
          } else if (op["retain"] != null) {
            Map<String, Object?>? attributes;
            var attr = op["attributes"];
            if (attr != null) {
              var mp = attr as Map;
              attributes = mp.map((key, value) =>
                  MapEntry(key as String, value as Object?));
            }
            formatText(
              transaction,
              this,
              currPos,
              op["retain"] as int,
              attributes ?? {},
            );
          } else if (op["delete"] != null) {
            deleteText(transaction, currPos, op["delete"] as int);
          }
        }
      });
    } else {
      /** @type {List<function>} */
      (this._pending!).add(() => this.applyDelta(delta));
    }
  }

  /**
   * Returns the Delta representation of this YText type.
   *
   * @param {Snapshot} [snapshot]
   * @param {Snapshot} [prevSnapshot]
   * @param {function('removed' | 'added', ID):any} [computeYChange]
   * @return {any} The Delta representation of this type.
   *
   * @public
   */
  //
  /**
   * Returns the Delta representation of this YText type.
   *
   * @param {Snapshot} [snapshot]
   * @param {Snapshot} [prevSnapshot]
   * @param {Function(String, ID): dynamic} [computeYChange]
   * @return {dynamic} The Delta representation of this type.
   *
   * @public
   */
  List<Map<String, Object?>> toDelta(
      [Snapshot? snapshot, Snapshot? prevSnapshot, Function? computeYChange]) {
    /**
     * @type{List<dynamic>}
     */
    List<Map<String, Object?>> resultOps = [];
    final currentAttributes = <String, dynamic>{};
    final doc = this.doc;
    var str = '';
    var n = this.innerStart;

    void packStr() {
      if (str.length > 0) {
        // pack str with attributes to ops
        /**
         * @type {Map<String, dynamic>}
         */
        final attributes = {};
        var addAttributes = false;
        currentAttributes.forEach((key, value) {
          addAttributes = true;
          attributes[key] = value;
        });
        /**
         * @type {Map<String, dynamic>}
         */
        final op = <String, dynamic>{'insert': str};
        if (addAttributes) {
          op['attributes'] = attributes;
        }

        resultOps.add(op);
        str = '';
      }
    }

    void computeDelta() {
      while (n != null) {
        if (isVisible(n!, snapshot) ||
            (prevSnapshot != null && isVisible(n!, prevSnapshot))) {
          switch (n!.content.runtimeType) {
            case ContentString:
              {
                final cur = currentAttributes['ychange'];
                if (snapshot != null && !isVisible(n!, snapshot)) {
                  if (cur == null ||
                      cur.user != n!.id.client ||
                      cur.type != 'removed') {
                    packStr();
                    currentAttributes['ychange'] = computeYChange != null
                        ? computeYChange('removed', n!.id)
                        : {'type': 'removed'};
                  }
                } else if (prevSnapshot != null &&
                    !isVisible(n!, prevSnapshot)) {
                  if (cur == null ||
                      cur.user != n!.id.client ||
                      cur.type != 'added') {
                    packStr();
                    currentAttributes['ychange'] = computeYChange != null
                        ? computeYChange('added', n!.id)
                        : {'type': 'added'};
                  }
                } else if (cur != null) {
                  packStr();
                  currentAttributes.remove('ychange');
                }
                str += (n!.content as ContentString).str;
                break;
              }
            case ContentType:
            case ContentEmbed:
              {
                packStr();
                /**
                 * @type {Map<String, dynamic>}
                 */
                final op = {'insert': n!.content.getContent()[0]};
                if (currentAttributes.isNotEmpty) {
                  final attrs = <String, dynamic>{};
                  op['attributes'] = attrs;
                  currentAttributes.forEach((key, value) {
                    attrs[key] = value;
                  });
                }
                resultOps.add(op);
                break;
              }
            case ContentFormat:
              if (isVisible(n!, snapshot)) {
                packStr();
                updateCurrentAttributes(
                    currentAttributes, n!.content as ContentFormat);
              }
              break;
          }
        }
        n = n!.right;
      }
      packStr();
    }

    if (snapshot != null || prevSnapshot != null) {
      // snapshots are merged again after the transaction, so we need to keep the
      // transaction alive until we are done
      transact(doc!, (transaction) {
        if (snapshot != null) {
          splitSnapshotAffectedStructs(transaction, snapshot);
        }
        if (prevSnapshot != null) {
          splitSnapshotAffectedStructs(transaction, prevSnapshot);
        }
        computeDelta();
      }, 'cleanup');
    } else {
      computeDelta();
    }
    return resultOps;
  }

  /**
   * Insert text at a given index.
   *
   * @param {number} index The index at which to start inserting.
   * @param {String} text The text to insert at the specified position.
   * @param {TextAttributes} [attributes] Optionally define some formatting
   *                                    information to apply on the inserted
   *                                    Text.
   * @public
   */
  void insert(int index,
      String text, [
        Map<String, Object?>? _attributes,
      ]) {
    if (text.length <= 0) {
      return;
    }
    final y = this.doc;
    if (y != null) {
      transact(y, (transaction) {
        final pos = findPosition(transaction, this, index);
        final Map<String, Object?> attributes;
        if (_attributes == null) {
          attributes = {};
          // @ts-ignore
          pos.currentAttributes.forEach((k, v) {
            attributes[k] = v;
          });
        } else {
          attributes = {..._attributes};
        }
        _insertText(transaction, this, pos, text, attributes);
      });
    } else {
      /** @type {List<function>} */
      (this._pending!).add(() => this.insert(index, text, _attributes));
    }
  }

  /**
   * Inserts an embed at a index.
   *
   * @param {number} index The index to insert the embed at.
   * @param {Object} embed The Object that represents the embed.
   * @param {TextAttributes} attributes Attribute information to apply on the
   *                                    embed
   *
   * @public
   */
  void insertEmbed(int index,
      Map<String, dynamic> embed, [
        Map<String, Object?>? attributes,
      ]) {
    // if (embed.constructor != Object) {
    //   throw  Exception("Embed must be an Object");
    // }
    attributes = attributes == null ? {} : {...attributes};
    final y = this.doc;
    if (y != null) {
      transact(y, (transaction) {
        final pos = findPosition(transaction, this, index);
        _insertText(transaction, this, pos, embed, attributes!);
      });
    } else {
      /** @type {List<function>} */
      (this._pending!).add(() => this.insertEmbed(index, embed, attributes));
    }
  }

  /**
   * Deletes text starting from an index.
   *
   * @param {number} index Index at which to start deleting.
   * @param {number} length The number of characters to remove. Defaults to 1.
   *
   * @public
   */
  void delete(int index, int length) {
    if (length == 0) {
      return;
    }
    final y = this.doc;
    if (y != null) {
      transact(y, (transaction) {
        deleteText(transaction, findPosition(transaction, this, index), length);
      });
    } else {
      /** @type {List<function>} */
      (this._pending!).add(() => this.delete(index, length));
    }
  }

  /**
   * Assigns properties to a range of text.
   *
   * @param {number} index The position where to start formatting.
   * @param {number} length The amount of characters to assign properties to.
   * @param {TextAttributes} attributes Attribute information to apply on the
   *                                    text.
   *
   * @public
   */
  void format(int index, int length, Map<String, Object?> attributes) {
    if (length == 0) {
      return;
    }
    final y = this.doc;
    if (y != null) {
      transact(y, (transaction) {
        final pos = findPosition(transaction, this, index);
        if (pos.right == null) {
          return;
        }
        formatText(transaction, this, pos, length, attributes);
      });
    } else {
      /** @type {List<function>} */
      (this._pending!).add(() => this.format(index, length, attributes));
    }
  }

  /**
   * Removes an attribute.
   *
   * @note Xml-Text nodes don't have attributes. You can use this feature to assign properties to complete text-blocks.
   *
   * @param {String} attributeName The attribute name that is to be removed.
   *
   * @public
   */
  void removeAttribute(String attributeName) {
    if (this.doc != null) {
      transact(this.doc!, (transaction) {
        typeMapDelete(transaction, this, attributeName);
      });
    } else {
      (this._pending as List<Function>).add(() =>
          this.removeAttribute(attributeName));
    }
  }

  /**
   * Sets or updates an attribute.
   *
   * @note Xml-Text nodes don't have attributes. You can use this feature to assign properties to complete text-blocks.
   *
   * @param attributeName The attribute name that is to be set.
   * @param attributeValue The attribute value that is to be set.
   *
   * @public
   */
  void setAttribute(String attributeName, dynamic attributeValue) {
    if (this.doc != null) {
      transact(this.doc!, (transaction) {
        typeMapSet(transaction, this, attributeName, attributeValue);
      });
    } else {
      (this._pending as List<Function>).add(() =>
          this.setAttribute(attributeName, attributeValue));
    }
  }

  /**
   * Returns an attribute value that belongs to the attribute name.
   *
   * @note Xml-Text nodes don't have attributes. You can use this feature to assign properties to complete text-blocks.
   *
   * @param {String} attributeName The attribute name that identifies the
   *                               queried value.
   * @return {dynamic} The queried attribute value.
   *
   * @public
   */
  dynamic getAttribute(String attributeName) {
    return typeMapGet(this, attributeName);
  }

  /**
   * Returns all attribute name/value pairs in a JSON Object.
   *
   * @note Xml-Text nodes don't have attributes. You can use this feature to assign properties to complete text-blocks.
   *
   * @return {Map<String, dynamic>} A JSON Object that describes the attributes.
   *
   * @public
   */
  Map<String, dynamic> getAttributes() {
    return typeMapGetAll(this);
  }

  /**
   * @param {AbstractUpdateEncoder} encoder
   */
  @override
  void innerWrite(AbstractUpdateEncoder encoder) {
    encoder.writeTypeRef(YTextRefID);
  }
}

/**
 * @param {AbstractUpdateDecoder} decoder
 * @return {YText}
 *
 * @private
 * @function
 */
YText readYText(AbstractUpdateDecoder decoder) => YText();
