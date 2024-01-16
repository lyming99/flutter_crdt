import 'package:flutter_crdt/structs/item.dart';
import 'package:flutter_crdt/types/abstract_type.dart';

bool isParentOf(AbstractType parent, Item? child) {
  while (child != null) {
    if (child.parent == parent) {
      return true;
    }
    child = (child.parent as AbstractType)
        .innerItem;
  }
  return false;
}
