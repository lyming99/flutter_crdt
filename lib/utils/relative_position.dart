import 'dart:typed_data';

import 'package:flutter_crdt/lib0/decoding.dart' as decoding;
import 'package:flutter_crdt/lib0/encoding.dart' as encoding;
import 'package:flutter_crdt/structs/content_type.dart';
import 'package:flutter_crdt/structs/item.dart';
import 'package:flutter_crdt/types/abstract_type.dart';
import 'package:flutter_crdt/utils/doc.dart';
import 'package:flutter_crdt/utils/id.dart';
import 'package:flutter_crdt/utils/struct_store.dart';

class RelativePosition {
  RelativePosition(this.type, this.tname, this.item, [this.assoc = 0]);

  ID? type;

  String? tname;

  ID? item;

  int assoc;
}

Map relativePositionToJSON(RelativePosition rpos) {
  final json = {};
  if (rpos.type != null) {
    json['type'] = rpos.type;
  }
  if (rpos.tname != null) {
    json['tname'] = rpos.tname;
  }
  if (rpos.item != null) {
    json['item'] = rpos.item?.toMap();
  }
  json['assoc'] = rpos.assoc;
  return json;
}

RelativePosition createRelativePositionFromJSON(dynamic json) {
  return RelativePosition(
    json['type'] == null
        ? null
        : createID(json['type']['client'], json['type']['clock']),
    json['tname'] ?? null,
    json['item'] == null
        ? null
        : createID(json['item']['client'], json['item']['clock']),
    json['assoc'] == null ? 0 : json['assoc'],
  );
}

class AbsolutePosition {
  AbsolutePosition(this.type, this.index, [this.assoc = 0]);

  final AbstractType type;

  final int index;
  final int assoc;
}

AbsolutePosition createAbsolutePosition(AbstractType type, int index,
        [assoc = 0]) =>
    AbsolutePosition(type, index, assoc);

RelativePosition createRelativePosition(
    AbstractType type, ID? item, int assoc) {
  ID? typeid;
  String? tname;
  final typeItem = type.innerItem;
  if (typeItem == null) {
    tname = findRootTypeKey(type);
  } else {
    typeid = createID(typeItem.id.client, typeItem.id.clock);
  }
  return RelativePosition(typeid, tname, item, assoc);
}

RelativePosition createRelativePositionFromTypeIndex(
    AbstractType type, int index,
    [assoc = 0]) {
  if (assoc < 0) {
    if (index == 0) {
      return createRelativePosition(type, null, assoc);
    }
    index--;
  }
  Item? t = type.innerStart;
  while (t != null) {
    if (!t.deleted && t.countable) {
      if (t.length > index) {
        // case 1: found position somewhere in the linked list
        return createRelativePosition(
            type, createID(t.id.client, t.id.clock + index), assoc);
      }
      index -= t.length;
    }
    if (t.right == null && assoc < 0) {
      return createRelativePosition(type, t.lastId, assoc);
    }
    t = t.right;
  }
  return createRelativePosition(type, null, assoc);
}

encoding.Encoder writeRelativePosition(
    encoding.Encoder encoder, RelativePosition rpos) {
  final type = rpos.type;
  final tname = rpos.tname;
  final item = rpos.item;
  final assoc = rpos.assoc;
  if (item != null) {
    encoding.writeVarUint(encoder, 0);
    writeID(encoder, item);
  } else if (tname != null) {
    // case 2: found position at the end of the list and type is stored in y.share
    encoding.writeUint8(encoder, 1);
    encoding.writeVarString(encoder, tname);
  } else if (type != null) {
    // case 3: found position at the end of the list and type is attached to an item
    encoding.writeUint8(encoder, 2);
    writeID(encoder, type);
  } else {
    throw Exception('Unexpected case');
  }
  encoding.writeVarInt(encoder, assoc);
  return encoder;
}

Uint8List encodeRelativePosition(RelativePosition rpos) {
  final encoder = encoding.createEncoder();
  writeRelativePosition(encoder, rpos);
  return encoding.toUint8Array(encoder);
}

RelativePosition readRelativePosition(decoding.Decoder decoder) {
  ID? type;
  String? tname;
  ID? itemID;
  switch (decoding.readVarUint(decoder)) {
    case 0:
      itemID = readID(decoder);
      break;
    case 1:
      tname = decoding.readVarString(decoder);
      break;
    case 2:
      type = readID(decoder);
  }
  final assoc = decoding.hasContent(decoder) ? decoding.readVarInt(decoder) : 0;
  return RelativePosition(type, tname, itemID, assoc);
}

RelativePosition decodeRelativePosition(Uint8List uint8Array) =>
    readRelativePosition(decoding.createDecoder(uint8Array));

AbsolutePosition? createAbsolutePositionFromRelativePosition(
    RelativePosition rpos, Doc doc) {
  final store = doc.store;
  final rightID = rpos.item;
  final typeID = rpos.type;
  final tname = rpos.tname;
  final assoc = rpos.assoc;
  AbstractType type;
  var index = 0;
  if (rightID != null) {
    if (getState(store, rightID.client) <= rightID.clock) {
      return null;
    }
    final res = followRedone(store, rightID);
    final right = res.item;
    if (right is! Item) {
      return null;
    }
    type = right.parent as AbstractType;
    if (type.innerItem == null || !type.innerItem!.deleted) {
      index = right.deleted || !right.countable
          ? 0
          : (res.diff + (assoc >= 0 ? 0 : 1));
      var n = right.left;
      while (n != null) {
        if (!n.deleted && n.countable) {
          index += n.length;
        }
        n = n.left;
      }
    }
  } else {
    if (tname != null) {
      type = doc.get(tname);
    } else if (typeID != null) {
      if (getState(store, typeID.client) <= typeID.clock) {
        // type does not exist yet
        return null;
      }
      final item = followRedone(store, typeID).item;
      if (item is Item && item.content is ContentType) {
        type = (item.content as ContentType).type;
      } else {
        // struct is garbage collected
        return null;
      }
    } else {
      throw Exception('Unexpected case');
    }
    if (assoc >= 0) {
      index = type.innerLength;
    } else {
      index = 0;
    }
  }
  return createAbsolutePosition(type, index, rpos.assoc);
}

bool compareRelativePositions(RelativePosition? a, RelativePosition? b) =>
    a == b ||
    (a != null &&
            b != null &&
            a.tname == b.tname &&
            compareIDs(a.item, b.item) &&
            compareIDs(a.type, b.type)) &&
        a.assoc == b.assoc;
