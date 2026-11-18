/// A small HTTP client on `dart:io`, in place of `package:http`.
///
/// It covers what fluttAIrbar uses: GET and POST with headers and a text or
/// form body, the whole answer read at once. Requests, redirects (followed,
/// at most 5), how an answer's text is decoded and the error messages are
/// those of `package:http` 1.6, which used `dart:io` the same way. Import it
/// as `http` so the call sites read `http.Client`, `http.Response`.
library;

import 'dart:collection';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

/// Header names compare without regard to case, as in HTTP.
Map<String, String> _headerMap([Map<String, String>? from]) {
  final map = LinkedHashMap<String, String>(
    equals: (a, b) => a.toLowerCase() == b.toLowerCase(),
    hashCode: (key) => key.toLowerCase().hashCode,
  );
  if (from != null) map.addAll(from);
  return map;
}

/// The text encoding of a body with this `Content-Type`: its charset, UTF-8
/// for JSON without one, Latin-1 otherwise (RFC 2616's default).
Encoding _encodingFor(Map<String, String> headers) {
  final header = headers['content-type'];
  if (header == null) return latin1;
  final type = io.ContentType.parse(header);
  final charset = type.charset;
  if (charset == null) {
    return type.primaryType == 'application' && type.subType == 'json'
        ? utf8
        : latin1;
  }
  return Encoding.getByName(charset) ?? latin1;
}

/// A request whose whole body is known before it is sent.
class Request {
  Request(this.method, this.url, {Map<String, String>? headers, Object? body})
    : headers = _headerMap(headers) {
    switch (body) {
      case null:
        bodyBytes = Uint8List(0);
      case String text:
        _setText(text);
      case List<int> bytes:
        bodyBytes = Uint8List.fromList(bytes);
      case Map<String, String> fields:
        final type = this.headers['content-type'];
        if (type == null) {
          this.headers['content-type'] = 'application/x-www-form-urlencoded';
        } else if (io.ContentType.parse(type).mimeType !=
            'application/x-www-form-urlencoded') {
          throw StateError(
            'Cannot set the body fields of a Request with content-type '
            '"${io.ContentType.parse(type).mimeType}".',
          );
        }
        _setText(
          fields.entries
              .map(
                (e) =>
                    '${Uri.encodeQueryComponent(e.key)}='
                    '${Uri.encodeQueryComponent(e.value)}',
              )
              .join('&'),
        );
      default:
        throw ArgumentError('Invalid request body "$body".');
    }
  }

  final String method;
  final Uri url;
  final Map<String, String> headers;
  late final Uint8List bodyBytes;

  String get body => utf8.decode(bodyBytes);

  /// A text body is sent as UTF-8; a text or XML type without a charset says so.
  void _setText(String text) {
    bodyBytes = utf8.encode(text);
    final header = headers['content-type'];
    if (header == null) {
      headers['content-type'] = 'text/plain; charset=utf-8';
      return;
    }
    final type = io.ContentType.parse(header);
    final mime = type.mimeType;
    final wantsCharset =
        type.primaryType == 'text' ||
        mime == 'application/xml' ||
        mime == 'application/xml-external-parsed-entity' ||
        mime == 'application/xml-dtd' ||
        mime.endsWith('+xml');
    if (wantsCharset && type.charset == null) {
      headers['content-type'] = '$header; charset=utf-8';
    }
  }
}

/// An answer, read in full.
class Response {
  /// An answer with a text body, encoded as its `Content-Type` says.
  Response(String body, int statusCode, {Map<String, String>? headers})
    : this.bytes(
        _encodingFor(_headerMap(headers)).encode(body),
        statusCode,
        headers: headers,
      );

  Response.bytes(
    List<int> bytes,
    this.statusCode, {
    Map<String, String>? headers,
  }) : headers = _headerMap(headers),
       bodyBytes = Uint8List.fromList(bytes);

  final int statusCode;
  final Map<String, String> headers;
  final Uint8List bodyBytes;

  /// The body as text, decoded as its `Content-Type` says.
  String get body => _encodingFor(headers).decode(bodyBytes);
}

/// A request that could not be made or whose answer could not be read.
class ClientException implements Exception {
  ClientException(this.message, [this.uri]);

  final String message;
  final Uri? uri;

  @override
  String toString() => uri != null
      ? 'ClientException: $message, uri=$uri'
      : 'ClientException: $message';
}

class _ClientSocketException extends ClientException
    implements io.SocketException {
  _ClientSocketException(this.cause, Uri uri) : super(cause.message, uri);

  final io.SocketException cause;

  @override
  io.InternetAddress? get address => cause.address;

  @override
  io.OSError? get osError => cause.osError;

  @override
  int? get port => cause.port;

  @override
  String toString() => 'ClientException with $cause, uri=$uri';
}

/// An HTTP client. [close] it when done; a closed client refuses requests.
class Client {
  Client() : _inner = io.HttpClient();

  /// For [send] overrides (tests) that never open a connection.
  Client.withoutConnection() : _inner = null;

  io.HttpClient? _inner;

  Future<Response> get(Uri url, {Map<String, String>? headers}) =>
      send(Request('GET', url, headers: headers));

  /// [body] is a `String`, bytes, or form fields as a `Map<String, String>`.
  Future<Response> post(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
  }) => send(Request('POST', url, headers: headers, body: body));

  Future<Response> send(Request request) async {
    final inner = _inner;
    if (inner == null) {
      throw ClientException(
        'HTTP request failed. Client is already closed.',
        request.url,
      );
    }
    try {
      final ioRequest = await inner.openUrl(request.method, request.url)
        ..followRedirects = true
        ..maxRedirects = 5
        ..contentLength = request.bodyBytes.length
        ..persistentConnection = true;
      request.headers.forEach(ioRequest.headers.set);
      ioRequest.add(request.bodyBytes);
      final response = await ioRequest.close();
      final bytes = await response.fold<BytesBuilder>(
        BytesBuilder(copy: false),
        (builder, chunk) => builder..add(chunk),
      );
      final headers = <String, String>{};
      response.headers.forEach((name, values) {
        headers[name] = values.map((value) => value.trimRight()).join(',');
      });
      return Response.bytes(
        bytes.takeBytes(),
        response.statusCode,
        headers: headers,
      );
    } on io.SocketException catch (error) {
      throw _ClientSocketException(error, request.url);
    } on io.HttpException catch (error) {
      throw ClientException(error.message, error.uri);
    }
  }

  void close() {
    _inner?.close(force: true);
    _inner = null;
  }
}
