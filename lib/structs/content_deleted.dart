import 'package:flutter_crdt/structs/item.dart';
import 'package:flutter_crdt/utils/delete_set.dart';
import 'package:flutter_crdt/utils/update_decoder.dart';

class ContentDeleted implements AbstractContent {
  
  ContentDeleted(this.len);
  int len;

  
  @override
  getLength() {
    return this.len;
  }

  
  @override
  getContent() {
    return [];
  }

  
  @override
  isCountable() {
    return false;
  }

  
  @override
  copy() {
    return ContentDeleted(this.len);
  }

  
  @override
  splice(offset) {
    final right = ContentDeleted(this.len - offset);
    this.len = offset;
    return right;
  }

  
  @override
  mergeWith(right) {
    if (right is ContentDeleted) {
      this.len += right.len;
      return true;
    } else {
      return false;
    }
  }

  
  @override
  integrate(transaction, item) {
    addToDeleteSet(
        transaction.deleteSet, item.id.client, item.id.clock, this.len);
    item.markDeleted();
  }

  
  @override
  delete(transaction) {}
  
  @override
  gc(store) {}
  
  @override
  write(encoder, offset) {
    encoder.writeLen(this.len - offset);
  }

  
  @override
  getRef() {
    return 1;
  }
}


ContentDeleted readContentDeleted(AbstractUpdateDecoder decoder) {
  return ContentDeleted(decoder.readLen());
}
