import 'package:flutter_crdt/structs/abstract_struct.dart';
import 'package:flutter_crdt/utils/id.dart';
import 'package:flutter_crdt/utils/struct_store.dart';
import 'package:flutter_crdt/utils/transaction.dart';
import 'package:flutter_crdt/utils/update_encoder.dart';

const structGCRefNumber = 0;

class GC extends AbstractStruct {
  GC(ID id, int length) : super(id, length);

  @override
  bool get deleted {
    return true;
  }

  void delete() {}

  @override
  bool mergeWith(AbstractStruct right) {
    if(this.runtimeType!=right.runtimeType){
      return false;
    }
    this.length += right.length;
    return true;
  }

  @override
  void integrate(Transaction transaction, int offset) {
    if (offset > 0) {
      this.id.clock += offset;
      this.length -= offset;
    }
    addStruct(transaction.doc.store, this);
  }

  @override
  void write(AbstractUpdateEncoder encoder, int offset) {
    encoder.writeInfo(structGCRefNumber);
    encoder.writeLen(this.length - offset);
  }

  int? getMissing(Transaction transaction, StructStore store) {
    return null;
  }
}
