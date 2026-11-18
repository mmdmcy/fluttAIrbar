import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluttairbar/net/http.dart' as http;

void main() {
  late HttpServer server;
  late String base;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      final response = request.response;
      switch (request.uri.path) {
        case '/redirect':
          response
            ..statusCode = 302
            ..headers.set('location', '/echo');
        case '/latin':
          response.headers.set('content-type', 'text/plain');
          response.add([0x63, 0x61, 0x66, 0xe9]);
        case '/json':
          response.headers.set('content-type', 'application/json');
          response.add(utf8.encode('{"city":"Zürich"}'));
        default:
          response.headers.set('content-type', 'application/json');
          response.write(
            jsonEncode({
              'method': request.method,
              'type': request.headers.value('content-type'),
              'agent': request.headers.value('user-agent'),
              'body': body,
            }),
          );
      }
      await response.close();
    });
  });

  tearDown(() => server.close(force: true));

  test('GET sends the headers given and follows a redirect', () async {
    final client = http.Client();
    addTearDown(client.close);
    final direct = await client.get(
      Uri.parse('$base/echo'),
      headers: {'User-Agent': 'fluttAIrbar/1.0'},
    );
    expect(direct.statusCode, 200);
    expect(jsonDecode(direct.body), containsPair('agent', 'fluttAIrbar/1.0'));

    final redirected = await client.get(Uri.parse('$base/redirect'));
    expect(redirected.statusCode, 200);
    expect(jsonDecode(redirected.body), containsPair('method', 'GET'));
  });

  test('POST encodes form fields and keeps a JSON body as given', () async {
    final client = http.Client();
    addTearDown(client.close);
    final form = await client.post(
      Uri.parse('$base/echo'),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {'scope': 'openid profile', 'x': 'ü'},
    );
    expect(
      jsonDecode(form.body),
      containsPair('body', 'scope=openid+profile&x=%C3%BC'),
    );
    expect(
      jsonDecode(form.body),
      containsPair('type', 'application/x-www-form-urlencoded'),
    );

    final json = await client.post(
      Uri.parse('$base/echo'),
      headers: {'Content-Type': 'application/json'},
      body: '{"a":1}',
    );
    expect(jsonDecode(json.body), containsPair('body', '{"a":1}'));
    expect(jsonDecode(json.body), containsPair('type', 'application/json'));
  });

  test('a body is decoded as its content type says', () async {
    final client = http.Client();
    addTearDown(client.close);
    expect((await client.get(Uri.parse('$base/latin'))).body, 'café');
    expect(
      (await client.get(Uri.parse('$base/json'))).body,
      '{"city":"Zürich"}',
    );
  });

  test(
    'a refused connection and a closed client throw ClientException',
    () async {
      final client = http.Client();
      await expectLater(
        client.get(Uri.parse('http://127.0.0.1:1/')),
        throwsA(
          isA<http.ClientException>().having(
            (e) => e.toString(),
            'message',
            startsWith('ClientException with SocketException'),
          ),
        ),
      );
      client.close();
      await expectLater(
        client.get(Uri.parse('$base/echo')),
        throwsA(
          isA<http.ClientException>().having(
            (e) => e.message,
            'message',
            'HTTP request failed. Client is already closed.',
          ),
        ),
      );
    },
  );
}
