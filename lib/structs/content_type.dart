import 'package:flutter_crdt/structs/item.dart';
import 'package:flutter_crdt/types/abstract_type.dart';
import 'package:flutter_crdt/types/y_array.dart' show readYArray;
import 'package:flutter_crdt/types/y_map.dart';
import 'package:flutter_crdt/types/y_text.dart';
import 'package:flutter_crdt/utils/update_decoder.dart';

const List<AbstractType Function(AbstractUpdateDecoder)> typeRefs = [
  readYArray,
  readYMap,
  readYText,
];

const YArrayRefID = 0;
const YMapRefID = 1;
const YTextRefID = 2;
const YXmlElementRefID = 3;
const YXmlFragmentRefID = 4;
const YXmlHookRefID = 5;
const YXmlTextRefID = 6;

class ContentType implements AbstractContent {
  
  ContentType(this.type);
  
  final AbstractType type;

  
  @override
  getLength() {
    return 1;
  }

  
  @override
  getContent() {
    return [this.type];
  }

  
  @override
  isCountable() {
    return true;
  }

  
  @override
  copy() {
    return ContentType(this.type.innerCopy());
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
    this.type.innerIntegrate(transaction.doc, item);
  }

  
  @override
  delete(transaction) {
    var item = this.type.innerStart;
    while (item != null) {
      if (!item.deleted) {
        item.delete(transaction);
      } else {
        // Whis will be gc'd later and we want to merge it if possible
        // We try to merge all deleted items after each transaction,
        // but we have no knowledge about that this needs to be merged
        // since it is not in transaction.ds. Hence we add it to transaction._mergeStructs
        transaction.mergeStructs.add(item);
      }
      item = item.right;
    }
    this.type.innerMap.values.forEach((item) {
      if (!item.deleted) {
        item.delete(transaction);
      } else {
        // same as above
        transaction.mergeStructs.add(item);
      }
    });
    transaction.changed.remove(this.type);
  }

  
  @override
  gc(store) {
    var item = this.type.innerStart;
    while (item != null) {
      item.gc(store, true);
      item = item.right;
    }
    this.type.innerStart = null;
    this.type.innerMap.values.forEach(
         (item) {
      Item? _item = item;
      while (_item != null) {
        _item.gc(store, true);
        _item = _item.left;
      }
    });
    this.type.innerMap = {};
  }

  
  @override
  write(encoder, offset) {
    this.type.innerWrite(encoder);
  }

  
  @override
  getRef() {
    return 7;
  }
}


ContentType readContentType(AbstractUpdateDecoder decoder) =>
    ContentType(typeRefs[decoder.readTypeRef()](decoder));
