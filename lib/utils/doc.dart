import 'dart:math' as math;

import 'package:uuid/uuid.dart';
import 'package:flutter_crdt/structs/content_doc.dart';
import 'package:flutter_crdt/structs/item.dart';
import 'package:flutter_crdt/types/abstract_type.dart';
import 'package:flutter_crdt/types/y_array.dart';
import 'package:flutter_crdt/types/y_map.dart';
import 'package:flutter_crdt/types/y_text.dart';
import 'package:flutter_crdt/utils/observable.dart';
import 'package:flutter_crdt/utils/struct_store.dart';
import 'package:flutter_crdt/utils/transaction.dart' show Transaction, transact;
import 'package:flutter_crdt/utils/y_event.dart';
import 'package:flutter_crdt/y_crdt_base.dart';

const globalTransact = transact;
/**
 * @module Y
 */


final _random = math.Random();
final _uuid = Uuid();

int generateNewClientId() => _random.nextInt(4294967295);

class Doc extends Observable<String> {
  static bool defaultGcFilter(Item _) => true;

  Doc({
    String? guid,
    bool? gc,
    this.gcFilter = Doc.defaultGcFilter,
    this.meta,
    bool? autoLoad,
  })  : autoLoad = autoLoad ?? false,
        shouldLoad = autoLoad ?? false,
        gc = gc ?? true {
    this.guid = guid ?? _uuid.v4();
  }

  final bool gc;
  final bool Function(Item) gcFilter;
  int clientID = generateNewClientId();
  late final String guid;
  Object? collectionid;

  final share = <String, AbstractType<YEvent>>{};
  final StructStore store = StructStore();

  Transaction? transaction;

  List<Transaction> transactionCleanups = [];

  final subdocs = <Doc>{};

  Item? item;
  bool shouldLoad;
  final bool autoLoad;
  final dynamic meta;

  void load() {
    final item = this.item;
    if (item != null && !this.shouldLoad) {
      globalTransact(
          /** @type {any} */
          (item.parent as dynamic).doc as Doc, (transaction) {
        transaction.subdocsLoaded.add(this);
      }, null, true);
    }
    this.shouldLoad = true;
  }

  Set<Doc> getSubdocs() {
    return this.subdocs;
  }

  Set<dynamic> getSubdocGuids() {
    return this.subdocs.map((doc) => doc.guid).toSet();
  }

  void transact(void Function(Transaction transaction) f, [dynamic origin]) {
    globalTransact(this, f, origin);
  }

  T get<T extends AbstractType<YEvent>>(
    String name, [
    T Function()? typeConstructor,
  ]) {
    if (typeConstructor == null) {
      if (T.toString() == "AbstractType<YEvent>") {
        typeConstructor = () => AbstractType.create<YEvent>() as T;
      } else {
        throw Exception();
      }
    }
    final type = this.share.putIfAbsent(name, () {
      // @ts-ignore
      final t = typeConstructor!();
      t.innerIntegrate(this, null);
      return t;
    });
    if (T.toString() != "AbstractType<YEvent>" && type is! T) {
      if (type.runtimeType.toString() == "AbstractType<YEvent>") {
        // @ts-ignore
        final t = typeConstructor();
        t.innerMap = type.innerMap;
        type.innerMap.forEach(
            /** @param {Item?} n */
            (_, n) {
          Item? item = n;
          for (; item != null; item = item.left) {
            // @ts-ignore
            item.parent = t;
          }
        });
        t.innerStart = type.innerStart;
        for (var n = t.innerStart; n != null; n = n.right) {
          n.parent = t;
        }
        t.innerLength = type.innerLength;
        this.share.set(name, t);
        t.innerIntegrate(this, null);
        return t;
      } else {
        throw Exception(
            "Type with the name ${name} has already been defined with a different constructor");
      }
    }
    return type as T;
  }

  YArray<T> getArray<T>([String name = ""]) {
    // @ts-ignore
    return this.get<YArray<T>>(name, YArray.create) as YArray<T>;
  }

  YText getText([String name = ""]) {
    // @ts-ignore
    return this.get<YText>(name, YText.create) as YText;
  }

  YMap<T> getMap<T>([String name = ""]) {
    // @ts-ignore
    return this.get<YMap<T>>(name, YMap.create) as YMap<T>;
  }

  Map<String, dynamic> toJSON() {
    final doc = <String, dynamic>{};

    // TODO: use Map.map
    this.share.forEach((key, value) {
      doc[key] = value.toJSON();
    });

    return doc;
  }

  @override
  void destroy() {
    this.subdocs.forEach((subdoc) => subdoc.destroy());
    final item = this.item;
    if (item != null) {
      this.item = null;
      final content = item.content as ContentDoc;
      var opts = content.opts;
      content.doc = Doc(
        guid: this.guid,
        gc: opts.gc,
        autoLoad: opts.autoLoad,
        meta: opts.meta,
      );
      content.doc!.item = item;
      globalTransact((item.parent as dynamic).doc, (transaction) {
        final doc = content.doc;
        if (!item.deleted) {
          transaction.subdocsAdded.add(doc!);
        }
        transaction.subdocsRemoved.add(this);
      }, [null, true]);
    }
    this.emit('destroyed', [true]);
    this.emit('destroy', [this]);
    super.destroy();
  }

  @override
  void on(String eventName, void Function(List<dynamic> args) f) {
    super.on(eventName, f);
  }

  @override
  void off(String eventName, void Function(List<dynamic>) f) {
    super.off(eventName, f);
  }
}
