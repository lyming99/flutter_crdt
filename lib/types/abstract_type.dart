import 'dart:math' as math;

import 'dart:typed_data';

import 'package:flutter_crdt/structs/content_any.dart';
import 'package:flutter_crdt/structs/content_binary.dart';
import 'package:flutter_crdt/structs/content_doc.dart';
import 'package:flutter_crdt/structs/content_type.dart';
import 'package:flutter_crdt/structs/item.dart';
import 'package:flutter_crdt/utils/doc.dart';
import 'package:flutter_crdt/utils/event_handler.dart';
import 'package:flutter_crdt/utils/id.dart';
import 'package:flutter_crdt/utils/snapshot.dart';
import 'package:flutter_crdt/utils/struct_store.dart';
import 'package:flutter_crdt/utils/transaction.dart';
import 'package:flutter_crdt/utils/update_encoder.dart';
import 'package:flutter_crdt/utils/y_event.dart';
import 'package:flutter_crdt/y_crdt_base.dart';

const maxSearchMarker = 80;

int globalSearchMarkerTimestamp = 0;

class ArraySearchMarker {
  
  ArraySearchMarker(this.p, this.index)
      : timestamp = globalSearchMarkerTimestamp++ {
    p.marker = true;
  }

  Item p;
  int index;
  int timestamp;
}


void refreshMarkerTimestamp(ArraySearchMarker marker) {
  marker.timestamp = globalSearchMarkerTimestamp++;
}


void overwriteMarker(ArraySearchMarker marker, Item p, int index) {
  marker.p.marker = false;
  marker.p = p;
  p.marker = true;
  marker.index = index;
  marker.timestamp = globalSearchMarkerTimestamp++;
}


ArraySearchMarker markPosition(List<ArraySearchMarker> searchMarker, Item p,
    int index) {
  if (searchMarker.length >= maxSearchMarker) {
    // override oldest marker (we don't want to create more objects)
    final marker =
    searchMarker.reduce((a, b) => a.timestamp < b.timestamp ? a : b);
    overwriteMarker(marker, p, index);
    return marker;
  } else {
    // create new marker
    final pm = ArraySearchMarker(p, index);
    searchMarker.add(pm);
    return pm;
  }
}


ArraySearchMarker? findMarker(AbstractType yarray, int index) {
  final _searchMarker = yarray.innerSearchMarker;
  if (yarray.innerStart == null || index == 0 || _searchMarker == null) {
    return null;
  }
  final marker = _searchMarker.length == 0
      ? null
      : _searchMarker.reduce(
          (a, b) => (index - a.index).abs() < (index - b.index).abs() ? a : b);
  var p = yarray.innerStart;
  var pindex = 0;
  if (marker != null) {
    p = marker.p;
    pindex = marker.index;
    refreshMarkerTimestamp(marker); // we used it, we might need to use it again
  }
  // iterate to right if possible
  if (p == null) {
    throw Exception("");
  }
  while (p != null && p.right != null && pindex < index) {
    if (!p.deleted && p.countable) {
      if (index < pindex + p.length) {
        break;
      }
      pindex += p.length;
    }
    p = p.right;
  }
  // iterate to left if necessary (might be that pindex > index)
  var pLeft = p?.left;
  while (pLeft != null && pindex > index) {
    p = pLeft;
    pLeft = p.left;
    if (!p.deleted && p.countable) {
      pindex -= p.length;
    }
  }
  // we want to make sure that p can't be merged with left, because that would screw up everything
  // in that cas just return what we have (it is most likely the best marker anyway)
  // iterate to left until p can't be merged with left
  pLeft = p?.left;
  while (p != null &&
      pLeft != null &&
      pLeft.id.client == p.id.client &&
      pLeft.id.clock + pLeft.length == p.id.clock) {
    p = pLeft;
    pLeft = p.left;
    if (!p.deleted && p.countable) {
      pindex -= p.length;
    }
  }

  // @todo remove!
  // assure position
  // {
  //   var start = yarray._start
  //   var pos = 0
  //   while (start != p) {
  //     if (!start.deleted && start.countable) {
  //       pos += start.length
  //     }
  //     start =  (start.right)
  //   }
  //   if (pos != pindex) {
  //     debugger
  //     throw new Error('Gotcha position fail!')
  //   }
  // }
  // if (marker) {
  //   if (window.lengthes == null) {
  //     window.lengthes = []
  //     window.getLengthes = () => window.lengthes.sort((a, b) => a - b)
  //   }
  //   window.lengthes.push(marker.index - pindex)
  //   console.log('distance', marker.index - pindex, 'len', p && p.parent.length)
  // }
  if (p == null) {
    throw Exception("");
  }
  if (marker != null &&
      (marker.index - pindex).abs() <
           (p.parent as AbstractType)
          .innerLength /
          maxSearchMarker) {
    // adjust existing marker
    overwriteMarker(marker, p, pindex);
    return marker;
  } else {
    // create new marker
    return markPosition(yarray.innerSearchMarker!, p, pindex);
  }
}


