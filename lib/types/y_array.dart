import 'dart:collection';

import 'package:flutter_crdt/structs/content_type.dart';
import 'package:flutter_crdt/structs/item.dart';
import 'package:flutter_crdt/types/abstract_type.dart';
import 'package:flutter_crdt/utils/doc.dart';
import 'package:flutter_crdt/utils/transaction.dart';
import 'package:flutter_crdt/utils/update_decoder.dart';
import 'package:flutter_crdt/utils/update_encoder.dart';


import 'package:flutter_crdt/utils/y_event.dart';

class YArrayEvent<T> extends YEvent {

  YArrayEvent(YArray<T> target, Transaction transaction)
      : _transaction = transaction,
        super(target, transaction);

  final Transaction _transaction;
}


class YArray<T> extends AbstractType<YArrayEvent<T>> with IterableMixin<T> {
  YArray();

  static YArray<T> create<T>() => YArray<T>();


  List<T>? _prelimContent = [];


  @override
  List<ArraySearchMarker>? innerSearchMarker = [];


  static YArray<T> from<T>(List<T> items) {
    final a = YArray<T>();
    a.push(items);
    return a;
  }


  @override
  void innerIntegrate(Doc y, Item? item) {
    super.innerIntegrate(y, item);
    this.insert(0,  this._prelimContent!);
    this._prelimContent = null;
  }

  @override
  YArray<T> innerCopy() {
    return YArray();
  }


  @override
  YArray<T> clone() {
    final arr = YArray<T>();
    arr.insert(
        0,
        this
            .toArray()
            .map((el) => el is AbstractType ? el.clone() : el)
            .toList()
            .cast());
    return arr;
  }

  @override
  int get length {
    return this._prelimContent == null
        ? this.innerLength
        : this._prelimContent!.length;
  }

  @override
  bool get isEmpty {
    return length == 0;
  }

  @override
  bool get isNotEmpty {
    return length != 0;
  }


  @override
  void innerCallObserver(Transaction transaction, Set<String?> parentSubs) {
    super.innerCallObserver(transaction, parentSubs);
    callTypeObservers(this, transaction, YArrayEvent(this, transaction));
  }

  /**
   * Inserts new content at an index.
   *
   * Important: This function expects an array of content. Not just a content
   * object. The reason for this "weirdness" is that inserting several elements
   * is very efficient when it is done as a single operation.
   *
   * @example
   *  // Insert character 'a' at position 0
   *  yarray.insert(0, ['a'])
   *  // Insert numbers 1, 2 at position 1
   *  yarray.insert(1, [1, 2])
   *
   * @param {number} index The index to insert content at.
   * @param {List<T>} content The array of content
   */
  void insert(int index, List<T> content) {
    if (this.doc != null) {
      transact(this.doc!, (transaction) {
        typeListInsertGenerics(transaction, this, index, content);
      });
    } else {

      (this._prelimContent!).insertAll(index, content);
    }
  }


  void push(List<T> content) {
    this.insert(this.innerLength, content);
  }


  void unshift(List<T> content) {
    this.insert(0, content);
  }


  void delete(int index, [int length = 1]) {
    if (this.doc != null) {
      transact(this.doc!, (transaction) {
        typeListDelete(transaction, this, index, length);
      });
    } else {

      (this._prelimContent!)
          .removeRange(index, index + length);
    }
  }


  T get(int index) {
    return typeListGet(this, index) as T;
  }


  List<T> toArray() {
    return typeListToArray(this).cast();
  }


  List<T> slice([int start = 0, int? end]) {
    return typeListSlice(this, start, end ?? this.innerLength).cast();
  }


  @override
  List<dynamic> toJSON() {
    return this.map((c) => c is AbstractType ? c.toJSON() : c).toList();
  }

  // /**
  //  * Returns an Array with the result of calling a provided function on every
  //  * element of this YArray.
  //  *
  //  * @template T,M
  //  * @param {function(T,number,YList<T>):M} f Function that produces an element of the new Array
  //  * @return {List<M>} A new array with each element being the result of the
  //  *                 callback function
  //  */
  // List<M> map<M>(M Function(T, int, YArray<T>) f) {
  //   return typeListMap<T, M, YArray<T>>(this,  (f));
  // }

  // /**
  //  * Executes a provided function on once on overy element of this YArray.
  //  *
  //  * @param {function(T,number,YList<T>):void} f A function to execute on every element of this YArray.
  //  */
  // void forEach(void Function(T, int, YArray<T>) f) {
  //   typeListForEach(this, f);
  // }


  @override
  Iterator<T> get iterator {
    return typeListCreateIterator<T>(this);
  }


  @override
  void innerWrite(AbstractUpdateEncoder encoder) {
    encoder.writeTypeRef(YArrayRefID);
  }
}


YArray<T> readYArray<T>(AbstractUpdateDecoder decoder) => YArray<T>();
