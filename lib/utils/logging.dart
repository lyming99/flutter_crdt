import 'package:flutter_crdt/structs/item.dart';
import 'package:flutter_crdt/types/abstract_type.dart';

void logType(AbstractType type) {
  final res = <Item>[];
  var n = type.innerStart;
  while (n != null) {
    res.add(n);
    n = n.right;
  }
  print("Children: $res");
  print(
      "Children content: ${res.where((m) => !m.deleted).map((m) => m.content)}");
}