void updateMarkerChanges(List<ArraySearchMarker> searchMarker, int index,
    int len) {
  for (var i = searchMarker.length - 1; i >= 0; i--) {
    final m = searchMarker[i];
    if (len > 0) {
      
      Item? p = m.p;
      p.marker = false;
      // Ideally we just want to do a simple position comparison, but this will only work if
      // search markers don't point to deleted items for formats.
      // Iterate marker to prev undeleted countable position so we know what to do when updating a position
      while (p != null && (p.deleted || !p.countable)) {
        p = p.left;
        if (p != null && !p.deleted && p.countable) {
          // adjust position. the loop should break now
          m.index -= p.length;
        }
      }
      if (p == null || p.marker == true) {
        // remove search marker if updated position is null or if position is already marked
        searchMarker.removeAt(i);
        continue;
      }
      m.p = p;
      p.marker = true;
    }
    if (index < m.index || (len > 0 && index == m.index)) {
      // a simple index <= m.index check would actually suffice
      m.index = math.max(index, m.index + len);
    }
  }
}


List<Item> getTypeChildren(AbstractType t) {
  var s = t.innerStart;
  final arr = <Item>[];
  while (s != null) {
    arr.add(s);
    s = s.right;
  }
  return arr;
}


void callTypeObservers<EventType extends YEvent>(AbstractType<EventType> type,
    Transaction transaction, EventType event) {
  final changedType = type;
  final changedParentTypes = transaction.changedParentTypes;

  AbstractType<YEvent> _type = type;
  while (true) {
    // @ts-ignore
    changedParentTypes.putIfAbsent(_type, () => []).add(event);
    if (_type.innerItem == null) {
      break;
    }
    //会不会为空？
    var temp =  (_type.innerItem!.parent
    as AbstractType<YEvent>?);
    if (temp == null) {
      break;
    }
    _type = temp;
  }
  callEventHandlerListeners(changedType._eH, event, transaction);
}


class AbstractType<EventType> {
  static AbstractType<EventType> create<EventType>() =>
      AbstractType<EventType>();

  
  Item? innerItem;

  
  Map<String, Item> innerMap = {};

  
  Item? innerStart;

  
  Doc? doc;
  int innerLength = 0;

  
  final EventHandler<EventType, Transaction> _eH = createEventHandler();

  
  final EventHandler<List<YEvent>, Transaction> innerdEH = createEventHandler();

  
  List<ArraySearchMarker>? innerSearchMarker;

  
  AbstractType? get parent {
    return this.innerItem?.parent as AbstractType?;
  }

  
  void innerIntegrate(Doc y, Item? item) {
    this.doc = y;
    this.innerItem = item;
  }

  
  AbstractType<EventType> innerCopy() {
    throw UnimplementedError();
  }

  
  AbstractType<EventType> clone() {
    throw UnimplementedError();
  }

  
  void innerWrite(AbstractUpdateEncoder encoder) {}

  
  Item? get innerFirst {
    var n = this.innerStart;
    while (n != null && n.deleted) {
      n = n.right;
    }
    return n;
  }

  
  void innerCallObserver(Transaction transaction, Set<String?> parentSubs) {
    if (!transaction.local && (this.innerSearchMarker?.isNotEmpty ?? false)) {
      this.innerSearchMarker!.length = 0;
    }
  }

  
  void observe(void Function(EventType eventType, Transaction transaction) f) {
    addEventHandlerListener(this._eH, f);
  }

  
  void observeDeep(void Function(List<YEvent> eventList, Transaction transaction) f) {
    addEventHandlerListener(this.innerdEH, f);
  }

  
  void unobserve(void Function(EventType eventType, Transaction transaction) f) {
    removeEventHandlerListener(this._eH, f);
  }

  
  void unobserveDeep(void Function(List<YEvent> eventList, Transaction transaction) f) {
    removeEventHandlerListener(this.innerdEH, f);
  }

  
  Object toJSON() {
    return Object();
  }
}


