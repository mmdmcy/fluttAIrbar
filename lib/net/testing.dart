/// A [Client] for tests: a function answers every request, nothing goes out.
library;

import 'http.dart';

class MockClient extends Client {
  MockClient(this._handler) : super.withoutConnection();

  final Future<Response> Function(Request request) _handler;

  @override
  Future<Response> send(Request request) => _handler(request);
}
