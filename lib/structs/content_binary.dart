import 'dart:typed_data';

import 'package:flutter_crdt/structs/item.dart';
import 'package:flutter_crdt/utils/update_decoder.dart';

class ContentBinary implements AbstractContent {
  
  ContentBinary(this.content);
  final Uint8List content;

  
  @override
  getLength() {
    return 1;
  }

  
  @override
  getContent() {
    return [this.content];
  }

  
  @override
  isCountable() {
    return true;
  }

  
  @override
  copy() {
    return ContentBinary(this.content);
  }

  
  @override
  splice(offset) {
    throw UnimplementedError();
  }

  
  @override
  mergeWith(right) {
    return false;
  }

  
  @override
  integrate(transaction, item) {}
  
  @override
  delete(transaction) {}
  
  @override
  gc(store) {}
  
  @override
  write(encoder, offset) {
    encoder.writeBuf(this.content);
  }

  
  @override
  getRef() {
    return 3;
  }
}


ContentBinary readContentBinary(AbstractUpdateDecoder decoder) =>
    ContentBinary(decoder.readBuf());
