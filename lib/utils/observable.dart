import 'package:flutter_crdt/y_crdt_base.dart';

class Observable<N> {
  Observable();
  var innerObservers = <N, Set<void Function(List<dynamic>)>>{};

  void on(N name, void Function(List<dynamic>) f) {
    this.innerObservers.putIfAbsent(name, () => {}).add(f);
  }

  void once(N name, void Function() f) {
    void _f(List<dynamic> args) {
      this.off(name, _f);
      f();
    }

    this.on(name, _f);
  }

  void off(N name, void Function(List<dynamic>) f) {
    final observers = this.innerObservers.get(name);
    if (observers != null) {
      observers.remove(f);
      if (observers.length == 0) {
        this.innerObservers.remove(name);
      }
    }
  }

  void emit(N name, List<dynamic> args) {
    return (this.innerObservers.get(name) ?? {})
        .toList()
        .forEach((f) => f(args));
  }

  void destroy() {
    this.innerObservers = {};
  }
}
