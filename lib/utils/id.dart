import 'package:flutter_crdt/lib0/decoding.dart' as decoding;
import 'package:flutter_crdt/lib0/encoding.dart' as encoding;
// import * as decoding from 'lib0/decoding.js'
// import * as encoding from 'lib0/encoding.js'
// import * as error from 'lib0/error.js'

import 'package:flutter_crdt/types/abstract_type.dart';

class ID {
  ID(this.client, this.clock);

  final int client;

  int clock;

  Map<String, dynamic> toMap() {
    return {
      'client': this.client,
      'clock': this.clock,
    };
  }
}

bool compareIDs(ID? a, ID? b) =>
    a == b ||
    (a != null && b != null && a.client == b.client && a.clock == b.clock);

ID createID(int client, int clock) => ID(client, clock);

void writeID(encoding.Encoder encoder, ID id) {
  encoding.writeVarUint(encoder, id.client);
  encoding.writeVarUint(encoder, id.clock);
}

ID readID(decoding.Decoder decoder) =>
    createID(decoding.readVarUint(decoder), decoding.readVarUint(decoder));

String findRootTypeKey(AbstractType type) {
  for (final entrie in type.doc!.share.entries) {
    if (entrie.value == type) {
      return entrie.key;
    }
  }
  throw Exception('Unexpected case');
}