List typeListSlice(AbstractType type, int start, int end) {
  if (start < 0) {
    start = type.innerLength + start;
  }
  if (end < 0) {
    end = type.innerLength + end;
  }
  var len = end - start;
  final cs = <dynamic>[];
  var n = type.innerStart;
  while (n != null && len > 0) {
    if (n.countable && !n.deleted) {
      final c = n.content.getContent();
      if (c.length <= start) {
        start -= c.length;
      } else {
        for (var i = start; i < c.length && len > 0; i++) {
          cs.add(c[i]);
          len--;
        }
        start = 0;
      }
    }
    n = n.right;
  }
  return cs;
}


List typeListToArray(AbstractType type) {
  final cs = <dynamic>[];
  var n = type.innerStart;
  while (n != null) {
    if (n.countable && !n.deleted) {
      final c = n.content.getContent();
      for (var i = 0; i < c.length; i++) {
        cs.add(c[i]);
      }
    }
    n = n.right;
  }
  return cs;
}


List typeListToArraySnapshot(AbstractType type, Snapshot snapshot) {
  final cs = <dynamic>[];
  var n = type.innerStart;
  while (n != null) {
    if (n.countable && isVisible(n, snapshot)) {
      final c = n.content.getContent();
      for (var i = 0; i < c.length; i++) {
        cs.add(c[i]);
      }
    }
    n = n.right;
  }
  return cs;
}


void typeListForEach<L, R extends AbstractType<dynamic>>(R type,
    void Function(L, int, R) f) {
  var index = 0;
  var n = type.innerStart;
  while (n != null) {
    if (n.countable && !n.deleted) {
      final c = n.content.getContent();
      for (var i = 0; i < c.length; i++) {
        f(c[i] as L, index++, type);
      }
    }
    n = n.right;
  }
}


List<R> typeListMap<C, R, T extends AbstractType<dynamic>>(T type,
    R Function(C, int, T) f) {
  
  final result = <R>[];
  typeListForEach<C, T>(type, (c, i, _) {
    result.add(f(c, i, type));
  });
  return result;
}


Iterator<T> typeListCreateIterator<T>(AbstractType type) {
  return TypeListIterator<T>(type.innerStart);
}

class TypeListIterator<T> implements Iterator<T> {
  TypeListIterator(this.n);

  Item? n;
  List<dynamic>? currentContent;
  int currentContentIndex = 0;
  T? _value;

  @override
  T get current => _value as T;

  @override
  bool moveNext() {
    // find some content
    if (currentContent == null) {
      while (n != null && n!.deleted) {
        n = n!.right;
      }
      // check if we reached the end, no need to check currentContent, because it does not exist
      if (n == null) {
        return false;
      }
      // we found n, so we can set currentContent
      currentContent = n!.content.getContent();
      currentContentIndex = 0;
      n = n!.right; // we used the content of n, now iterate to next
    }
    final _currentContent = currentContent!;
    _value = _currentContent[currentContentIndex++] as T;
    // check if we need to empty currentContent
    if (_currentContent.length <= currentContentIndex) {
      currentContent = null;
    }
    return true;
  }
}


void typeListForEachSnapshot(AbstractType type,
    void Function(dynamic, int, AbstractType) f, Snapshot snapshot) {
  var index = 0;
  var n = type.innerStart;
  while (n != null) {
    if (n.countable && isVisible(n, snapshot)) {
      final c = n.content.getContent();
      for (var i = 0; i < c.length; i++) {
        f(c[i], index++, type);
      }
    }
    n = n.right;
  }
}


