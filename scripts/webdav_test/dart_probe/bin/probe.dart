import 'dart:io';
import 'package:webdav_client/webdav_client.dart' as webdav;

void main() async {
  final c = webdav.newClient('https://127.0.0.1:8443',
      user: 'pctest', password: 'piggy123', debug: false);
  c.c.options.followRedirects = false;
  c.c.options.maxRedirects = 0;
  c.c.options.validateStatus = (s) => s == null || s < 300 || s >= 400;
  try {
    await c.readDir('/piggycount/');
    stdout.writeln('readDir OK');
  } catch (e) {
    stdout.writeln('EX TYPE: ${e.runtimeType}');
    stdout.writeln('EX: $e');
    final dyn = e as dynamic;
    try {
      stdout.writeln('response.statusCode: ${dyn.response?.statusCode}');
      stdout.writeln('type: ${dyn.type}');
    } catch (x) {
      stdout.writeln('no fields: $x');
    }
    try {
      await c.mkdirAll('/piggycount');
      stdout.writeln('mkdirAll OK');
      final files = await c.readDir('/piggycount/');
      stdout.writeln('readDir after mkdir: ${files.length} items');
    } catch (e2) {
      stdout.writeln('mkdirAll EX: $e2');
    }
  }
  exit(0);
}
