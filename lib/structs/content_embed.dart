import 'package:flutter_crdt/structs/item.dart';
import 'package:flutter_crdt/utils/update_decoder.dart';


class ContentEmbed implements AbstractContent {
  
  ContentEmbed(this.embed);
  final Map<String, dynamic> embed;

  
  @override
  getLength() {
    return 1;
  }

  
  @override
  getContent() {
    return [this.embed];
  }

  
  @override
  isCountable() {
    return true;
  }

  
  @override
  copy() {
    return ContentEmbed(this.embed);
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
    encoder.writeJSON(this.embed);
  }

  
  @override
  getRef() {
    return 5;
  }
}


ContentEmbed readContentEmbed(AbstractUpdateDecoder decoder) =>
    ContentEmbed((decoder.readJSON() as Map).map((key, value) => MapEntry(key as String, value)));