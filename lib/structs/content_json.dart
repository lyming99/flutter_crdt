import 'dart:convert';

import 'package:flutter_crdt/structs/item.dart';
import 'package:flutter_crdt/utils/update_decoder.dart';

class ContentJSON implements AbstractContent {
  
  ContentJSON(this.arr);
  
  List<dynamic> arr;

  
  @override
  getLength() {
    return this.arr.length;
  }

  @override
  getContent() {
    return this.arr;
  }

  @override
  isCountable() {
    return true;
  }

  @override
  copy() {
    return ContentJSON(this.arr);
  }

  @override
  splice(offset) {
    final right = ContentJSON(this.arr.sublist(offset));
    this.arr = this.arr.sublist(0, offset);
    return right;
  }

  @override
  mergeWith(right) {
    if (right is ContentJSON) {
      this.arr = [...this.arr, ...right.arr];
      return true;
    } else {
      return false;
    }
  }

  @override
  integrate(transaction, item) {}
  
  @override
  delete(transaction) {}
  
  @override
  gc(store) {}
  
  @override
  write(encoder, offset) {
    final len = this.arr.length;
    encoder.writeLen(len - offset);
    for (var i = offset; i < len; i++) {
      final c = this.arr[i];
      encoder.writeString(c == null ? "undefined" : jsonEncode(c));
    }
  }

  
  @override
  getRef() {
    return 2;
  }
}

ContentJSON readContentJSON(AbstractUpdateDecoder decoder) {
  final len = decoder.readLen();
  final cs = [];
  for (var i = 0; i < len; i++) {
    final c = decoder.readString();
    if (c == "undefined") {
      cs.add(null);
    } else {
      cs.add(jsonDecode(c));
    }
  }
  return ContentJSON(cs);
}