dynamic typeListGet(AbstractType type, int index) {
  final marker = findMarker(type, index);
  var n = type.innerStart;
  if (marker != null) {
    n = marker.p;
    index -= marker.index;
  }
  for (; n != null; n = n.right) {
    if (!n.deleted && n.countable) {
      if (index < n.length) {
        return n.content.getContent()[index];
      }
      index -= n.length;
    }
  }
}


void typeListInsertGenericsAfter(Transaction transaction,
    AbstractType parent,
    Item? referenceItem,
    List<dynamic> content,) {
  var left = referenceItem;
  final doc = transaction.doc;
  final ownClientId = doc.clientID;
  final store = doc.store;
  final right = referenceItem == null ? parent.innerStart : referenceItem.right;
  
  var jsonContent = <Object>[];
  final packJsonContent = () {
    if (jsonContent.length > 0) {
      left = Item(
          createID(ownClientId, getState(store, ownClientId)),
          left,
          left?.lastId,
          right,
          right?.id,
          parent,
          null,
          ContentAny(jsonContent));
      left!.integrate(transaction, 0);
      jsonContent = [];
    }
  };
  content.forEach((dynamic c) {
    if (c is int ||
        c is double ||
        c is num ||
        c is Map ||
        c is bool ||
        (c is List && c is! Uint8List) ||
        c is String) {
      jsonContent.add(c as Object);
    } else {
      packJsonContent();
      // TODO: or ArrayBuffer
      if (c is Uint8List) {
        left = Item(
          createID(ownClientId, getState(store, ownClientId)),
          left,
          left?.lastId,
          right,
          right?.id,
          parent,
          null,
          ContentBinary(c),
        );
        left!.integrate(transaction, 0);
      } else if (c is Doc) {
        left = Item(
            createID(ownClientId, getState(store, ownClientId)),
            left,
            left?.lastId,
            right,
            right?.id,
            parent,
            null,
            ContentDoc(
                c));
        left!.integrate(transaction, 0);
      } else if (c is AbstractType) {
        left = Item(
            createID(ownClientId, getState(store, ownClientId)),
            left,
            left?.lastId,
            right,
            right?.id,
            parent,
            null,
            ContentType(c));
        left!.integrate(transaction, 0);
      } else {
        throw Exception('Unexpected content type in insert operation');
      }
    }
  });
  packJsonContent();
}


void typeListInsertGenerics(Transaction transaction,
    AbstractType parent,
    int index,
    List<dynamic> content,) {
  if (index == 0) {
    if (parent.innerSearchMarker != null &&
        parent.innerSearchMarker!.isNotEmpty) {
      updateMarkerChanges(parent.innerSearchMarker!, index, content.length);
    }
    return typeListInsertGenericsAfter(transaction, parent, null, content);
  }
  final startIndex = index;
  final marker = findMarker(parent, index);
  var n = parent.innerStart;
  if (marker != null) {
    n = marker.p;
    index -= marker.index;
    // we need to iterate one to the left so that the algorithm works
    if (index == 0) {
      // @todo refactor this as it actually doesn't consider formats
      n = n
          .prev; // important! get the left undeleted item so that we can actually decrease index
      index += (n != null && n.countable && !n.deleted) ? n.length : 0;
    }
  }
  for (; n != null; n = n.right) {
    if (!n.deleted && n.countable) {
      if (index <= n.length) {
        if (index < n.length) {
          // insert in-between
          getItemCleanStart(
              transaction, createID(n.id.client, n.id.clock + index));
        }
        break;
      }
      index -= n.length;
    }
  }
  if (parent.innerSearchMarker != null &&
      parent.innerSearchMarker!.isNotEmpty) {
    updateMarkerChanges(parent.innerSearchMarker!, startIndex, content.length);
  }
  return typeListInsertGenericsAfter(transaction, parent, n, content);
}


