import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:webdav_client/webdav_client.dart' as webdav;

void main() async {
  final c = webdav.newClient('https://127.0.0.1:8443',
      user: 'pctest', password: 'piggy123', debug: false);
  c.c.options.followRedirects = false;
  c.c.options.maxRedirects = 0;
  c.c.options.validateStatus = (s) => s == null || s < 300 || s >= 400;
  c.c.options.connectTimeout = const Duration(seconds: 8);
  c.c.options.receiveTimeout = const Duration(seconds: 8);
  c.c.options.sendTimeout = const Duration(seconds: 8);
  final adapter = IOHttpClientAdapter();
  adapter.createHttpClient = () {
    final client = HttpClient();
    client.badCertificateCallback = (cert, host, port) => true;
    return client;
  };
  c.c.httpClientAdapter = adapter;
  try {
    await c.readDir('/piggycount/');
    stdout.writeln('readDir OK (unexpected)');
  } catch (e) {
    stdout.writeln('EX: $e');
    final dyn = e as dynamic;
    stdout.writeln('statusCode: ${dyn.response?.statusCode}');
    try {
      await c.mkdirAll('/piggycount');
      stdout.writeln('mkdirAll OK');
      final files = await c.readDir('/piggycount/');
      stdout.writeln('readDir after: ${files.length} items');
    } catch (e2) {
      stdout.writeln('mkdirAll EX: $e2');
    }
  }
  exit(0);
}
