import 'package:flutter_crdt/utils/doc.dart';
import 'package:flutter_crdt/utils/observable.dart';

class AbstractConnector extends Observable<dynamic> {
  AbstractConnector(this.doc, this.awareness);
  final Doc doc;
  final Object awareness;
}
