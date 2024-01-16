import 'package:flutter_crdt/y_crdt_base.dart';

class EventHandler<ARG0, ARG1> {
  List<void Function(ARG0, ARG1)> l = [];
}

EventHandler<ARG0, ARG1> createEventHandler<ARG0, ARG1>() => EventHandler();

void addEventHandlerListener<ARG0, ARG1>(
        EventHandler<ARG0, ARG1> eventHandler, void Function(ARG0, ARG1) f) =>
    eventHandler.l.add(f);

void removeEventHandlerListener<ARG0, ARG1>(
    EventHandler<ARG0, ARG1> eventHandler, void Function(ARG0, ARG1) f) {
  final l = eventHandler.l;
  final len = l.length;
  eventHandler.l = l.where((g) => f != g).toList();
  if (len == eventHandler.l.length) {
    logger.e("[yjs] Tried to remove event handler that doesn't exist.");
  }
}

void removeAllEventHandlerListeners<ARG0, ARG1>(
    EventHandler<ARG0, ARG1> eventHandler) {
  eventHandler.l.length = 0;
}

void callEventHandlerListeners<ARG0, ARG1>(
        EventHandler<ARG0, ARG1> eventHandler, ARG0 arg0, ARG1 arg1) =>
    eventHandler.l.forEach((f) => f(arg0, arg1));
