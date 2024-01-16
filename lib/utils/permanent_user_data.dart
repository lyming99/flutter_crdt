import 'dart:typed_data';

import 'package:flutter_crdt/lib0/decoding.dart' as decoding;
import 'package:flutter_crdt/types/y_array.dart';
import 'package:flutter_crdt/types/y_map.dart';
import 'package:flutter_crdt/utils/delete_set.dart';
import 'package:flutter_crdt/utils/doc.dart';
import 'package:flutter_crdt/utils/id.dart';
import 'package:flutter_crdt/utils/transaction.dart';
import 'package:flutter_crdt/utils/update_decoder.dart';
import 'package:flutter_crdt/utils/update_encoder.dart';
import 'package:flutter_crdt/y_crdt_base.dart';

bool _defaultFilter(_, __) => true;

class PermanentUserData {
  PermanentUserData(this.doc, [YMap<YMap<dynamic>>? storeType]) {
    this.yusers = storeType ?? doc.getMap<YMap<dynamic>>("users");

    void initUser(YMap<dynamic> user, String userDescription, YMap<dynamic> _) {
      final ds = user.get("ds")! as YArray;
      final ids = user.get("ids")! as YArray;
      final addClientId =
          (int clientid) => this.clients.set(clientid, userDescription);
      ds.observe((event, _) {
        event.changes.added.forEach((item) {
          item.content.getContent().forEach((encodedDs) {
            if (encodedDs is Uint8List) {
              this.dss.set(
                    userDescription,
                    mergeDeleteSets([
                      this.dss.get(userDescription) ?? createDeleteSet(),
                      readDeleteSet(
                          DSDecoderV1(decoding.createDecoder(encodedDs))),
                    ]),
                  );
            }
          });
        });
      });
      this.dss.set(
            userDescription,
            mergeDeleteSets(ds
                .map(
                  (encodedDs) => readDeleteSet(DSDecoderV1(
                    decoding.createDecoder(encodedDs as Uint8List),
                  )),
                )
                .toList()),
          );
      ids.observe((event, _) =>
            event.changes.added.forEach(
          (item) => item.content.getContent().cast<int>().forEach(addClientId),
        ),
      );
      ids.forEach((v) => addClientId(v as int));
    }

    // observe users
    this.yusers.observe((event, _) {
      event.keysChanged.forEach((userDescription) => initUser(
            this.yusers.get(userDescription!)!,
            userDescription,
            this.yusers,
          ));
    });
    // add intial data
    this.yusers.forEach(initUser);
  }

  final Doc doc;
  late final YMap<YMap<dynamic>> yusers;
  final clients = <int, String>{};

  final dss = <String, DeleteSet>{};

  void setUserMapping(
    Doc doc,
    int clientid,
    String userDescription, [
    bool Function(Transaction, DeleteSet) filter = _defaultFilter,
  ]) {
    final users = this.yusers;
    var user = users.get(userDescription);
    if (user == null) {
      user = YMap();
      user.set("ids", YArray<int>());
      user.set("ds", YArray<Uint8List>());
      users.set(userDescription, user);
    }
    user.get("ids").push([clientid]);
    users.observe((event, _) {
      Future.delayed(Duration.zero, () {
        final userOverwrite = users.get(userDescription);
        if (userOverwrite != user) {
          // user was overwritten, port all data over to the next user object
          // @todo Experiment with Y.Sets here
          user = userOverwrite;
          // @todo iterate over old type
          this.clients.forEach((clientid, _userDescription) {
            if (userDescription == _userDescription) {
              user!.get("ids").push([clientid]);
            }
          });
          final encoder = DSEncoderV1();
          final ds = this.dss.get(userDescription);
          if (ds != null) {
            writeDeleteSet(encoder, ds);
            user!.get("ds").push([encoder.toUint8Array()]);
          }
        }
      });
    });
    doc.on("afterTransaction",(params) {
      final transaction = params[0] as Transaction;
      Future.delayed(Duration.zero, () {
        final yds = user!.get("ds") as YArray<Uint8List>;
        final ds = transaction.deleteSet;
        if (transaction.local &&
            ds.clients.length > 0 &&
            filter(transaction, ds)) {
          final encoder = DSEncoderV1();
          writeDeleteSet(encoder, ds);
          yds.push([encoder.toUint8Array()]);
        }
      });
    });
  }

  String? getUserByClientId(int clientid) {
    return this.clients.get(clientid);
  }

  String? getUserByDeletedId(ID id) {
    for (final entry in this.dss.entries) {
      if (isDeleted(entry.value, id)) {
        return entry.key;
      }
    }
    return null;
  }
}
