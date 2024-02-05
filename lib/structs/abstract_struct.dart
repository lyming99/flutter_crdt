import 'package:flutter_crdt/utils/id.dart' show ID;
import 'package:flutter_crdt/utils/transaction.dart' show Transaction;
import 'package:flutter_crdt/utils/update_encoder.dart'
    show AbstractUpdateEncoder;

abstract class AbstractStruct {
  
  AbstractStruct(this.id, this.length);
  ID id;
  int length;

  
  bool get deleted;

  
  bool mergeWith(AbstractStruct right) {
    return false;
  }

  
  void write(AbstractUpdateEncoder encoder, int offset);

  
  void integrate(Transaction transaction, int offset);
}
