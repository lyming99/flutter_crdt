import 'package:flutter_crdt/structs/item.dart';
import 'package:flutter_crdt/types/abstract_type.dart';
import 'package:flutter_crdt/utils/update_decoder.dart';

class ContentFormat implements AbstractContent {
  ContentFormat(this.key, this.value);
  final String key;
  final Object? value;

  @override
  getLength() {
    return 1;
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
    return ContentFormat(this.key, this.value);
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
  integrate(transaction, item) {
     (item.parent as AbstractType)
        .innerSearchMarker = null;
  }

  
  @override
  delete(transaction) {}
  
  @override
  gc(store) {}
  
  @override
  write(encoder, offset) {
    encoder.writeKey(this.key);
    encoder.writeJSON(this.value);
  }

  @override
  getRef() {
    return 6;
  }
}

ContentFormat readContentFormat(AbstractUpdateDecoder decoder) =>
    ContentFormat(decoder.readString(), decoder.readJSON());
