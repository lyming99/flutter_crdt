import 'package:flutter_crdt/structs/item.dart';
import 'package:flutter_crdt/utils/update_decoder.dart';

class ContentString implements AbstractContent {
  
  ContentString(this.str);
  
  String str;

  @override
  getLength() {
    return this.str.length;
  }

  @override
  getContent() {
    return this.str.split("");
  }

  @override
  isCountable() {
    return true;
  }

  @override
  copy() {
    return ContentString(this.str);
  }

  @override
  splice(offset) {
    final right = ContentString(this.str.substring(offset));
    this.str = this.str.substring(0, offset);

    // Prevent encoding invalid documents because of splitting of surrogate pairs: https://github.com/yjs/yjs/issues/248
    final firstCharCode = this.str.codeUnitAt(offset - 1);
    if (firstCharCode >= 0xd800 && firstCharCode <= 0xdbff) {
      // Last character of the left split is the start of a surrogate utf16/ucs2 pair.
      // We don't support splitting of surrogate pairs because this may lead to invalid documents.
      // Replace the invalid character with a unicode replacement character (� / U+FFFD)
      this.str = this.str.substring(0, offset - 1) + "�";
      // replace right as well
      right.str = "�" + right.str.substring(1);
    }
    return right;
  }

  
  @override
  mergeWith(right) {
    if (right is ContentString) {
      this.str += right.str;
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
    encoder.writeString(offset == 0 ? this.str : this.str.substring(offset));
  }

  
  @override
  getRef() {
    return 4;
  }
}


ContentString readContentString(AbstractUpdateDecoder decoder) =>
    ContentString(decoder.readString());