void typeListPushGenerics(Transaction transaction, AbstractType parent,
    List<dynamic> content) {
  ArraySearchMarker? marker;
  if (parent.innerSearchMarker == null || parent.innerSearchMarker!.isEmpty) {
    if (parent.innerStart != null) {
      marker = ArraySearchMarker(parent.innerStart!, 0);
    }
  } else {
    marker = (parent.innerSearchMarker ?? []).reduce((maxMarker, currMarker) =>
    currMarker.index > maxMarker.index ? currMarker : maxMarker);
  }
  if (marker != null) {
    typeListInsertGenericsAfter(transaction, parent, marker.p, content);
  }
}


void typeListDelete(Transaction transaction, AbstractType parent, int index,
    int _length) {
  var length = _length;
  if (length == 0) {
    return;
  }
  final startIndex = index;
  final startLength = length;
  final marker = findMarker(parent, index);
  var n = parent.innerStart;
  if (marker != null) {
    n = marker.p;
    index -= marker.index;
  }
  // compute the first item to be deleted
  for (; n != null && index > 0; n = n.right) {
    if (!n.deleted && n.countable) {
      if (index < n.length) {
        getItemCleanStart(
            transaction, createID(n.id.client, n.id.clock + index));
      }
      index -= n.length;
    }
  }
  // delete all items until done
  while (length > 0 && n != null) {
    if (!n.deleted) {
      if (length < n.length) {
        getItemCleanStart(
            transaction, createID(n.id.client, n.id.clock + length));
      }
      n.delete(transaction);
      length -= n.length;
    }
    n = n.right;
  }
  if (length > 0) {
    throw Exception('array length exceeded');
  }
  if (parent.innerSearchMarker != null) {
    updateMarkerChanges(parent.innerSearchMarker!, startIndex,
        -startLength + length /* in case we remove the above exception */);
  }
}


void typeMapDelete(Transaction transaction, AbstractType parent, String key) {
  final c = parent.innerMap.get(key);
  if (c != null) {
    c.delete(transaction);
  }
}


void typeMapSet(Transaction transaction,
    AbstractType parent,
    String key,
    Object? value,) {
  final left = parent.innerMap.get(key);
  final doc = transaction.doc;
  final ownClientId = doc.clientID;
  final AbstractContent content;
  if (value == null) {
    content = ContentAny(<dynamic>[value]);
  } else {
    if (value is int ||
        value is num ||
        value is double ||
        value is Map ||
        value is bool ||
        value is List ||
        value is String) {
      content = ContentAny(<dynamic>[value]);
    } else if (value is Uint8List) {
      content = ContentBinary(
          value);
    } else if (value is Doc) {
      content = ContentDoc(
          value);
    } else {
      if (value is AbstractType) {
        content = ContentType(value);
      } else {
        throw Exception('Unexpected content type');
      }
    }
  }
  Item(
    createID(ownClientId, getState(doc.store, ownClientId)),
    left,
    left?.lastId,
    null,
    null,
    parent,
    key,
    content,
  ).integrate(transaction, 0);
}


dynamic typeMapGet(AbstractType parent, String key) {
  final val = parent.innerMap.get(key);
  return val != null && !val.deleted
      ? val.content.getContent()[val.length - 1]
      : null;
}


dynamic typeMapGetAll(AbstractType parent) {
  
  final res = <String, dynamic>{};
  parent.innerMap.forEach((key, value) {
    if (!value.deleted) {
      res[key] = value.content.getContent()[value.length - 1];
    }
  });
  return res;
}


bool typeMapHas(AbstractType parent, String key) {
  final val = parent.innerMap.get(key);
  return val != null && !val.deleted;
}


dynamic typeMapGetSnapshot(AbstractType parent, String key, Snapshot snapshot) {
  var v = parent.innerMap.get(key);
  while (v != null &&
      (!snapshot.sv.containsKey(v.id.client) ||
          v.id.clock >= (snapshot.sv.get(v.id.client) ?? 0))) {
    v = v.left;
  }
  return v != null && isVisible(v, snapshot)
      ? v.content.getContent()[v.length - 1]
      : null;
}


Iterable<MapEntry<String, Item>> createMapIterator(Map<String, Item> map) =>
    map.entries.where((entry) => !entry.value.deleted);
