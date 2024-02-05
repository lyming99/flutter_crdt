import 'package:flutter_crdt/structs/item.dart';
import 'package:flutter_crdt/utils/doc.dart';
import 'package:flutter_crdt/utils/update_decoder.dart';
import 'package:flutter_crdt/y_crdt_base.dart';

class _Opts {
  bool? gc;
  bool? autoLoad;
  dynamic meta;

  Map<String, dynamic> toMap() {
    return {
      "gc": gc,
      "autoLoad": autoLoad,
      "meta": meta,
    };
  }
}


class ContentDoc implements AbstractContent {
  
  ContentDoc(this.doc) {
    final doc = this.doc;
    if (doc != null) {
      if (doc.item != null) {
        logger.e("This document was already integrated as a sub-document. "
            "You should create a second instance instead with the same guid.");
      }
      if (!doc.gc) {
        opts.gc = false;
      }
      if (doc.autoLoad) {
        opts.autoLoad = true;
      }
      if (doc.meta != null) {
        opts.meta = doc.meta;
      }
    }
  }
  
  Doc? doc;
  

  final opts = _Opts();

  
  @override
  getLength() {
    return 1;
  }

  
  @override
  getContent() {
    return [this.doc];
  }

  
  @override
  isCountable() {
    return true;
  }

  
  @override
  copy() {
    return ContentDoc(this.doc);
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
    // this needs to be reflected in doc.destroy as well
    final doc = this.doc;
    if (doc != null) {
      doc.item = item;
      transaction.subdocsAdded.add(doc);
      if (doc.shouldLoad) {
        transaction.subdocsLoaded.add(doc);
      }
    }
  }

  
  @override
  delete(transaction) {
    if (transaction.subdocsAdded.contains(this.doc)) {
      transaction.subdocsAdded.remove(this.doc);
    } else {
      transaction.subdocsRemoved.add(this.doc!);
    }
  }

  
  @override
  gc(store) {}

  
  @override
  write(encoder, offset) {
    encoder.writeString(this.doc!.guid);
    encoder.writeAny(this.opts.toMap());
  }

  
  @override
  getRef() {
    return 9;
  }
}


ContentDoc readContentDoc(AbstractUpdateDecoder decoder) {
  final guid = decoder.readString();
  final params = decoder.readAny();
  return ContentDoc(
    Doc(
      guid: guid,
      autoLoad: params["autoLoad"] as bool?,
      gc: params["gc"] as bool?,
      gcFilter:
          (params["gcFilter"] ?? Doc.defaultGcFilter) as bool Function(Item),
      meta: params["meta"],
    ),
  );
}
