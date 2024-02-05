import 'package:flutter_crdt/structs/item.dart';
import 'package:flutter_crdt/utils/struct_store.dart';
import 'package:flutter_crdt/utils/transaction.dart';
import 'package:flutter_crdt/utils/update_decoder.dart';
import 'package:flutter_crdt/utils/update_encoder.dart';

class ContentAny implements AbstractContent {
  
  ContentAny(this.arr);
  List<dynamic> arr;

  
  @override
  int getLength() {
    return this.arr.length;
  }

  
  @override
  List<dynamic> getContent() {
    return this.arr;
  }

  
  @override
  bool isCountable() {
    return true;
  }

  
  @override
  ContentAny copy() {
    return ContentAny(this.arr);
  }

  
  @override
  ContentAny splice(int offset) {
    final right = ContentAny(this.arr.sublist(offset));
    this.arr = this.arr.sublist(0, offset);
    return right;
  }

  
  @override
  bool mergeWith(AbstractContent right) {
    if (right is ContentAny) {
      this.arr = [...this.arr, ...right.arr];
      return true;
    } else {
      return false;
    }
  }

  
  @override
  void integrate(transaction, item) {}
  
  @override
  void delete(Transaction transaction) {}
  
  @override
  void gc(StructStore store) {}
  
  @override
  void write(AbstractUpdateEncoder encoder, int offset) {
    final len = this.arr.length;
    encoder.writeLen(len - offset);
    for (var i = offset; i < len; i++) {
      final c = this.arr[i];
      encoder.writeAny(c);
    }
  }

  
  @override
  int getRef() {
    return 8;
  }
}


ContentAny readContentAny(AbstractUpdateDecoder decoder) {
  final len = decoder.readLen();
  final cs = [];
  for (var i = 0; i < len; i++) {
    cs.add(decoder.readAny());
  }
  return ContentAny(cs);
}
