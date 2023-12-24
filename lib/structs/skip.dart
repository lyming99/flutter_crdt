import 'package:flutter_crdt/lib0/encoding.dart';
import 'package:flutter_crdt/structs/abstract_struct.dart';
import 'package:flutter_crdt/utils/struct_store.dart';
import 'package:flutter_crdt/utils/transaction.dart';
import 'package:flutter_crdt/utils/update_encoder.dart';

const structSkipRefNumber = 10;

class Skip extends AbstractStruct {
  Skip(super.id, super.length);

  @override
  bool get deleted => true;

  @override
  bool mergeWith(AbstractStruct right) {
    if (this.runtimeType != right.runtimeType) {
      return false;
    }
    this.length += right.length;
    return true;
  }

  @override
  void integrate(Transaction transaction, int offset) {
    throw Exception("");
  }

  @override
  void write(AbstractUpdateEncoder encoder, int offset) {
    encoder.writeInfo(structSkipRefNumber);
    writeVarUint(encoder.restEncoder, this.length - offset);
  }

  int? getMissing(Transaction transaction, StructStore store) {
    return null;
  }
}
