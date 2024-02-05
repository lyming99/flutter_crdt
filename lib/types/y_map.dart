import 'package:flutter_crdt/structs/content_type.dart';
import 'package:flutter_crdt/structs/item.dart';
import 'package:flutter_crdt/types/abstract_type.dart';
import 'package:flutter_crdt/utils/doc.dart';
import 'package:flutter_crdt/utils/transaction.dart';
import 'package:flutter_crdt/utils/update_decoder.dart';
import 'package:flutter_crdt/utils/update_encoder.dart';

import 'package:flutter_crdt/utils/y_event.dart';
import 'package:flutter_crdt/y_crdt_base.dart';

class YMapEvent<T> extends YEvent {
  YMapEvent(YMap<T> ymap, Transaction transaction, this.keysChanged)
      : super(ymap, transaction);
  final Set<String?> keysChanged;
}

class YMap<T> extends AbstractType<YMapEvent<T>> {
  static YMap<T> create<T>() => YMap<T>();

  YMap([Iterable<MapEntry<String, T>>? _prelimContent]) {
    if (_prelimContent == null) {
      this._prelimContent = {};
    } else {
      this._prelimContent = Map.fromEntries(_prelimContent);
    }
  }

  Map<String, T>? _prelimContent;

  @override
  void innerIntegrate(Doc y, Item? item) {
    super.innerIntegrate(y, item);
    (this._prelimContent!)
        .forEach((key, value) {
      this.set(key, value);
    });
    this._prelimContent = null;
  }

  @override
  YMap<T> innerCopy() {
    return YMap<T>();
  }

  @override
  YMap<T> clone() {
    final map = YMap<T>();
    this.forEach((value, key, _) {
      map.set(key, value is AbstractType ? value.clone() as T : value);
    });
    return map;
  }

  @override
  void innerCallObserver(Transaction transaction, Set<String?> parentSubs) {
    callTypeObservers<YMapEvent<T>>(
      this,
      transaction,
      YMapEvent<T>(this, transaction, parentSubs),
    );
  }

  @override
  Map<String, Object?> toJSON() {
    final map = <String, Object?>{};
    this.innerMap.forEach((key, item) {
      if (!item.deleted) {
        final v = item.content.getContent()[item.length - 1] as T;
        map[key] = v is AbstractType ? v.toJSON() : v;
      }
    });
    return map;
  }

  int get size {
    return [...createMapIterator(this.innerMap)].length;
  }

  Iterable<String> keys() {
    return createMapIterator(this.innerMap).map((e) => e.key);
  }

  
  Iterable<T> values() {
    return createMapIterator(this.innerMap).map(
          (v) => v.value.content.getContent()[v.value.length - 1] as T,
    );
  }

  
  Iterable<MapEntry<String, T>> entries() {
    return createMapIterator(this.innerMap).map(
      
          (v) =>
          MapEntry(
            v.key,
            v.value.content.getContent()[v.value.length - 1] as T,
          ),
    );
  }

  
  void forEach(void Function(T, String, YMap<T>) f) {
    this.innerMap.forEach((key, item) {
      if (!item.deleted) {
        f(item.content.getContent()[item.length - 1] as T, key, this);
      }
    });
  }

  
  // [Symbol.iterator]() {
  //   return this.entries();
  // }

  
  void delete(String key) {
    final doc = this.doc;
    if (doc != null) {
      transact(doc, (transaction) {
        typeMapDelete(transaction, this, key);
      });
    } else {
      
      (this._prelimContent!).remove(key);
    }
  }

  
  T set(String key, T value) {
    final doc = this.doc;
    if (doc != null) {
      transact(doc, (transaction) {
        typeMapSet(transaction, this, key, value);
      });
    } else {
      
      (this._prelimContent!).set(key, value);
    }
    return value;
  }

  
  T? get(String key) {
    final doc = this.doc;
    if (doc != null) {
      return  typeMapGet(this, key) as T?;
    } else {
      return this._prelimContent?[key];
    }
  }

  
  bool has(String key) {
    return typeMapHas(this, key);
  }

  
  @override
  void innerWrite(AbstractUpdateEncoder encoder) {
    encoder.writeTypeRef(YMapRefID);
  }
}


YMap<T> readYMap<T>(AbstractUpdateDecoder decoder) => YMap<T>();
